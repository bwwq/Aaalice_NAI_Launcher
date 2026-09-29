import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/storage/local_storage_service.dart';

final onlineGalleryEnabledProvider =
    NotifierProvider<OnlineGalleryEnabledNotifier, bool>(
      OnlineGalleryEnabledNotifier.new,
    );

class OnlineGalleryEnabledNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref
          .watch(localStorageServiceProvider)
          .getSetting<bool>(StorageKeys.onlineGalleryEnabled) ??
      false;

  Future<void> setEnabled(bool enabled) async {
    await ref
        .read(localStorageServiceProvider)
        .setSetting(StorageKeys.onlineGalleryEnabled, enabled);
    state = enabled;
  }
}
