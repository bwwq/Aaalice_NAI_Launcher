import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/cache/local_gallery_thumbnail_provider.dart';
import '../../../../core/utils/localization_extension.dart';
import '../../../../core/utils/thumbnail_image_normalizer.dart';
import '../../../../data/models/gallery/local_image_record.dart';
import '../../../../data/services/gallery/local_gallery_service.dart';
import '../../../adaptive/adaptive_presenter.dart';
import '../../../providers/image_generation_provider.dart';
import '../../../providers/local_gallery_provider.dart';
import '../../../providers/local_image_favorite_provider.dart';
import '../../../widgets/common/decoded_memory_image.dart';
import '../../../widgets/common/horizontal_segmented_control.dart';
import '../../../widgets/common/image_picker_card/image_picker_result.dart';
import '../../../widgets/common/image_viewport_surface.dart';

final thumbnailFavoritesProvider = FutureProvider.autoDispose
    .family<LocalGalleryQueryPage, int>((ref, page) async {
      ref.watch(galleryFavoriteRevisionProvider);
      final gallery = ref.read(localGalleryNotifierProvider.notifier);
      final service = await gallery.getService();
      return service.queryPage(page: page, favoritesOnly: true);
    });

final thumbnailHistoryReadyProvider = FutureProvider.autoDispose<void>((ref) {
  return ref
      .read(imageGenerationNotifierProvider.notifier)
      .ensureGenerationHistoryRestored();
});

final thumbnailImageNormalizerProvider =
    Provider<Future<Uint8List> Function(Uint8List)>(
      (ref) =>
          (bytes) => compute(normalizeThumbnailImageToPng, bytes),
    );

/// Picks a private, normalized preview image; never changes gallery selection.
class ThumbnailSourcePicker extends ConsumerStatefulWidget {
  const ThumbnailSourcePicker({super.key, required this.scrollController});

  final ScrollController scrollController;

  static Future<ImagePickerResult?> show(BuildContext context) =>
      AdaptivePresenter.showPicker<ImagePickerResult>(
        context: context,
        width: 720,
        maxCenteredHeight: 680,
        builder: (context, controller) =>
            ThumbnailSourcePicker(scrollController: controller),
      );

  @override
  ConsumerState<ThumbnailSourcePicker> createState() =>
      _ThumbnailSourcePickerState();
}

class _ThumbnailSourcePickerState extends ConsumerState<ThumbnailSourcePicker> {
  bool _history = false;
  bool _busy = false;
  int _page = 0;
  Object? _error;

