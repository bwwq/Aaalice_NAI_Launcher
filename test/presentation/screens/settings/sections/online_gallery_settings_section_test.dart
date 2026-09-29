import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/online_gallery_enabled_provider.dart';
import 'package:nai_launcher/presentation/screens/settings/sections/online_gallery_settings_section.dart';

void main() {
  testWidgets(
    'gallery switch remains reachable at narrow widths and large text',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      for (final width in [320.0, 600.0, 840.0, 1180.0, 1600.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey(width),
            overrides: [
              localStorageServiceProvider.overrideWithValue(_Storage()),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(3)),
                child: child!,
              ),
              home: const Scaffold(
                body: SingleChildScrollView(
                  child: OnlineGallerySettingsSection(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tile = find.byType(SwitchListTile);
        expect(tester.widget<SwitchListTile>(tile).value, isFalse);
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(tester.element(tile));
        expect(container.read(onlineGalleryEnabledProvider), isTrue);
        expect(tester.takeException(), isNull, reason: 'width=$width');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}

class _Storage extends LocalStorageService {
  final values = <String, Object?>{};
  @override
  T? getSetting<T>(String key, {T? defaultValue}) =>
      values[key] as T? ?? defaultValue;
  @override
  Future<void> setSetting<T>(String key, T value) async {
    values[key] = value;
  }
}
