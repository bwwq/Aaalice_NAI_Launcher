import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../core/cloud_sync/backup_automation.dart';
import '../../../core/cloud_sync/backup_change_bus.dart';
import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/local_storage_service.dart';
import '../../../core/utils/app_logger.dart';
import '../../../data/cloud_sync/app_cloud_sync_adapters.dart';
import '../../../data/models/vibe/vibe_library_entry.dart';
import '../../../data/models/vibe/vibe_library_category.dart';
import '../../../data/models/precise_ref/precise_ref_library_entry.dart';
import 'cloud_sync_ui_provider.dart';
import 'cloud_sync_provider_wiring.dart';

final backupAutomationProvider =
    StateNotifierProvider<BackupAutomationController, int>((ref) {
      return BackupAutomationController(
        storage: ref.watch(localStorageServiceProvider),
        readState: () => ref.read(cloudSyncUiStateProvider),
        upload: () =>
            ref.read(cloudSyncApplicationServiceProvider).pushAutomatically(),
      );
    });

class BackupAutomationController extends StateNotifier<int> {
  BackupAutomationController({
    required this.storage,
    required this.readState,
    required Future<void> Function() upload,
  }) : super(0) {
    engine = BackupAutomation(
      now: DateTime.now,
      upload: upload,
      canRun: () {
        final current = readState();
        return current.isConnected &&
            !current.isBusy &&
            !current.needsPreviewConfirmation &&
            !current.needsConflictResolution &&
            !BackupChangeBus.restoring;
      },
      changed: _changed,
    );
    _bus = BackupChangeBus.events.listen((group) {
      final content = readState().contentSelection;
      if ((group == 'galleryFavorites' &&
              content.includeGalleryFavoriteImages) ||
          (group == 'galleryAlbums' && content.includeGalleryAlbums)) {
        engine.markChanged();
      }
    });
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }
  final LocalStorageService storage;
  final CloudSyncUiState Function() readState;
  late final BackupAutomation engine;
  late final StreamSubscription<String> _bus;
  Timer? _timer;
  final Map<String, StreamSubscription<BoxEvent>> _watches = {};
  String? _configurationKey;
  bool _loading = false;
  Future<void> _saveFlight = Future.value();

  void _bindConnection() {
    final raw =
        storage.getSetting<String>(StorageKeys.cloudDriveConfiguration) ??
        storage.getSetting<String>(StorageKeys.cloudSyncConfiguration);
    String? key;
    if (raw != null) {
      try {
        final config = jsonDecode(raw) as Map;
        final identity = [
          'backend',
          'serverUrl',
          'bucket',
          'region',
          'pathStyle',
          'owner',
          'repository',
          'branch',
          'accountId',
          'path',
        ].map((name) => config[name]).toList();
        key =
            'backup_automation_v1_${sha256.convert(utf8.encode(jsonEncode(identity)))}';
      } on Object {
        return;
      }
    }
    if (key == _configurationKey) return;
    _loading = true;
    _configurationKey = key;
    engine.cancelPending();
    var preferences = const BackupAutomationPreferences();
    DateTime? pending;
    if (key != null) {
      try {
        final saved = storage.getSetting<String>(key);
        if (saved != null) {
          final decoded = jsonDecode(saved) as Map<String, dynamic>;
          preferences = BackupAutomationPreferences.fromJson(decoded);
          pending = DateTime.tryParse(
            decoded['pendingChangeAt'] as String? ?? '',
          );
        }
      } on Object {
        /* Invalid schedules stay disabled. */
      }
    }
    engine.configure(preferences);
    if (preferences.onChange && pending != null) {
      final grace = DateTime.now().add(
        Duration(minutes: preferences.delayMinutes),
      );
      engine.pendingChange = pending.isAfter(DateTime.now()) ? pending : grace;
    }
    _loading = false;
    if (mounted) state++;
  }

  void _poll() {
    if (!mounted) return;
    _bindConnection();
    _attachBoxes();
    unawaited(engine.tick());
  }

  void _attachBoxes() {
    const names = [
      'settings',
      'tag_favorites',
      'tag_templates',
      'random_presets',
      'shortcuts',
      'local_favorites',
      'tag_library_user',
      'vibe_library_entries',
      'vibe_library_categories',
      'precise_ref_library_entries',
    ];
    for (final name in names) {
      if (_watches.containsKey(name) || !Hive.isBoxOpen(name)) continue;
      try {
        Stream<BoxEvent> stream;
        if (name == 'vibe_library_entries') {
          try {
            stream = Hive.box<VibeLibraryEntry>(name).watch();
          } on Object {
            stream = Hive.lazyBox<VibeLibraryEntry>(name).watch();
          }
        } else if (name == 'vibe_library_categories') {
          stream = Hive.box<VibeLibraryCategory>(name).watch();
        } else if (name == 'precise_ref_library_entries') {
          stream = Hive.box<PreciseRefLibraryEntry>(name).watch();
        } else if (name == 'random_presets') {
          stream = Hive.box<String>(name).watch();
        } else {
          stream = Hive.box<dynamic>(name).watch();
        }
        _watches[name] = stream.listen(
          (event) => _onBoxChange(name, event.key.toString()),
          onDone: () => _watches.remove(name),
        );
      } on Object {
        // A typed box may finish opening later; the next tick retries attachment.
      }
    }
  }

  void _onBoxChange(String box, String key) {
    if (!mounted || BackupChangeBus.restoring || _configurationKey == null) {
      return;
    }
    final selection = readState().contentSelection;
    var included = false;
    if (box == 'settings') {
      included =
          (selection.includeSettings && portableSettingKeys.contains(key)) ||
          (selection.includePromptsAndTags &&
              portablePromptSettingKeys.contains(key)) ||
          (selection.includeOnlineGallerySettings &&
              portableOnlineGallerySettingKeys.contains(key)) ||
          ((selection.includeAgentSystemPrompt || selection.includeSkills) &&
              key == StorageKeys.agentSettingsJson) ||
          (selection.includePromptsAndTags &&
              key == StorageKeys.promptAssistantConfigJson);
    } else if (box == 'local_favorites') {
      included = selection.includeOnlineGalleryFavorites;
    } else if (box.startsWith('vibe_library')) {
      included = selection.includeVibes;
    } else if (box.startsWith('precise_ref')) {
      included = selection.includePreciseReferences;
    } else {
      included = selection.includePromptsAndTags;
    }
    if (included) engine.markChanged();
  }

  void configure(BackupAutomationPreferences preferences) =>
      engine.configure(preferences);
  void cancelPending() => engine.cancelPending();
  void _changed() {
    if (!mounted || _loading) return;
    state++;
    final key = _configurationKey;
    if (key == null) return;
    final value = jsonEncode({
      ...engine.preferences.toJson(),
      'pendingChangeAt': engine.pendingChange?.toUtc().toIso8601String(),
    });
    _saveFlight = _saveFlight
        .then((_) => storage.setSetting(key, value))
        .catchError((Object error) {
          AppLogger.w(
            'Could not persist automatic backup settings',
            'CloudSync',
          );
        });
  }

  @override
  void dispose() {
    _timer?.cancel();
    engine.dispose();
    unawaited(_bus.cancel());
    for (final subscription in _watches.values) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}
