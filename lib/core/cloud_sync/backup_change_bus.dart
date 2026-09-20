import 'dart:async';

/// Signals completed local edits. Restores are deliberately excluded.
class BackupChangeBus {
  static final _events = StreamController<String>.broadcast(sync: true);
  static Stream<String> get events => _events.stream;
  static int _restoring = 0;
  static bool get restoring => _restoring > 0;
  static void notify(String group) {
    if (!restoring) _events.add(group);
  }

  static Future<T> duringRestore<T>(Future<T> Function() apply) async {
    _restoring++;
    try {
      return await apply();
    } finally {
      _restoring--;
    }
  }
}
