/// The server's idea of "now", estimated on this device.
///
/// Every live-session deadline (`question_ends_at`) is a server timestamp. A
/// countdown that compares it with `DateTime.now()` inherits whatever this
/// device's clock is doing: a host laptop five seconds fast used to reveal every
/// question five seconds early for the whole class, and a slow phone showed
/// time left after the server had closed answers.
///
/// Each realtime frame carries the server's send time (`at`). The gap between
/// that and the local receive time is the clock offset minus network latency,
/// so the largest recent gap is the best estimate — the sample that spent the
/// least time in flight.
class ServerClock {
  ServerClock({this.window = 16, DateTime Function()? localNow})
    : _localNow = localNow ?? DateTime.now;

  /// How many recent samples to keep. Old samples roll off, so a device clock
  /// that is corrected mid-lesson is picked up within a few frames.
  final int window;

  final DateTime Function() _localNow;
  final List<Duration> _samples = [];

  Duration _offset = Duration.zero;

  /// Add this to local time to get server time.
  Duration get offset => _offset;

  bool get hasSample => _samples.isNotEmpty;

  /// Server time now, as best this device can tell.
  DateTime now() => _localNow().add(_offset);

  /// Records one frame's server send time, received at [receivedAt] (local).
  void sample(DateTime serverTime, {DateTime? receivedAt}) {
    final local = receivedAt ?? _localNow();
    _samples.add(serverTime.difference(local));
    if (_samples.length > window) _samples.removeAt(0);
    _offset = _samples.reduce((a, b) => a > b ? a : b);
  }

  void reset() {
    _samples.clear();
    _offset = Duration.zero;
  }
}
