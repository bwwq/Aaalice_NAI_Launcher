import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:nai_launcher/core/cloud_sync/backup_automation.dart';
import 'package:nai_launcher/core/cloud_sync/backup_change_bus.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/presentation/providers/cloud_sync/backup_automation_provider.dart';
import 'package:nai_launcher/presentation/providers/cloud_sync/cloud_sync_ui_provider.dart';

void main() {
  test(
    'portable edits queue backup; metadata and restore writes do not',
    () async {
      final root = await Directory.systemTemp.createTemp('backup-automation-');
      Hive.init(root.path);
      final settings = await Hive.openBox<dynamic>('settings');
      await Hive.openBox<String>('random_presets');
      final storage = LocalStorageService();
      await storage.setSetting(
        StorageKeys.cloudSyncConfiguration,
        jsonEncode({
          'backend': 's3',
          'serverUrl': 'https://example.test',
          'bucket': 'images',
          'path': 'backup',
        }),
      );
      var controller = BackupAutomationController(
        storage: storage,
        readState: () => const CloudSyncUiState(
          connectionStatus: CloudSyncConnectionStatus.connected,
        ),
        upload: () async {},
      );
      addTearDown(() async {
        controller.dispose();
        await Hive.close();
        await root.delete(recursive: true);
      });
      controller.configure(
        const BackupAutomationPreferences(onChange: true, delayMinutes: 17),
      );
      await settings.put(StorageKeys.themeType, 3);
      await Future<void>.delayed(Duration.zero);
      expect(controller.engine.pendingChange, isNotNull);
      controller.cancelPending();
      await settings.put('backup_automation_unrelated', 'metadata');
      await Future<void>.delayed(Duration.zero);
      expect(controller.engine.pendingChange, isNull);
      await BackupChangeBus.duringRestore(() async {
        await settings.put(StorageKeys.themeType, 4);
        BackupChangeBus.notify('gallery');
        await Future<void>.delayed(Duration.zero);
      });
      expect(controller.engine.pendingChange, isNull);
      await Hive.box<String>('random_presets').put('preset', '{}');
      await Future<void>.delayed(Duration.zero);
      expect(controller.engine.pendingChange, isNotNull);
      final saved = settings.keys
          .where((key) => key.toString().startsWith('backup_automation_v1_'))
          .single;
      final stored =
          jsonDecode(settings.get(saved) as String) as Map<String, dynamic>;
      expect(stored['pendingChangeAt'], isNotNull);
      stored['pendingChangeAt'] = DateTime.utc(2000).toIso8601String();
      await settings.put(saved, jsonEncode(stored));
      controller.dispose();
      controller = BackupAutomationController(
        storage: storage,
        readState: () => const CloudSyncUiState(
          connectionStatus: CloudSyncConnectionStatus.connected,
        ),
        upload: () async {},
      );
      expect(controller.engine.preferences.delayMinutes, 17);
      expect(
        controller.engine.pendingChange!.isAfter(
          DateTime.now().add(const Duration(minutes: 16)),
        ),
        isTrue,
      );
    },
  );
}
