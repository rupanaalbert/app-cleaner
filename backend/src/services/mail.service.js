import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';
import * as templates from './mail.templates.js';

/**
 * Transactional email.
 *
 * Postmark over its HTTP API (no SDK — one fetch, no dependency). When
 * POSTMARK_TOKEN is unset the service logs instead of sending: local dev needs
 * no key and, crucially, tests never reach the network. Callers pass tokens;
 * this module turns them into links and never logs a link body in production.
 */

const link = (path) => `${config.mail.appUrl}${path}`;

async function deliver({ to, subject, text, html }) {
  if (!config.mail.postmarkToken) {
    logger.info({ to, subject }, config.isProd
      ? 'email suppressed: no mail provider configured'
      : 'email sent via log transport (no POSTMARK_TOKEN)');
    // Only a local dev machine should ever see the clickable contents in a log.
    if (config.env === 'development') logger.debug({ to, text }, 'email body (dev only)');
    return { delivered: false, provider: 'log' };
  }

  const res = await fetch('https://api.postmarkapp.com/email', {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      'X-Postmark-Server-Token': config.mail.postmarkToken,
    },
    body: JSON.stringify({
      From: config.mail.from,
      To: to,
      Subject: subject,
      TextBody: text,
      HtmlBody: html,
      MessageStream: 'outbound',
    }),
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    throw new Error(`postmark ${res.status}: ${detail.slice(0, 200)}`);
  }
  return { delivered: true, provider: 'postmark' };
}

export const MailService = {
  verifyEmail: ({ to, name, token }) =>
    deliver({ to, ...templates.verifyEmail({ name, url: link(`/verify-email?token=${encodeURIComponent(token)}`) }) }),
  passwordReset: ({ to, token }) =>
    deliver({ to, ...templates.passwordReset({ url: link(`/reset-password?token=${encodeURIComponent(token)}`) }) }),
  passwordChanged: ({ to, name }) =>
    deliver({ to, ...templates.passwordChanged({ name }) }),
  welcome: ({ to, name }) =>
    deliver({ to, ...templates.welcome({ name }) }),
};
