import 'dart:async';
import 'package:dio/dio.dart';
import '../agent/abort_signal.dart';

/// Only external operations install this scope. Existing UI requests are unchanged.
class ExternalBillingScope {
  ExternalBillingScope({required this.beforeRequest, this.signal});
  final Future<void> Function(String kind, Map<String, dynamic> parameters)
  beforeRequest;
  final AbortSignal? signal;
  final CancelToken _cancelToken = CancelToken();
  static final Object _key = Object();
  static final Map<String, ExternalBillingScope> _queueScopes = {};
  static bool get hasQueueOwner => _queueScopes.isNotEmpty;
  static void bindQueueTasks(Iterable<String> ids) {
    final scope = Zone.current[_key] as ExternalBillingScope?;
    if (scope == null) return;
    for (final id in ids) {
      _queueScopes.putIfAbsent(id, () => scope);
    }
  }

  /// Queue callbacks may resume from a UI event outside the original Zone.
  static Future<T> runQueueTask<T>(String id, Future<T> Function() action) {
    final scope = _queueScopes[id];
    return scope == null
        ? action()
        : runZoned(action, zoneValues: {_key: scope});
  }

  static AbortSignal? get currentSignal =>
      (Zone.current[_key] as ExternalBillingScope?)?.signal;
  static CancelToken? get cancelToken =>
      (Zone.current[_key] as ExternalBillingScope?)?._cancelToken;
  static Future<void> check(
    String kind,
    Map<String, dynamic> parameters,
  ) async {
    final scope = Zone.current[_key] as ExternalBillingScope?;
    if (scope != null) await scope.beforeRequest(kind, parameters);
  }

  Future<T> run<T>(Future<T> Function() action) async {
    void cancel(String? _) =>
        _cancelToken.cancel('External operation cancelled');
    throwIfAborted(signal);
    signal?.addListener(cancel);
    try {
      return await runZoned(action, zoneValues: {_key: this});
    } finally {
      signal?.removeListener(cancel);
      _queueScopes.removeWhere((_, scope) => identical(scope, this));
    }
  }
}
