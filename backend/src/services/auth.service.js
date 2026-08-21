import argon2 from 'argon2';
import jwt from 'jsonwebtoken';
import { randomBytes, createHash, randomInt, timingSafeEqual } from 'node:crypto';

import { query, withTransaction } from '../db/pool.js';
import { config } from '../config/index.js';
import { AppError } from '../utils/errors.js';
import { logger } from '../utils/logger.js';
import { MailService } from './mail.service.js';
import { SmsService } from './sms.service.js';

const sha256 = (value) => createHash('sha256').update(value).digest('hex');

const ARGON = { type: argon2.argon2id, memoryCost: 19_456, timeCost: 2, parallelism: 1 };

/**
 * Authentication.
 *
 * Access tokens are short-lived JWTs (15 min) and are never revoked — with a
 * window that small, a revocation list buys you a database read on every
 * request for almost no security. Refresh tokens carry the weight: opaque,
 * stored hashed, rotated on every use, and grouped into a family per login so
 * a stolen copy can be detected and the whole family killed.
 */
export class AuthService {
  // ------------------------------------------------------------ register ---
  static async register({ email, password, fullName, phone, role, ip, userAgent, deviceId }) {
    if (role === 'admin') {
      // Admins are created by `npm run create-admin` on a machine someone had
      // to already have access to. An HTTP path to make an admin is an HTTP
      // path to take over the platform.
      throw AppError.forbidden('Admin accounts are not created through this endpoint');
    }
    if (password.length < 10) {
      throw AppError.badRequest('WEAK_PASSWORD', 'Use at least 10 characters');
    }

    const result = await withTransaction(async (client) => {
      const { rows: [existing] } = await client.query(
        'SELECT id FROM users WHERE email = $1 AND deleted_at IS NULL', [email]);
      if (existing) {
        // Registration is the one place enumeration is unavoidable — you cannot
        // let two people share an email. Keep the message narrow and make the
        // rate limiter do the rest of the work.
        throw AppError.conflict('EMAIL_TAKEN', 'An account with that email already exists');
      }

      const { rows: [user] } = await client.query(
        `INSERT INTO users (role, email, phone_e164, password_hash, full_name, status)
         VALUES ($1,$2,$3,$4,$5,'pending')
         RETURNING id, role, email, full_name, status, created_at`,
        [role, email, phone ?? null, await argon2.hash(password, ARGON), fullName],
      );

      if (role === 'customer') {
        await client.query('INSERT INTO customer_profiles (user_id) VALUES ($1)', [user.id]);
      } else {
        await client.query(
          `INSERT INTO cleaner_profiles (user_id, onboarding_status) VALUES ($1,'started')`,
          [user.id]);
      }

      await client.query(
        `INSERT INTO consents (user_id, purpose, version, ip_address, user_agent)
         VALUES ($1,'tos','2026-01',$2,$3), ($1,'privacy','2026-01',$2,$3)`,
        [user.id, ip ?? null, userAgent ?? null],
      );

      const verification = await this.#issueCode(client, user.id, 'verify_email', 32, 24 * 60);
      const session = await this.#startSession(client, user, { ip, userAgent, deviceId });

      logger.info({ userId: user.id, role }, 'account created');
      return { user, session, verificationToken: verification.plain };
    });

    // Deliver after the account is durably committed — a provider blip must not
    // roll back a registration, only miss a (resendable) email.
    await this.#sendEmail('verification', result.user.id, () => MailService.verifyEmail({
      to: result.user.email, name: result.user.full_name, token: result.verificationToken,
    }));

    return { user: result.user, ...result.session };
  }

  // --------------------------------------------------------------- login ---
  static async login({ email, password, ip, userAgent, deviceId }) {
    const { rows: [user] } = await query(
      `SELECT id, role, email, full_name, password_hash, status
         FROM users WHERE email = $1 AND deleted_at IS NULL`, [email]);

    // Hash against a dummy when the user is missing so a wrong email and a
    // wrong password take the same time. Otherwise the response latency is an
    // account-existence oracle.
    const hash = user?.password_hash ?? '$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHRzYWx0$0000000000000000000000000000000000000000000';
    let ok;
    try {
      ok = await argon2.verify(hash, password);
    } catch { ok = false; }

    if (!user || !ok) {
      throw AppError.unauthorized('Email or password is incorrect');
    }
    if (user.status === 'suspended') {
      throw AppError.forbidden('This account is suspended. Contact support.');
    }
    if (user.status === 'deleted') {
      throw AppError.unauthorized('Email or password is incorrect');
    }

    return withTransaction(async (client) => {
      await client.query('UPDATE users SET last_login_at = now() WHERE id = $1', [user.id]);
      // A login cancels a pending erasure — coming back is the clearest
      // possible signal the person changed their mind.
      await client.query(
        `UPDATE data_requests SET status = 'canceled'
          WHERE user_id = $1 AND kind = 'erasure' AND completed_at IS NULL`, [user.id]);

      const session = await this.#startSession(client, user, { ip, userAgent, deviceId });
      return { user: strip(user), ...session };
    });
  }

  // ------------------------------------------------------------- refresh ---
  /**
   * Rotation with reuse detection.
   *
   * A refresh token is single-use. Presenting one that has already been
   * exchanged means two parties hold the same secret — the legitimate client
   * and whoever copied it. We can't tell which is which, so we revoke the
   * entire family and make both log in again. Annoying once, safe always.
   */
  static async refresh({ presented, ip, userAgent, deviceId }) {
    const tokenHash = sha256(presented);

    return withTransaction(async (client) => {
      const { rows: [token] } = await client.query(
        'SELECT * FROM refresh_tokens WHERE token_hash = $1 FOR UPDATE', [tokenHash]);
      if (!token) throw AppError.unauthorized('Session expired. Please sign in again.');

      if (token.used_at || token.revoked_at) {
        await client.query(
          `UPDATE refresh_tokens
              SET revoked_at = now(), revoked_reason = 'reuse_detected'
            WHERE family_id = $1 AND revoked_at IS NULL`,
          [token.family_id]);
        logger.error({ userId: token.user_id, familyId: token.family_id },
          'refresh token reuse — family revoked');
        throw AppError.unauthorized('Session expired. Please sign in again.');
      }

      if (token.expires_at < new Date()) {
        throw AppError.unauthorized('Session expired. Please sign in again.');
      }

      const { rows: [user] } = await client.query(
        `SELECT id, role, email, full_name, status FROM users
          WHERE id = $1 AND deleted_at IS NULL`, [token.user_id]);
      if (!user || user.status === 'suspended') {
        throw AppError.unauthorized('Session expired. Please sign in again.');
      }

      await client.query('UPDATE refresh_tokens SET used_at = now() WHERE id = $1', [token.id]);

      const next = await this.#issueRefresh(client, user.id, {
        familyId: token.family_id, parentId: token.id, ip, userAgent, deviceId,
      });
      return {
        user: strip(user),
        access_token: this.#signAccess(user),
        refresh_token: next.plain,
        expires_in: 900,
      };
    });
  }

  /** Sign out this device. `allDevices` revokes every live family. */
  static async logout({ presented, userId, allDevices = false }) {
    if (allDevices) {
      await query(
        `UPDATE refresh_tokens SET revoked_at = now(), revoked_reason = 'logout_all'
          WHERE user_id = $1 AND revoked_at IS NULL`, [userId]);
      return { revoked: 'all' };
    }
    const { rows: [token] } = await query(
      'SELECT family_id FROM refresh_tokens WHERE token_hash = $1', [sha256(presented ?? '')]);
    if (token) {
      await query(
        `UPDATE refresh_tokens SET revoked_at = now(), revoked_reason = 'logout'
          WHERE family_id = $1 AND revoked_at IS NULL`, [token.family_id]);
    }
    return { revoked: 'session' };
  }

  // ---------------------------------------------------- verify and reset ---
  static async verifyEmail(token) {
    const user = await withTransaction(async (client) => {
      const record = await this.#consumeCode(client, 'verify_email', token);
      const { rows: [u] } = await client.query(
        `UPDATE users SET email_verified_at = now(),
                status = CASE WHEN status = 'pending' THEN 'active' ELSE status END
          WHERE id = $1 RETURNING id, email, full_name`, [record.user_id]);
      return u;
    });

    if (user?.email) {
      await this.#sendEmail('welcome', user.id, () => MailService.welcome({ to: user.email, name: user.full_name }));
    }
    return { verified: true };
  }

  static async startPhoneVerification(userId) {
    const { code, phone } = await withTransaction(async (client) => {
      const { rows: [user] } = await client.query(
        'SELECT phone_e164 FROM users WHERE id = $1', [userId]);
      const issued = await this.#issueCode(client, userId, 'verify_phone', null, 10);
      return { code: issued.plain, phone: user?.phone_e164 };
    });

    if (phone) {
      await this.#sendSms(userId, () => SmsService.otp({ to: phone, code, minutes: 10 }));
    } else {
      logger.warn({ userId }, 'phone verification requested but no phone number on file');
    }

    // The code is delivered by SMS and never returned over the API — except on a
    // developer's own machine, where there is no provider to deliver it.
    return {
      sent: true,
      expires_in: 600,
      ...(config.env === 'development' ? { dev_code: code } : {}),
    };
  }

  static async verifyPhone(userId, code) {
    return withTransaction(async (client) => {
      await this.#consumeCode(client, 'verify_phone', code, userId);
      await client.query('UPDATE users SET phone_verified_at = now() WHERE id = $1', [userId]);
      return { verified: true };
    });
  }

  /**
   * Always returns the same response whether or not the address exists — the
   * one endpoint where enumeration is trivially avoidable, so avoid it.
   */
  static async forgotPassword(email) {
    const { rows: [user] } = await query(
      'SELECT id FROM users WHERE email = $1 AND deleted_at IS NULL', [email]);
    if (user) {
      const code = await withTransaction((client) =>
        this.#issueCode(client, user.id, 'reset_password', 32, 60));
      logger.info({ userId: user.id }, 'password reset issued');
      await this.#sendEmail('password reset', user.id, () =>
        MailService.passwordReset({ to: email, token: code.plain }));
    }
    // Identical response whether or not the address exists — no enumeration.
    return { sent: true };
  }

  static async resetPassword({ token, password }) {
    if (password.length < 10) {
      throw AppError.badRequest('WEAK_PASSWORD', 'Use at least 10 characters');
    }
    const userId = await withTransaction(async (client) => {
      const record = await this.#consumeCode(client, 'reset_password', token);
      await client.query('UPDATE users SET password_hash = $2 WHERE id = $1',
        [record.user_id, await argon2.hash(password, ARGON)]);
      // A password change ends every existing session. If the reset was the
      // attacker's doing the owner finds out immediately; if it was the owner's,
      // any session the attacker held is now dead.
      await client.query(
        `UPDATE refresh_tokens SET revoked_at = now(), revoked_reason = 'password_reset'
          WHERE user_id = $1 AND revoked_at IS NULL`, [record.user_id]);
      return record.user_id;
    });

    // Security notice — the owner learns of a change they didn't make.
    const { rows: [user] } = await query(
      'SELECT email, full_name FROM users WHERE id = $1', [userId]);
    if (user?.email) {
      await this.#sendEmail('password changed', userId, () =>
        MailService.passwordChanged({ to: user.email, name: user.full_name }));
    }
    return { reset: true };
  }

  // -------------------------------------------------------------- private ---
  /**
   * Transactional sends are best-effort and always post-commit: the account
   * change is the source of truth, and a provider outage should degrade to "no
   * email arrived" (resendable), never a 500 that loses the write. Failures are
   * logged loudly for ops.
   */
  static async #sendEmail(kind, userId, send) {
    try {
      const r = await send();
      logger.info({ userId, kind, provider: r.provider, delivered: r.delivered }, 'transactional email dispatched');
    } catch (err) {
      logger.error({ err: err.message, userId, kind }, 'transactional email failed to send');
    }
  }

  static async #sendSms(userId, send) {
    try {
      const r = await send();
      logger.info({ userId, provider: r.provider, delivered: r.delivered }, 'otp sms dispatched');
    } catch (err) {
      logger.error({ err: err.message, userId }, 'otp sms failed to send');
    }
  }

  static #signAccess(user) {
    return jwt.sign(
      { sub: user.id, role: user.role },
      config.jwt.accessSecret,
      { expiresIn: config.jwt.accessTtl, issuer: 'sparkle-api', jwtid: randomBytes(8).toString('hex') },
    );
  }

  static async #startSession(client, user, meta) {
    const refresh = await this.#issueRefresh(client, user.id, { ...meta, familyId: null });
    return { access_token: this.#signAccess(user), refresh_token: refresh.plain, expires_in: 900 };
  }

  static async #issueRefresh(client, userId, { familyId, parentId, ip, userAgent, deviceId }) {
    const plain = randomBytes(48).toString('base64url');
    const expiresAt = new Date(Date.now() + config.jwt.refreshTtlDays * 86_400_000);

    const { rows: [row] } = await client.query(
      `INSERT INTO refresh_tokens
         (user_id, family_id, token_hash, parent_id, device_id, user_agent, ip_address, expires_at)
       VALUES ($1, COALESCE($2, uuid_generate_v7()), $3, $4, $5, $6, $7, $8)
       RETURNING id, family_id`,
      [userId, familyId, sha256(plain), parentId ?? null, deviceId ?? null,
       userAgent ?? null, ip ?? null, expiresAt],
    );
    return { plain, ...row };
  }

  static async #issueCode(client, userId, purpose, bytes, ttlMinutes) {
    // Long random string for links, 6 digits for SMS — a 6-digit link is
    // guessable, and a 43-character SMS code is unusable.
    const plain = bytes ? randomBytes(bytes).toString('base64url') : String(randomInt(100_000, 1_000_000));

    // Supersede anything outstanding for this purpose so an old email can't be
    // replayed after a resend.
    await client.query(
      `UPDATE auth_codes SET consumed_at = now()
        WHERE user_id = $1 AND purpose = $2 AND consumed_at IS NULL`, [userId, purpose]);

    await client.query(
      `INSERT INTO auth_codes (user_id, purpose, code_hash, expires_at)
       VALUES ($1,$2,$3, now() + ($4 || ' minutes')::interval)`,
      [userId, purpose, sha256(plain), ttlMinutes],
    );
    return { plain };
  }

  static async #consumeCode(client, purpose, presented, userId = null) {
    const presentedHash = sha256(presented ?? '');
    const { rows } = await client.query(
      `SELECT * FROM auth_codes
        WHERE purpose = $1 AND consumed_at IS NULL AND expires_at > now()
          AND ($2::uuid IS NULL OR user_id = $2)
        ORDER BY created_at DESC LIMIT 5
        FOR UPDATE`,
      [purpose, userId],
    );

    const match = rows.find((row) => {
      const a = Buffer.from(row.code_hash);
      const b = Buffer.from(presentedHash);
      return a.length === b.length && timingSafeEqual(a, b);
    });

    if (!match) {
      // Count the miss against the newest outstanding code, and burn it after
      // five. Without this a 6-digit SMS code falls to a million guesses.
      if (rows[0]) {
        const { rows: [updated] } = await client.query(
          'UPDATE auth_codes SET attempts = attempts + 1 WHERE id = $1 RETURNING attempts',
          [rows[0].id]);
        if (updated.attempts >= 5) {
          await client.query('UPDATE auth_codes SET consumed_at = now() WHERE id = $1', [rows[0].id]);
        }
      }
      throw AppError.badRequest('INVALID_CODE', 'That code is invalid or has expired');
    }

    await client.query('UPDATE auth_codes SET consumed_at = now() WHERE id = $1', [match.id]);
    return match;
  }
}

const strip = ({ password_hash, ...rest }) => rest;
