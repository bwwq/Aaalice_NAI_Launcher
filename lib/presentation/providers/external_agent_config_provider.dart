import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/external_agent/external_agent_models.dart';
import '../../core/storage/local_storage_service.dart';

/// Connection and spending are device-local and excluded from cloud settings.
const externalAgentConfigKey = 'external_agent_device_config_v1';
final externalAgentConfigProvider =
    NotifierProvider<ExternalAgentConfigNotifier, ExternalAgentConfig>(
      ExternalAgentConfigNotifier.new,
    );
final builtInAgentEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(externalAgentConfigProvider.select((c) => c.builtInEnabled)),
);

class ExternalAgentConfigNotifier extends Notifier<ExternalAgentConfig> {
  Future<void> _updates = Future.value();
  @override
  ExternalAgentConfig build() {
    final raw = ref
        .read(localStorageServiceProvider)
        .getSetting<String>(externalAgentConfigKey);
    return raw == null
        ? const ExternalAgentConfig()
        : ExternalAgentConfig.fromJson(
            Map<String, dynamic>.from(jsonDecode(raw) as Map),
          );
  }

  Future<void> updateWith(
    ExternalAgentConfig Function(ExternalAgentConfig) change,
  ) {
    final result = _updates
        .catchError((Object _) {})
        .then((_) => _save(change(state)));
    _updates = result;
    return result;
  }

  Future<void> _save(ExternalAgentConfig config) async {
    if (config.port < 1024 ||
        config.port > 65535 ||
        config.budget < 0 ||
        config.perCallBudget < 0) {
      throw ArgumentError('Invalid port or budget.');
    }
    await ref
        .read(localStorageServiceProvider)
        .setSetting(externalAgentConfigKey, jsonEncode(config.toJson()));
    state = config;
  }

  Future<void> recordSpent(int value, String day) =>
      updateWith((c) => c.copyWith(spent: value, spentDay: day));
}
