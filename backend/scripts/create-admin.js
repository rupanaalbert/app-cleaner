#!/usr/bin/env node
/**
 * Creates an admin account. Deliberately not an HTTP endpoint: an API route
 * that mints admins is an API route that hands over the platform. This needs
 * shell access to a machine with the production DATABASE_URL.
 *
 *   npm run create-admin -- ops@sparkle.app "Dana Osei"
 */
import argon2 from 'argon2';
import { randomBytes } from 'node:crypto';
import { pool, query } from '../src/db/pool.js';

const [email, fullName] = process.argv.slice(2);
if (!email || !fullName) {
  console.error('Usage: npm run create-admin -- <email> "<full name>"');
  process.exit(1);
}

const password = randomBytes(18).toString('base64url');

const { rows: [existing] } = await query(
  'SELECT id FROM users WHERE email = $1 AND deleted_at IS NULL', [email]);
if (existing) {
  console.error(`${email} already exists.`);
  process.exit(1);
}

const { rows: [user] } = await query(
  `INSERT INTO users (role, email, full_name, password_hash, status, email_verified_at)
   VALUES ('admin', $1, $2, $3, 'active', now()) RETURNING id`,
  [email, fullName, await argon2.hash(password, {
    type: argon2.argon2id, memoryCost: 19_456, timeCost: 2, parallelism: 1,
  })],
);

await query(
  `INSERT INTO audit_log (actor_id, action, entity_type, entity_id, after)
   VALUES ($1,'admin.create','user',$1,$2)`,
  [user.id, JSON.stringify({ email, created_via: 'cli' })],
);

console.log(`\nAdmin created: ${email}`);
console.log(`Temporary password: ${password}`);
console.log('Share it out of band and have them reset it on first sign-in.\n');
await pool.end();
