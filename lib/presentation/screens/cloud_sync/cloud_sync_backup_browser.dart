import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cloud_sync/backup_content_preview.dart';
import '../../../core/utils/localization_extension.dart';
import '../../adaptive/adaptive_presenter.dart';
import '../../providers/cloud_sync/cloud_sync_ui_provider.dart';
import '../../providers/cloud_sync/cloud_sync_error_reporter.dart';
import 'cloud_sync_preview_panel.dart';
import 'cloud_sync_widgets.dart';

Future<void> showCloudSyncBackupBrowser({
  required BuildContext context,
  required CloudSyncUiPort port,
  required CloudSyncSnapshotView snapshot,
}) async {
  final loading = port.previewRestoreSnapshot(snapshot.id);
  // Attach an error handler immediately, even if the route has not built yet.
  final result = loading.then<Object?>((_) => null, onError: (Object e) => e);
  try {
    await AdaptivePresenter.showPanel<void>(
      context: context,
      title: context.l10n.cloudSync_backupContents,
      dialogWidth: 760,
      initialChildSize: .92,
      minChildSize: .62,
      maxChildSize: .96,
      builder: (context, controller) => CloudSyncBackupBrowser(
        snapshot: snapshot,
        port: port,
        loading: result,
        scrollController: controller,
      ),
    );
  } finally {
    await port.cancel();
  }
}

class CloudSyncBackupBrowser extends ConsumerStatefulWidget {
  const CloudSyncBackupBrowser({
    super.key,
    required this.snapshot,
    required this.port,
    required this.loading,
    required this.scrollController,
  });
  final CloudSyncSnapshotView snapshot;
  final CloudSyncUiPort port;
  final Future<Object?> loading;
  final ScrollController scrollController;

  @override
  ConsumerState<CloudSyncBackupBrowser> createState() => _BrowserState();
}

class _BrowserState extends ConsumerState<CloudSyncBackupBrowser> {
  String _query = '';
  bool _restoring = false;
  String? _restoreError;

  Future<void> _restore() async {
    setState(() {
      _restoring = true;
      _restoreError = null;
    });
    try {
      await widget.port.confirmRestoreSnapshot();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _restoreError = cloudSyncErrorMessage(error));
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cloudSyncUiStateProvider);
    final preview = state.pendingPreview;
    return PopScope(
      canPop: !_restoring,
      child: SizedBox(
        height: math.min(740.0, MediaQuery.sizeOf(context).height * .76),
        child: FutureBuilder<Object?>(
          future: widget.loading,
          builder: (context, result) {
            final ready =
                result.connectionState == ConnectionState.done &&
                result.data == null &&
                preview?.snapshotId == widget.snapshot.id;
            final items = ready
                ? preview!.contents
                      .where(
                        (item) =>
                            '${item.title}\n${item.text}\n${_group(context, item.group)}'
                                .toLowerCase()
                                .contains(_query),
                      )
                      .toList()
                : <BackupContentItem>[];
            return ListView.builder(
              key: const ValueKey('backup-browser-list'),
              controller: widget.scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: 1 + items.length + (ready ? 1 : 0),
              itemBuilder: (context, index) {
                if (ready && index == items.length + 1) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_restoreError != null)
                        Text(localizeCloudSyncError(context, _restoreError!)),
                      CloudSyncPreviewPanel(
                        state: state,
                        onClose: () async => Navigator.of(context).pop(),
                        onRestore: _restore,
                      ),
                    ],
                  );
                }
                if (index > 0) return _ContentRow(item: items[index - 1]);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.snapshot.createdAt
                          .toLocal()
                          .toString()
                          .split('.')
                          .first,
                    ),
                    if (!widget.snapshot.encrypted)
                      Text(context.l10n.cloudSync_legacyUnencrypted),
                    const SizedBox(height: 12),
                    if (result.connectionState != ConnectionState.done) ...[
                      const LinearProgressIndicator(),
                      Text(context.l10n.common_loading),
                    ] else if (result.data != null)
                      Text(localizeCloudSyncError(context, state.error ?? '')),
                    if (!ready && _restoreError != null)
                      Text(localizeCloudSyncError(context, _restoreError!)),
                    if (ready) ...[
                      TextField(
                        key: const ValueKey('backup-content-search'),
                        decoration: InputDecoration(
                          labelText:
                              context.l10n.cloudSync_searchBackupContents,
                          prefixIcon: const Icon(Icons.search),
                        ),
                        onChanged: (value) =>
                            setState(() => _query = value.toLowerCase()),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        context.l10n.cloudSync_backupItemCount(items.length),
                      ),
                      if (items.isEmpty)
                        Text(context.l10n.cloudSync_noBackupContents),
                    ] else
                      TextButton(
                        onPressed: _restoring
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: Text(context.l10n.common_close),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ContentRow extends StatefulWidget {
  const _ContentRow({required this.item});
  final BackupContentItem item;
  @override
  State<_ContentRow> createState() => _ContentRowState();
}

class _ContentRowState extends State<_ContentRow> {
  Future<Uint8List>? _image;
  @override
  void didUpdateWidget(covariant _ContentRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.item, widget.item)) _image = null;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return ExpansionTile(
      title: Text(
        item.title.isEmpty ? _group(context, item.group) : item.title,
      ),
      subtitle: Text(
        '${_group(context, item.group)}${item.bytes == null ? '' : ' · ${formatCloudBytes(item.bytes!)}'}',
      ),
      children: [
        if (item.text.isNotEmpty) SelectableText(item.text),
        if (item.readImage != null && _image == null)
          TextButton.icon(
            onPressed: () => setState(() => _image = item.readImage!()),
            icon: const Icon(Icons.image_outlined),
            label: Text(context.l10n.cloudSync_viewBackupImage),
          ),
        if (_image != null)
          FutureBuilder<Uint8List>(
            future: _image,
            builder: (context, result) {
              if (result.hasError) {
                return Text(context.l10n.cloudSync_backupImageUnavailable);
              }
              if (!result.hasData) return const LinearProgressIndicator();
              return Image.memory(
                result.data!,
                cacheWidth: 1024,
                height: 300,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) =>
                    Text(context.l10n.cloudSync_backupImageUnavailable),
              );
            },
          ),
      ],
    );
  }
}

String _group(BuildContext context, String group) => switch (group) {
  'gallery-favorite-images' => context.l10n.cloudSync_favoriteOriginals,
  'gallery-albums' => context.l10n.cloudSync_galleryAlbums,
  'online-gallery-favorites' => context.l10n.cloudSync_onlineGalleryFavorites,
  'gallery-blacklist' => context.l10n.cloudSync_onlineGallerySettings,
  'portable-settings' => context.l10n.cloudSync_kindSettings,
  'vibe-library' => context.l10n.cloudSync_vibes,
  'precise-ref-library' => context.l10n.cloudSync_preciseReferences,
  'agent-system-prompt' ||
  'agent-skills' => context.l10n.cloudSync_agentContentTitle,
  _ => context.l10n.cloudSync_promptsAndTags,
};
