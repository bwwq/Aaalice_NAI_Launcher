import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/main_navigation_order_provider.dart';
import 'package:nai_launcher/presentation/router/main_navigation_item.dart';
import 'package:nai_launcher/presentation/screens/settings/widgets/navigation_order_settings.dart';

class _Storage extends LocalStorageService {
  final values = <String, Object?>{};
  @override
  T? getSetting<T>(String key, {T? defaultValue}) =>
      values[key] as T? ?? defaultValue;
  @override
  Future<void> setSetting<T>(String key, T value) async => values[key] = value;
}

void main() {
  testWidgets('窄屏和大字下可移动全部图标并恢复默认', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(
      overrides: [localStorageServiceProvider.overrideWithValue(_Storage())],
    );
    addTearDown(container.dispose);
    for (final width in [320.0, 600.0, 840.0, 1180.0, 1600.0]) {
      await tester.binding.setSurfaceSize(Size(width, 700));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(3)),
              child: child!,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: NavigationOrderSettings(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('navigation-order-onlineGallery')),
        findsNothing,
      );
      for (final item in MainNavigationItem.values.where(
        (item) => item != MainNavigationItem.onlineGallery,
      )) {
        final button = find.byKey(ValueKey('navigation-order-up-${item.name}'));
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        expect(button.hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull, reason: 'width=$width');
    }
    final up = find.byKey(
      const ValueKey('navigation-order-up-preciseRefLibrary'),
    );
    await tester.ensureVisible(up);
    await tester.tap(up);
    await tester.pumpAndSettle();
    final order = container.read(mainNavigationOrderProvider);
    expect(
      order.indexOf(MainNavigationItem.preciseRefLibrary),
      lessThan(order.indexOf(MainNavigationItem.vibeLibrary)),
    );
    final reset = find.byKey(const ValueKey('navigation-order-reset'));
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(
      container.read(mainNavigationOrderProvider),
      MainNavigationItem.values,
    );
    expect(tester.takeException(), isNull);
  });
}
