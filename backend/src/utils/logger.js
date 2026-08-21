import pino from 'pino';
import { config } from '../config/index.js';

export const logger = pino({
  level: config.isProd ? 'info' : 'debug',
  transport: config.isProd ? undefined : { target: 'pino-pretty' },
  redact: {
    paths: [
      'req.headers.authorization', 'req.headers.cookie',
      '*.password', '*.password_hash', '*.card', '*.ssn',
      '*.phone_e164', '*.line1', '*.access_notes',
    ],
    censor: '[redacted]',
  },
});
