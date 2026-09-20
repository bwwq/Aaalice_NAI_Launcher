import 'package:flutter/material.dart';
import '../../../core/utils/localization_extension.dart';
import 'cloud_sync_widgets.dart';

class CloudSyncRetentionControl extends StatelessWidget {
  const CloudSyncRetentionControl({
    super.key,
    required this.value,
    this.onChanged,
  });
  final int value;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) => CloudSyncSection(
    title: context.l10n.cloudSync_keepSnapshots,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(context.l10n.cloudSync_retentionDescription),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          key: ValueKey('backup-retention-$value'),
          initialValue: value,
          isExpanded: true,
          isDense: false,
          itemHeight: null,
          menuMaxHeight: 320,
          items: [
            for (var count = 1; count <= 100; count++)
              DropdownMenuItem(value: count, child: Text('$count')),
          ],
          onChanged: onChanged == null
              ? null
              : (count) {
                  if (count != null) onChanged!(count);
                },
        ),
      ],
    ),
  );
}
