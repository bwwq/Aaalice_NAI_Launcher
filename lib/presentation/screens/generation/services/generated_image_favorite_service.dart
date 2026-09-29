import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/image_save_utils.dart';
import '../../../../core/utils/localization_extension.dart';
import '../../../../data/repositories/gallery_folder_repository.dart';
import '../../../providers/image_generation_provider.dart';
import '../../../providers/local_gallery_provider.dart';
import '../../../providers/local_image_favorite_provider.dart';
import '../../../widgets/common/app_toast.dart';

final generatedImageFavoriteProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, id) async {
      final path = ref.watch(
        imageGenerationNotifierProvider.select(
          (state) => state.findImageById(id)?.filePath,
        ),
      );
      if (path == null || path.isEmpty) return false;
      return ref.watch(localImageFavoriteProvider(path).future);
    });

final generatedImageFavoriteServiceProvider = Provider((ref) {
  final gallery = ref.read(localGalleryNotifierProvider.notifier);
  final generation = ref.read(imageGenerationNotifierProvider.notifier);
  return GeneratedImageFavoriteService(
    resolveImage: (id) =>
        ref.read(imageGenerationNotifierProvider).findImageById(id),
    saveImage: (image) async {
      final root = await GalleryFolderRepository.instance.getRootPath();
      if (root == null || root.isEmpty) {
        throw const MissingGallerySaveDirectory();
      }
      return ImageSaveUtils.saveBytesToDatedPath(
        rootPath: root,
        bytes: image.bytes,
        seed: await ImageSaveUtils.resolveSeed(
          metadata: image.metadata,
          bytes: image.bytes,
        ),
      );
    },
    registerImage: (image, path) async {
      generation.updateImageFilePath(image.id, path);
      await gallery.addNewlySavedImages([path]);
    },
    toggleFavorite: (path) => gallery.toggleFavorite(path, rethrowError: true),
  );
});

class MissingGallerySaveDirectory implements Exception {
  const MissingGallerySaveDirectory();
}

/// Shares persistence and the in-flight operation across preview and history.
class GeneratedImageFavoriteService {
  GeneratedImageFavoriteService({
    required this.resolveImage,
    required this.saveImage,
    required this.registerImage,
    required this.toggleFavorite,
  });

  final GeneratedImage? Function(String id) resolveImage;
  final Future<String> Function(GeneratedImage image) saveImage;
  final Future<void> Function(GeneratedImage image, String path) registerImage;
  final Future<bool> Function(String path) toggleFavorite;
  final Map<String, Future<bool>> _pending = {};

  Future<bool> toggle(GeneratedImage image) => _pending.putIfAbsent(
    image.id,
    () => _toggle(image).whenComplete(() {
      _pending.remove(image.id);
    }),
  );

  Future<bool> _toggle(GeneratedImage original) async {
    final image = resolveImage(original.id) ?? original;
    if (!image.canFavorite) throw StateError('Image cannot be favorited');
    var path = image.filePath;
    if (path == null || path.isEmpty || !await File(path).exists()) {
      path = await saveImage(image);
      await registerImage(image, path);
    }
    return toggleFavorite(path);
  }
}

Future<void> toggleGeneratedImageFavorite(
  BuildContext context,
  WidgetRef ref,
  GeneratedImage image,
) async {
  final service = ref.read(generatedImageFavoriteServiceProvider);
  final l10n = context.l10n;
  try {
    final favorite = await service.toggle(image);
    if (!context.mounted) return;
    AppToast.success(
      context,
      favorite ? l10n.toast_favorited : l10n.toast_unfavorited,
    );
  } catch (error) {
    if (!context.mounted) return;
    AppToast.error(
      context,
      error is MissingGallerySaveDirectory
          ? l10n.localGallery_saveDirectoryNotSet
          : l10n.toast_favoriteUpdateFailed('$error'),
    );
  }
}
