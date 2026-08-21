/** RFC 9457 problem details. Every thrown AppError renders identically to clients. */
export class AppError extends Error {
  constructor(status, code, detail, meta = {}) {
    super(detail);
    this.status = status;
    this.code = code;
    this.meta = meta;
  }
  static badRequest(code, detail, meta) { return new AppError(400, code, detail, meta); }
  static unauthorized(detail = 'Authentication required') { return new AppError(401, 'UNAUTHENTICATED', detail); }
  static forbidden(detail = 'Not permitted') { return new AppError(403, 'FORBIDDEN', detail); }
  static notFound(entity) { return new AppError(404, 'NOT_FOUND', `${entity} not found`); }
  static conflict(code, detail, meta) { return new AppError(409, code, detail, meta); }
  static unprocessable(code, detail, meta) { return new AppError(422, code, detail, meta); }
  static payment(code, detail) { return new AppError(402, code, detail); }
}
