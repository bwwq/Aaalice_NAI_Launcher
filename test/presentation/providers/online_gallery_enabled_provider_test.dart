import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/presentation/providers/online_gallery_enabled_provider.dart';

void main() {
  test('gallery is opt-in and remembers enabling and disabling', () async {
    final storage = _Storage();
    ProviderContainer open() => ProviderContainer(
      overrides: [localStorageServiceProvider.overrideWithValue(storage)],
    );
    final first = open();
    expect(first.read(onlineGalleryEnabledProvider), isFalse);
    await first.read(onlineGalleryEnabledProvider.notifier).setEnabled(true);
    first.dispose();
    final second = open();
    expect(second.read(onlineGalleryEnabledProvider), isTrue);
    await second.read(onlineGalleryEnabledProvider.notifier).setEnabled(false);
    second.dispose();
    final third = open();
    expect(third.read(onlineGalleryEnabledProvider), isFalse);
    third.dispose();
  });

  test('failed persistence leaves the feature disabled', () async {
    final storage = _Storage()..failWrites = true;
    final container = ProviderContainer(
      overrides: [localStorageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(onlineGalleryEnabledProvider.notifier).setEnabled(true),
      throwsStateError,
    );
    expect(container.read(onlineGalleryEnabledProvider), isFalse);
  });
}

class _Storage extends LocalStorageService {
  final values = <String, Object?>{};
  bool failWrites = false;
  @override
  T? getSetting<T>(String key, {T? defaultValue}) =>
      values[key] as T? ?? defaultValue;
  @override
  Future<void> setSetting<T>(String key, T value) async {
    if (failWrites) throw StateError('write failed');
    values[key] = value;
  }
}
