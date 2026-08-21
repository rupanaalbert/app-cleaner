import { AppError } from '../utils/errors.js';
import { logger } from '../utils/logger.js';

export function notFound(req, res) {
  res.status(404).json({
    type: 'https://api.sparkle.app/errors/not-found',
    title: 'Not found', status: 404, code: 'NOT_FOUND',
    detail: `${req.method} ${req.path} does not exist`, request_id: req.id,
  });
}

export function errorHandler(err, req, res, _next) {
  const known = err instanceof AppError;
  const status = known ? err.status : 500;

  if (!known) logger.error({ err, reqId: req.id }, 'unhandled error');

  res.status(status).json({
    type: `https://api.sparkle.app/errors/${(known ? err.code : 'internal').toLowerCase().replace(/_/g, '-')}`,
    title: known ? err.message : 'Something went wrong',
    status,
    code: known ? err.code : 'INTERNAL',
    // Never leak internals to clients; the request id ties this to the log line.
    detail: known ? err.message : 'The request could not be completed.',
    request_id: req.id,
    ...(known && Object.keys(err.meta).length ? { meta: err.meta } : {}),
  });
}
