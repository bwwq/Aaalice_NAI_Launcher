import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/content_selection.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/cloud_sync/cloud_sync_ui_provider.dart';
import 'package:nai_launcher/presentation/screens/cloud_sync/cloud_sync_retention_control.dart';

void main() {
  for (final width in [320.0, 600.0, 840.0, 1180.0, 1600.0]) {
    testWidgets('retention remains reachable at $width with 3x text', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 420));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var selected = 5;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(3)),
            child: child!,
          ),
          home: Scaffold(
            body: SafeArea(
              child: SingleChildScrollView(
                child: CloudSyncRetentionControl(
                  value: 5,
                  onChanged: (value) => selected = value,
                ),
              ),
            ),
          ),
        ),
      );
      final field = find.byKey(const ValueKey('backup-retention-5'));
      await Scrollable.ensureVisible(tester.element(field), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(field);
      await tester.pumpAndSettle();
      final option = find.text('10');
      await tester.scrollUntilVisible(
        option,
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(selected, 10);
      expect(tester.takeException(), isNull);
    });
  }

  test('favorite originals default on and persist independently', () {
    const selection = CloudSyncContentSelection();
    expect(selection.includeGalleryFavoriteImages, isTrue);
    final restored = CloudSyncContentSelection.decode(
      selection.copyWith(includeGalleryFavoriteImages: false).encode(),
    );
    expect(restored.includeGalleryFavoriteImages, isFalse);
    expect(restored.includeGalleryAlbums, isTrue);
  });

  test(
    'retention changes preserve connection and do not copy credentials into content',
    () {
      const draft = CloudSyncConnectionDraft(
        backend: CloudSyncBackendKind.webDav,
        serverUrl: 'https://example.invalid/dav',
        username: 'user',
        secret: 'example',
        path: 'backup',
      );
      expect(draft.keepSnapshots, 5);
      final updated = draft.withRetention(100);
      expect(updated.keepSnapshots, 100);
      expect(updated.path, draft.path);
      expect(updated.secret, draft.secret);
    },
  );
}
