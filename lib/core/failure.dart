/// A user-facing error the UI can show verbatim.
///
/// The backend speaks one error envelope (docs/API.md):
///
/// ```json
/// { "error": { "code": "VALIDATION", "message": "…", "field": "email" } }
/// ```
///
/// All three parts are preserved here: [message] for the banner, [code] for
/// programmatic branching (a caller can tell `NOT_FOUND` from `RATE_LIMITED`)
/// and [field] so a form can attach the message to the offending input instead
/// of dumping it in a snackbar.
class AppFailure implements Exception {
  const AppFailure(
    this.message, {
    this.code = 'UNKNOWN',
    this.field,
    this.status,
    this.cause,
  });

  /// Human readable, safe to render as-is.
  final String message;

  /// Backend error code: `VALIDATION`, `UNAUTHORIZED`, `FORBIDDEN`,
  /// `NOT_FOUND`, `CONFLICT`, `RATE_LIMITED`, `UPSTREAM`, `INTERNAL`, plus the
  /// client-side codes `NETWORK`, `STORAGE` and `UNKNOWN`.
  final String code;

  /// Offending request field, when the server named one (`email`, `options`…).
  final String? field;

  /// HTTP status, when the failure came from a response.
  final int? status;

  final Object? cause;

  bool get isUnauthorized => code == 'UNAUTHORIZED' || status == 401;
  bool get isNotFound => code == 'NOT_FOUND' || status == 404;
  bool get isNetwork => code == 'NETWORK';

  @override
  String toString() => message;
}
