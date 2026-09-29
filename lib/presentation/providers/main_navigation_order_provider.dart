import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/storage/local_storage_service.dart';
import '../router/main_navigation_item.dart';

final mainNavigationOrderProvider =
    NotifierProvider<MainNavigationOrderNotifier, List<MainNavigationItem>>(
      MainNavigationOrderNotifier.new,
    );

class MainNavigationOrderNotifier extends Notifier<List<MainNavigationItem>> {
  Future<void> _pending = Future<void>.value();

  @override
  List<MainNavigationItem> build() {
    final stored = ref
        .watch(localStorageServiceProvider)
        .getSetting<dynamic>(StorageKeys.mainNavigationOrder);
    final byName = {
      for (final item in MainNavigationItem.values) item.name: item,
    };
    return List.unmodifiable({
      if (stored is List)
        for (final name in stored)
          if (byName[name] case final item?) item,
      ...MainNavigationItem.values,
    });
  }

  Future<void> move(
    MainNavigationItem item,
    int direction, {
    required bool onlineGalleryEnabled,
  }) => _enqueue(() async {
    final visible = visibleMainNavigationItems(
      state,
      onlineGalleryEnabled: onlineGalleryEnabled,
    );
    final index = visible.indexOf(item);
    final neighbor = index + direction;
    if (index < 0 ||
        direction.abs() != 1 ||
        neighbor < 0 ||
        neighbor >= visible.length) {
      return;
    }
    final next = [...state];
    final from = next.indexOf(item);
    final to = next.indexOf(visible[neighbor]);
    next[from] = next[to];
    next[to] = item;
    await _persist(next);
  });

  Future<void> reset() => _enqueue(() => _persist(MainNavigationItem.values));

  Future<void> _persist(List<MainNavigationItem> order) async {
    await ref
        .read(localStorageServiceProvider)
        .setSetting(
          StorageKeys.mainNavigationOrder,
          order.map((item) => item.name).toList(growable: false),
        );
    state = List.unmodifiable(order);
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
