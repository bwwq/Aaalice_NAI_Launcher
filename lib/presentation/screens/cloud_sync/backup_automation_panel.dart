import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cloud_sync/backup_automation.dart';
import '../../../core/utils/localization_extension.dart';
import '../../providers/cloud_sync/backup_automation_provider.dart';
import '../../providers/cloud_sync/cloud_sync_ui_provider.dart';
import 'cloud_sync_widgets.dart';

class BackupAutomationPanel extends ConsumerWidget {
  const BackupAutomationPanel({super.key, required this.busy});
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(backupAutomationProvider);
    final controller = ref.read(backupAutomationProvider.notifier);
    final engine = controller.engine;
    final preferences = engine.preferences;
    final time = TimeOfDay(
      hour: preferences.minuteOfDay ~/ 60,
      minute: preferences.minuteOfDay % 60,
    );
    return CloudSyncSection(
      title: context.l10n.cloudSync_automaticBackup,
      subtitle: context.l10n.cloudSync_automaticBackupDescription,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: const ValueKey('backup-schedule-enabled'),
            contentPadding: EdgeInsets.zero,
            value: preferences.scheduled,
            title: Text(context.l10n.cloudSync_dailyBackup),
            onChanged: busy
                ? null
                : (value) => controller.configure(
                    preferences.copyWith(scheduled: value),
                  ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.cloudSync_backupTime),
            subtitle: Text(time.format(context)),
            trailing: const Icon(Icons.schedule),
            onTap: busy
                ? null
                : () async {
                    final selected = await showTimePicker(
                      context: context,
                      initialTime: time,
                    );
                    if (selected != null && context.mounted) {
                      controller.configure(
                        preferences.copyWith(
                          minuteOfDay: selected.hour * 60 + selected.minute,
                        ),
                      );
                    }
                  },
          ),
          SwitchListTile(
            key: const ValueKey('backup-change-enabled'),
            contentPadding: EdgeInsets.zero,
            value: preferences.onChange,
            title: Text(context.l10n.cloudSync_changeBackup),
            subtitle: Text(context.l10n.cloudSync_changeBackupDescription),
            onChanged: busy
                ? null
                : (value) => controller.configure(
                    preferences.copyWith(onChange: value),
                  ),
          ),
          ListTile(
            key: const ValueKey('backup-change-delay'),
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.cloudSync_changeDelay),
            subtitle: Text(
              context.l10n.cloudSync_delayMinutes(preferences.delayMinutes),
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: busy
                ? null
                : () => _editDelay(context, controller, preferences),
          ),
          if (engine.nextRun != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                context.l10n.cloudSync_nextBackup(
                  engine.nextRun!.toLocal().toString().split('.').first,
                ),
              ),
            ),
          if (engine.failed)
            Text(
              context.l10n.cloudSync_autoBackupFailed,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (engine.pendingChange != null || engine.failed)
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: busy ? null : controller.cancelPending,
                  child: Text(context.l10n.cloudSync_cancelPendingBackup),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          try {
                            await ref.read(cloudSyncUiPortProvider).pushNow();
                            controller.cancelPending();
                          } catch (error) {
                            if (context.mounted) {
                              showCloudSyncActionError(context, error);
                            }
                          }
                        },
                  child: Text(context.l10n.cloudSync_backupNow),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _editDelay(
    BuildContext context,
    BackupAutomationController controller,
    BackupAutomationPreferences preferences,
  ) async {
    final input = TextEditingController(text: '${preferences.delayMinutes}');
    final form = GlobalKey<FormState>();
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.cloudSync_changeDelay),
        content: Form(
          key: form,
          child: TextFormField(
            controller: input,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: context.l10n.cloudSync_minutesRange,
            ),
            validator: (text) {
              final value = int.tryParse(text ?? '');
              return value == null || value < 1 || value > 1440
                  ? context.l10n.cloudSync_minutesRange
                  : null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cloudSync_cancel),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, int.parse(input.text));
              }
            },
            child: Text(context.l10n.common_save),
          ),
        ],
      ),
    );
    input.dispose();
    if (result != null && context.mounted) {
      controller.configure(preferences.copyWith(delayMinutes: result));
    }
  }
}
