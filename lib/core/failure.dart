/// A user-facing error the UI can show verbatim.
class AppFailure implements Exception {
  const AppFailure(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() => 'AppFailure($message)';
}
