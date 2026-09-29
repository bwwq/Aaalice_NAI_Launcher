import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'local_gallery_provider.dart';

/// Invalidates readers even when the changed image is outside the gallery page.
final galleryFavoriteRevisionProvider = StateProvider<int>((ref) => 0);

final localImageFavoriteProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, path) async {
      ref.watch(galleryFavoriteRevisionProvider);
      final gallery = ref.read(localGalleryNotifierProvider.notifier);
      final service = await gallery.getService();
      return service.isFavorite(path);
    });
