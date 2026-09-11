// One error shape for the whole API:
//   { error: { code, message, field? } }
// Stack traces never cross the wire; 500s carry a request id instead.

export const CODES = {
  VALIDATION: 422,
  UNAUTHORIZED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  RATE_LIMITED: 429,
  UPSTREAM: 502,
  INTERNAL: 500,
};

export class ApiError extends Error {
  constructor(code, message, { field, status, cause } = {}) {
    super(message);
    this.name = 'ApiError';
    this.code = code;
    this.status = status || CODES[code] || 400;
    this.field = field;
    if (cause) this.cause = cause;
  }

  toJSON() {
    const body = { code: this.code, message: this.message };
    if (this.field) body.field = this.field;
    return { error: body };
  }
}

export const badRequest = (message, field) =>
  new ApiError('VALIDATION', message, { field, status: 400 });
export const validation = (message, field) => new ApiError('VALIDATION', message, { field });
export const unauthorized = (message = 'Sign in to continue.') =>
  new ApiError('UNAUTHORIZED', message);
export const forbidden = (message = 'You do not have access to that.') =>
  new ApiError('FORBIDDEN', message);
/** Ownership failures use this, never 403 — do not leak existence. */
export const notFound = (message = 'Not found.') => new ApiError('NOT_FOUND', message);
export const conflict = (message, field) => new ApiError('CONFLICT', message, { field });
export const upstream = (message) => new ApiError('UPSTREAM', message);
