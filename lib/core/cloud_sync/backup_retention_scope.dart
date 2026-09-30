import 'dart:async';

/// External backup creation must never prune older snapshots.
class BackupRetentionScope {
  static final Object _key = Object();
  static bool get preserveExisting => Zone.current[_key] == true;
  static Future<T> preserve<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_key: true});
}
