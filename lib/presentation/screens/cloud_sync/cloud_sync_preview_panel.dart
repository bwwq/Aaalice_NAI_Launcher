import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/localization_extension.dart';
import '../../providers/cloud_sync/cloud_sync_ui_provider.dart';
import 'cloud_sync_widgets.dart';

class CloudSyncPreviewPanel extends ConsumerWidget {
  const CloudSyncPreviewPanel({super.key, required this.state});

  final CloudSyncUiState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = state.pendingPreview!;
    final hasUnresolved = state.conflicts.any((item) => item.choice == null);
    return CloudSyncSection(
      title: preview.isUpload
          ? context.l10n.cloudSync_previewUpload
          : preview.isRestore
          ? context.l10n.cloudSync_restorePreviewTitle
          : context.l10n.cloudSync_mergePreviewTitle,
      subtitle: preview.isUpload
          ? context.l10n.cloudSync_encryptedDescription
          : preview.isRestore
          ? context.l10n.cloudSync_restorePreviewDescription
          : context.l10n.cloudSync_mergePreviewDescription,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (preview.images case final images?) ...[
            Text(
              preview.isRestore
                  ? '${context.l10n.cloudSync_favoriteOriginals}: ${images.count}, ${(images.originalBytes / 1048576).toStringAsFixed(1)} MiB'
                  : context.l10n.cloudSync_imageBackupSummary(
                      images.count,
                      (images.originalBytes / 1048576).toStringAsFixed(1),
                      (images.estimatedUploadBytes / 1048576).toStringAsFixed(
                        1,
                      ),
                    ),
            ),
            if (preview.isRestore)
              Text(
                context.l10n.cloudSync_imageRestoreSummary(
                  images.added,
                  images.reused,
                  images.nameConflicts,
                ),
              ),
            const SizedBox(height: 12),
          ],
          if (preview.isRestore) ...[
            Text(context.l10n.cloudSync_localRestoreDescription),
            const SizedBox(height: 12),
          ],
          if (preview.conflictSafeDeletionCount > 0) ...[
            CloudSyncStatusBanner(
              icon: Icons.warning_amber_rounded,
              title: context.l10n.cloudSync_previewDeletesTitle,
              message: context.l10n.cloudSync_previewDeletesDescription(
                preview.conflictSafeDeletionCount,
              ),
              warning: true,
            ),
            const SizedBox(height: 12),
          ],
          if (preview.changes.isEmpty && !preview.isUpload)
            Text(context.l10n.cloudSync_previewNoChanges)
          else
            for (final row in preview.changes)
              ListTile(
                key: ValueKey('cloud-sync-preview-${row.kind.name}'),
                contentPadding: EdgeInsets.zero,
                title: Text(_kindLabel(context, row.kind)),
                subtitle: Text(
                  context.l10n.cloudSync_previewCounts(
                    row.added,
                    row.modified,
                    row.deleted,
                  ),
                ),
              ),
          TextButton(
            onPressed: state.isBusy
                ? null
                : () => _run(context, ref.read(cloudSyncUiPortProvider).cancel),
            child: Text(context.l10n.cloudSync_cancel),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const ValueKey('cloud-sync-confirm-preview'),
              onPressed: state.isBusy || hasUnresolved
                  ? null
                  : () => _run(
                      context,
                      preview.isRestore
                          ? ref
                                .read(cloudSyncUiPortProvider)
                                .confirmRestoreSnapshot
                          : ref
                                .read(cloudSyncUiPortProvider)
                                .applyPendingPreview,
                    ),
              icon: Icon(
                preview.isRestore ? Icons.restore : Icons.merge_outlined,
              ),
              label: Text(
                preview.isUpload
                    ? context.l10n.cloudSync_confirmUpload
                    : preview.isRestore
                    ? context.l10n.cloudSync_confirmRestore
                    : context.l10n.cloudSync_confirmMerge,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _kindLabel(BuildContext context, CloudSyncDataKind kind) =>
    switch (kind) {
      CloudSyncDataKind.settings => context.l10n.cloudSync_kindSettings,
      CloudSyncDataKind.prompts => context.l10n.cloudSync_kindPrompts,
      CloudSyncDataKind.galleries => context.l10n.cloudSync_kindGalleries,
      CloudSyncDataKind.largeBinary => context.l10n.cloudSync_kindLargeFiles,
    };

Future<void> _run(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (error) {
    if (!context.mounted) return;
    showCloudSyncActionError(context, error);
  }
}
