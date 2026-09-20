import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/backup_automation.dart';

void main() {
  late DateTime time;
  late int uploads;
  late bool ready;
  late BackupAutomation automation;
  setUp(() {
    time = DateTime(2026, 9, 20, 12);
    uploads = 0;
    ready = true;
    automation = BackupAutomation(
      now: () => time,
      upload: () async {
        uploads++;
      },
      canRun: () => ready,
      changed: () {},
    );
  });
  test('both triggers default off', () async {
    automation.markChanged();
    time = time.add(const Duration(days: 1));
    await automation.tick();
    expect(uploads, 0);
  });
  test('each edit restarts the configurable delay', () async {
    automation.configure(
      const BackupAutomationPreferences(onChange: true, delayMinutes: 7),
    );
    automation.markChanged();
    time = time.add(const Duration(minutes: 6));
    automation.markChanged();
    time = time.add(const Duration(minutes: 6));
    await automation.tick();
    expect(uploads, 0);
    time = time.add(const Duration(minutes: 1));
    await automation.tick();
    expect(uploads, 1);
    expect(automation.pendingChange, isNull);
  });
  test('scheduled time does not bypass a pending edit grace period', () async {
    automation.configure(
      const BackupAutomationPreferences(
        scheduled: true,
        minuteOfDay: 12 * 60 + 1,
        onChange: true,
        delayMinutes: 5,
      ),
    );
    automation.markChanged();
    time = time.add(const Duration(minutes: 1));
    await automation.tick();
    expect(uploads, 0);
    time = time.add(const Duration(minutes: 4));
    await automation.tick();
    expect(uploads, 1);
  });
  test('cancel pending protects against accidental edits', () async {
    automation.configure(const BackupAutomationPreferences(onChange: true));
    automation.markChanged();
    automation.cancelPending();
    time = time.add(const Duration(hours: 1));
    await automation.tick();
    expect(uploads, 0);
  });
  test('custom local daily time waits while busy and uploads once', () async {
    automation.configure(
      const BackupAutomationPreferences(
        scheduled: true,
        minuteOfDay: 12 * 60 + 23,
      ),
    );
    time = DateTime(2026, 9, 20, 12, 23);
    ready = false;
    await automation.tick();
    expect(uploads, 0);
    ready = true;
    await automation.tick();
    await automation.tick();
    expect(uploads, 1);
    expect(automation.nextScheduled, DateTime(2026, 9, 21, 12, 23));
  });
  test(
    'edits during an upload remain queued and uploads never overlap',
    () async {
      final completed = Completer<void>();
      automation = BackupAutomation(
        now: () => time,
        canRun: () => ready,
        upload: () async {
          uploads++;
          await completed.future;
        },
        changed: () {},
      );
      automation.configure(
        const BackupAutomationPreferences(onChange: true, delayMinutes: 1),
      );
      automation.markChanged();
      time = time.add(const Duration(minutes: 1));
      final active = automation.tick();
      automation.markChanged();
      await automation.tick();
      expect(uploads, 1);
      completed.complete();
      await active;
      expect(automation.pendingChange, isNotNull);
    },
  );
  test(
    'failed upload retries after five minutes and can be cancelled',
    () async {
      automation = BackupAutomation(
        now: () => time,
        canRun: () => true,
        upload: () async {
          uploads++;
          throw StateError('offline');
        },
        changed: () {},
      );
      automation.configure(
        const BackupAutomationPreferences(onChange: true, delayMinutes: 1),
      );
      automation.markChanged();
      time = time.add(const Duration(minutes: 1));
      await automation.tick();
      await automation.tick();
      expect(uploads, 1);
      expect(automation.failed, isTrue);
      automation.cancelPending();
      time = time.add(const Duration(minutes: 6));
      await automation.tick();
      expect(uploads, 1);
    },
  );
  test('preferences persist custom time and delay with validation', () {
    const prefs = BackupAutomationPreferences(
      scheduled: true,
      minuteOfDay: 83,
      onChange: true,
      delayMinutes: 42,
    );
    final restored = BackupAutomationPreferences.fromJson(prefs.toJson());
    expect(restored.minuteOfDay, 83);
    expect(restored.delayMinutes, 42);
    expect(
      () => BackupAutomationPreferences.fromJson({'delayMinutes': 0}),
      throwsFormatException,
    );
  });
}