  Future<void> _select(Future<ImagePickerResult?> Function() read) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await read();
      if (result == null || !mounted) return;
      final normalize = ref.read(thumbnailImageNormalizerProvider);
      final bytes = await normalize(result.bytes);
      if (!mounted) return;
      Navigator.of(context).pop(
        ImagePickerResult(
          bytes: bytes,
          fileName: result.fileName,
          path: result.path,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<ImagePickerResult?> _readFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedThumbnailImageExtensions,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    final bytes =
        file.bytes ??
        (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null) {
      throw const FileSystemException('Image data unavailable');
    }
    return ImagePickerResult(
      bytes: bytes,
      fileName: file.name,
      path: file.path,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      child: CustomScrollView(
        controller: widget.scrollController,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.tagLibrary_selectImage,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    tooltip: l10n.common_cancel,
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HorizontalSegmentedControl(
                    child: SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                          value: false,
                          label: Text(l10n.imagePicker_favoriteImages),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text(l10n.generation_historyRecord),
                        ),
                      ],
                      selected: {_history},
                      onSelectionChanged: _busy
                          ? null
                          : (value) => setState(() {
                              _history = value.single;
                              _error = null;
                            }),
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('thumbnail-source-file'),
                    onPressed: _busy ? null : () => _select(_readFile),
                    icon: const Icon(Icons.folder_open),
                    label: Text(l10n.imagePicker_chooseLocalFile),
                  ),
                ],
              ),
            ),
          ),
          if (_busy)
            const SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(),
                ),
              ),
            ),
          if (_error != null)
            _loadError(_error!, () => setState(() => _error = null))
          else if (_history)
            _buildHistory()
          else
            _buildFavorites(),
        ],
      ),
    );
  }

  Widget _loading() => const SliverFillRemaining(
    hasScrollBody: false,
    child: Center(child: CircularProgressIndicator()),
  );

  Widget _buildFavorites() => ref
      .watch(thumbnailFavoritesProvider(_page))
      .when(
        loading: _loading,
        error: (error, stack) => _loadError(
          error,
          () => ref.invalidate(thumbnailFavoritesProvider(_page)),
        ),
        data: (page) => SliverMainAxisGroup(
          slivers: [
            if (page.records.isEmpty)
              _message(context.l10n.imagePicker_noFavoriteImages)
            else
              _grid(
                page.records.length,
                (index) => _favoriteTile(page.records[index]),
              ),
            if (page.page > 0 || page.hasMore)
              SliverToBoxAdapter(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: context.l10n.pagination_previousPage,
                      icon: const Icon(Icons.chevron_left),
                      onPressed: !_busy && _page > 0
                          ? () => _changePage(_page - 1)
                          : null,
                    ),
                    Text(
                      '${page.page + 1} / ${(page.totalCount / page.pageSize).ceil().clamp(1, 1 << 30)}',
                    ),
                    IconButton(
                      tooltip: context.l10n.pagination_nextPage,
                      icon: const Icon(Icons.chevron_right),
                      onPressed: !_busy && page.hasMore
                          ? () => _changePage(_page + 1)
                          : null,
                    ),
                  ],
                ),
              ),
          ],
        ),
      );

  void _changePage(int page) {
    setState(() => _page = page);
    if (widget.scrollController.hasClients) widget.scrollController.jumpTo(0);
  }

  Widget _buildHistory() {
    final ready = ref.watch(thumbnailHistoryReadyProvider);
    if (ready.isLoading) {
      return _loading();
    }
    if (ready.hasError) {
      return _loadError(
        ready.error!,
        () => ref.invalidate(thumbnailHistoryReadyProvider),
      );
    }
    final images = ref
        .watch(imageGenerationNotifierProvider.select((state) => state.history))
        .where((image) => image.canUseAsGenerationInput)
        .toList();
    if (images.isEmpty) return _message(context.l10n.generation_noHistory);
    return _grid(images.length, (index) {
      final image = images[index];
      return _tile(
        label: '${context.l10n.generation_historyRecord} ${index + 1}',
        onTap: () => _select(
          () async => ImagePickerResult(
            bytes: image.bytes,
            fileName: 'history_${image.id}.png',
            path: image.filePath,
          ),
        ),
        child: DecodedMemoryImage(
          bytes: image.bytes,
          errorBuilder: _imageError,
        ),
      );
    });
  }

  Widget _favoriteTile(LocalImageRecord record) => _tile(
    label: p.basename(record.path),
    onTap: () => _select(
      () async => ImagePickerResult(
        bytes: await File(record.path).readAsBytes(),
        fileName: p.basename(record.path),
        path: record.path,
      ),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) => Image(
        image: LocalGalleryThumbnailProvider(
          source: LocalGallerySourceIdentity.fromRecord(
            path: record.path,
            size: record.size,
            modifiedAt: record.modifiedAt,
          ),
          target: LocalGalleryThumbnailTarget.fromLogicalSize(
            logicalWidth: constraints.maxWidth,
            logicalHeight: constraints.maxHeight,
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          ),
        ),
        fit: BoxFit.cover,
        errorBuilder: _imageError,
      ),
    ),
  );

  Widget _tile({
    required String label,
    required VoidCallback onTap,
    required Widget child,
  }) => Semantics(
    button: true,
    label: label,
    child: Material(
      color: ImageViewportSurface.background,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          Material(
            color: Colors.transparent,
            child: InkWell(onTap: _busy ? null : onTap),
          ),
        ],
      ),
    ),
  );

  Widget _grid(int count, Widget Function(int) tile) => SliverPadding(
    padding: const EdgeInsets.all(12),
    sliver: SliverGrid.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: count,
      itemBuilder: (context, index) => tile(index),
    ),
  );

  Widget _message(String text) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(text, textAlign: TextAlign.center),
      ),
    ),
  );

  Widget _loadError(Object error, VoidCallback retry) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.l10n.imagePicker_fileSelectionFailed('$error')),
            TextButton(
              onPressed: retry,
              child: Text(context.l10n.common_retry),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _imageError(BuildContext context, Object error, StackTrace? stack) =>
      const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.white),
      );
}
