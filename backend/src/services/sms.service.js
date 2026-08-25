import twilio from 'twilio';
import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';

/**
 * Transactional SMS (phone-verification OTP) over Twilio.
 *
 * The client is built lazily and only when credentials exist — Twilio's
 * constructor throws on a missing account SID, and we don't want importing this
 * module to require keys. No credentials (or no sender) → log transport, so dev
 * and tests never send. A Messaging Service SID is preferred over a bare number
 * when both are set.
 */

let client;
function twilioClient() {
  if (client !== undefined) return client;
  client = (config.twilio.sid?.startsWith('AC') && config.twilio.token)
    ? twilio(config.twilio.sid, config.twilio.token)
    : null;
  return client;
}

async function deliver(to, body) {
  const c = twilioClient();
  const sender = config.sms.messagingServiceSid
    ? { messagingServiceSid: config.sms.messagingServiceSid }
    : (config.sms.from ? { from: config.sms.from } : null);

  if (!c || !sender) {
    logger.info({ to }, config.isProd
      ? 'sms suppressed: no sms provider configured'
      : 'sms sent via log transport (no Twilio sender configured)');
    if (config.env === 'development') logger.debug({ to, body }, 'sms body (dev only)');
    return { delivered: false, provider: 'log' };
  }

  const msg = await c.messages.create({ to, body, ...sender });
  return { delivered: true, provider: 'twilio', sid: msg.sid };
}

export const SmsService = {
  otp: ({ to, code, minutes = 10 }) =>
    deliver(to, `Your Sparkle verification code is ${code}. It expires in ${minutes} minutes.`),
};
