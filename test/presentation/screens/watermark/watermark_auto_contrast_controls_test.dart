import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/models/watermark/watermark_settings.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/screens/watermark/watermark_editor_controls.dart';

void main() {
  for (final width in [320.0, 600.0, 840.0, 1180.0, 1600.0]) {
    for (final scale in [1.0, 3.0]) {
      testWidgets(
        'adaptation controls remain reachable at $width and ${scale}x',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 760));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          var settings = const WatermarkSettings(
            textStyle: WatermarkTextStyle(colorArgb: 0xFF123456),
          );
          var selected = WatermarkEditableLayer.text;
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    return WatermarkEditorControls(
                      settings: settings,
                      layout: settings.universalLayout,
                      selectedLayer: selected,
                      logoAvailable: true,
                      preserveMetadata: false,
                      onOpenMetadataSettings: () {},
                      onChooseLogo: () {},
                      onLayoutChanged: (_) {},
                      onSettingsChanged: (value) =>
                          setState(() => settings = value),
                      onSelectedLayerChanged: (value) =>
                          setState(() => selected = value),
                    );
                  },
                ),
              ),
            ),
          );
          final textSwitch = find.byKey(
            const ValueKey('watermark-auto-contrast-text'),
          );
          await tester.scrollUntilVisible(
            textSwitch,
            150,
            scrollable: find.byType(Scrollable).first,
          );
          expect(tester.widget<SwitchListTile>(textSwitch).value, isTrue);
          final color = find.widgetWithText(ListTile, 'Color Picker');
          await tester.scrollUntilVisible(
            color,
            150,
            scrollable: find.byType(Scrollable).first,
          );
          expect(tester.widget<ListTile>(color).enabled, isFalse);
          expect(tester.widget<ListTile>(color).onTap, isNull);
          await tester.scrollUntilVisible(
            textSwitch,
            -150,
            scrollable: find.byType(Scrollable).first,
          );
          await _tapVisible(tester, textSwitch);
          await tester.pump();
          expect(settings.textStyle.autoContrast, isFalse);
          expect(settings.logoStyle.autoContrast, isTrue);
          expect(settings.textStyle.colorArgb, 0xFF123456);
          await tester.scrollUntilVisible(
            color,
            150,
            scrollable: find.byType(Scrollable).first,
          );
          expect(tester.widget<ListTile>(color).enabled, isTrue);
          final logoTab = find.text('Logo');
          await tester.scrollUntilVisible(
            logoTab,
            -150,
            scrollable: find.byType(Scrollable).first,
          );
          await _tapVisible(tester, logoTab);
          await tester.pump();
          final logoSwitch = find.byKey(
            const ValueKey('watermark-auto-contrast-logo'),
          );
          await tester.scrollUntilVisible(
            logoSwitch,
            150,
            scrollable: find.byType(Scrollable).first,
          );
          expect(tester.widget<SwitchListTile>(logoSwitch).value, isTrue);
          await _tapVisible(tester, logoSwitch);
          await tester.pump();
          expect(settings.logoStyle.autoContrast, isFalse);
          expect(settings.textStyle.autoContrast, isFalse);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

Future<void> _tapVisible(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
}
