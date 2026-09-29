import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/presentation/providers/main_navigation_order_provider.dart';
import 'package:nai_launcher/presentation/router/main_navigation_item.dart';

class _Storage extends LocalStorageService {
  Object? stored;
  bool failWrites = false;

  @override
  T? getSetting<T>(String key, {T? defaultValue}) =>
      stored as T? ?? defaultValue;

  @override
  Future<void> setSetting<T>(String key, T value) async {
    expect(key, StorageKeys.mainNavigationOrder);
    if (failWrites) throw StateError('写入失败');
    stored = value;
  }
}

void main() {
  late _Storage storage;
  late ProviderContainer container;
  setUp(() {
    storage = _Storage();
    container = ProviderContainer(
      overrides: [localStorageServiceProvider.overrideWithValue(storage)],
    );
  });
  tearDown(() => container.dispose());

  test('恢复顺序时忽略未知项与重复项，并补齐新增功能', () {
    storage.stored = ['settings', 'unknown', 'settings', 'preciseRefLibrary'];
    final order = container.read(mainNavigationOrderProvider);
    expect(order.take(2), [
      MainNavigationItem.settings,
      MainNavigationItem.preciseRefLibrary,
    ]);
    expect(order.toSet(), MainNavigationItem.values.toSet());
    expect(order.length, MainNavigationItem.values.length);
  });

  test('连续移动跳过隐藏画廊，重启保留顺序且可恢复默认', () async {
    final notifier = container.read(mainNavigationOrderProvider.notifier);
    await Future.wait([
      notifier.move(
        MainNavigationItem.vibeLibrary,
        -1,
        onlineGalleryEnabled: false,
      ),
      notifier.move(
        MainNavigationItem.vibeLibrary,
        -1,
        onlineGalleryEnabled: false,
      ),
    ]);
    expect(
      container.read(mainNavigationOrderProvider).first,
      MainNavigationItem.vibeLibrary,
    );
    expect(
      container.read(mainNavigationOrderProvider)[2],
      MainNavigationItem.onlineGallery,
    );
    final restored = ProviderContainer(
      overrides: [localStorageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(restored.dispose);
    expect(
      restored.read(mainNavigationOrderProvider),
      container.read(mainNavigationOrderProvider),
    );
    await notifier.reset();
    expect(
      container.read(mainNavigationOrderProvider),
      MainNavigationItem.values,
    );
  });

  test('保存失败保留原顺序并允许重试', () async {
    final notifier = container.read(mainNavigationOrderProvider.notifier);
    storage.failWrites = true;
    await expectLater(
      notifier.move(
        MainNavigationItem.settings,
        -1,
        onlineGalleryEnabled: false,
      ),
      throwsStateError,
    );
    expect(
      container.read(mainNavigationOrderProvider),
      MainNavigationItem.values,
    );
    expect(storage.stored, isNull);
    storage.failWrites = false;
    await notifier.move(
      MainNavigationItem.settings,
      -1,
      onlineGalleryEnabled: false,
    );
    expect(
      container.read(mainNavigationOrderProvider).last,
      MainNavigationItem.queue,
    );
  });
}
