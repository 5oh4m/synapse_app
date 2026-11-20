/// Realtime connection status, surfaced to the UI through
/// `connectionStateProvider` so a live quiz can show a reconnect banner.
///
/// Deliberately named `ConnectionState` to match docs/STATE_CONTRACT.md. It
/// collides with Flutter's `ConnectionState` (the `AsyncSnapshot` one), so a
/// widget that needs both should import this as
/// `import 'package:quizzle/core/connection.dart' as net;`.
enum ConnectionState {
  /// Socket open and subscribed; deltas are flowing.
  connected,

  /// Socket dropped, backoff timer running, a reconnect is in flight.
  reconnecting,

  /// Not connected and not trying — signed out, or this backend has no socket.
  offline,
}
