import { AppError } from '../utils/errors.js';

/** zod schema → 400 problem detail with per-field errors. */
export const validate = (schema, source = 'body') => (req, _res, next) => {
  const result = schema.safeParse(req[source]);
  if (!result.success) {
    return next(AppError.badRequest('VALIDATION_FAILED', 'Some fields need attention', {
      fields: result.error.issues.map((i) => ({ path: i.path.join('.'), message: i.message })),
    }));
  }
  req[source] = result.data;
  next();
};
