import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/core/external_agent/external_agent_models.dart';
import 'package:nai_launcher/presentation/providers/external_agent_config_provider.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/external_agent/external_agent_controller.dart';
import 'package:nai_launcher/presentation/screens/settings/sections/external_agent_settings_section.dart';

class _MemoryStorage extends LocalStorageService {
  final Map<String, Object?> values = {};
  @override
  T? getSetting<T>(String key, {T? defaultValue}) =>
      (values[key] as T?) ?? defaultValue;
  @override
  Future<void> setSetting<T>(String key, T value) async {
    values[key] = value;
  }
}

class _IdleController extends ExternalAgentController {
  _IdleController(super.ref, {String? failure}) {
    loading = false;
    error = failure;
  }
}

void main() {
  for (final width in [320.0, 600.0, 840.0, 1180.0, 1600.0]) {
    testWidgets('external settings stay reachable at $width with large text', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localStorageServiceProvider.overrideWithValue(
              _MemoryStorage()
                ..values[externalAgentConfigKey] = jsonEncode(
                  const ExternalAgentConfig(
                    mode: ExternalAgentMode.full,
                  ).toJson(),
                ),
            ),
            externalAgentControllerProvider.overrideWith(
              (ref) => _IdleController(ref),
            ),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 800),
                textScaler: const TextScaler.linear(3),
              ),
              child: const Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: ExternalAgentSettingsSection(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Copy Codex configuration'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Show built-in Agent'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('No external calls yet'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
  testWidgets('bind errors remain visible in settings', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStorageServiceProvider.overrideWithValue(_MemoryStorage()),
          externalAgentControllerProvider.overrideWith(
            (ref) => _IdleController(ref, failure: 'Mock bind error'),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: SingleChildScrollView(child: ExternalAgentSettingsSection()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Mock bind error'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
