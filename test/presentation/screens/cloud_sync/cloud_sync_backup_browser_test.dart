import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/backup_content_preview.dart';
import 'package:nai_launcher/core/cloud_sync/backup_image_preview.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/cloud_sync/cloud_sync_ui_provider.dart';
import 'package:nai_launcher/presentation/screens/cloud_sync/cloud_sync_backup_browser.dart';

void main() {
  testWidgets('browsing offers a separate preparation step and stays open', (
    tester,
  ) async {
    final port = _Port();
    await tester.pumpWidget(_subject(port, browsing: true));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('恢复到本机'), findsNothing);
    final list = find
        .descendant(
          of: find.byKey(const ValueKey('backup-browser-list')),
          matching: find.byType(Scrollable),
        )
        .first;
    await _reveal(tester, find.text('检查恢复影响'), list);
    await tester.tap(find.text('检查恢复影响'));
    await tester.pumpAndSettle();
    expect(
      port.restores,
      1,
    ); // The port advances preparation; the browser does not dismiss.
    expect(find.text('备份内容'), findsOneWidget);
    expect(port.cancels, 0);
  });

  testWidgets('viewing a backup opens contents; closing never restores', (
    tester,
  ) async {
    final port = _Port();
    await tester.pumpWidget(_subject(port));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('备份内容'), findsOneWidget);
    expect(port.previews, 1);
    expect(port.restores, 0);
    final list = find
        .descendant(
          of: find.byKey(const ValueKey('backup-browser-list')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('garden.png'),
      200,
      scrollable: list,
    );
    await tester.tap(find.text('garden.png'));
    await tester.pumpAndSettle();
    expect(find.text('flower, blue'), findsOneWidget);
    await _reveal(tester, find.text('取消'), list);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(port.restores, 0);
    expect(port.cancels, 1);
    expect(find.text('备份内容'), findsNothing);
  });

  testWidgets('explicit restore remains reachable at all widths and 3x text', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final width in [320.0, 600.0, 840.0, 1180.0, 1600.0]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(Size(width, 900));
      final port = _Port();
      await tester.pumpWidget(_subject(port, scale: 3));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final list = find
          .descendant(
            of: find.byKey(const ValueKey('backup-browser-list')),
            matching: find.byType(Scrollable),
          )
          .first;
      final restore = find.text('恢复到本机');
      await _reveal(tester, restore, list);
      expect(port.restores, 0);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(port.restores, 1);
      expect(tester.takeException(), isNull, reason: 'width=$width');
    }
  });

  testWidgets('closing while downloading cancels without applying', (
    tester,
  ) async {
    final port = _Port()..pending = Completer<void>();
    await tester.pumpWidget(_subject(port));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('正在读取备份目录…'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    port.pending!.complete();
    await tester.pumpAndSettle();
    expect(port.cancels, 1);
    expect(port.restores, 0);
  });
}

Widget _subject(_Port port, {double scale = 1, bool browsing = false}) =>
    ProviderScope(
      overrides: [
        cloudSyncUiPortProvider.overrideWithValue(port),
        cloudSyncUiStateProvider.overrideWithValue(
          CloudSyncUiState(
            pendingPreview: CloudSyncPreviewView(
              snapshotId: 'old',
              isBrowse: browsing,
              isRestore: true,
              changes: [],
              images: const BackupImagePreview(
                count: 1,
                originalBytes: 1024,
                added: 1,
              ),
              contents: const [
                BackupContentItem(
                  group: 'gallery-favorite-images',
                  title: 'garden.png',
                  text: 'flower, blue',
                  bytes: 1024,
                ),
              ],
            ),
          ),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('open'),
              onPressed: () => showCloudSyncBackupBrowser(
                context: context,
                port: port,
                snapshot: CloudSyncSnapshotView(
                  id: 'old',
                  createdAt: DateTime(2026, 9, 19),
                  objectCount: 1,
                  encrypted: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );

class _Port implements CloudSyncUiPort {
  int previews = 0, restores = 0, cancels = 0;
  Completer<void>? pending;
  @override
  Future<void> previewRestoreSnapshot(String id) async {
    previews++;
    await pending?.future;
  }

  @override
  Future<void> confirmRestoreSnapshot() async {
    restores++;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _reveal(
  WidgetTester tester,
  Finder target,
  Finder scrollable,
) async {
  for (var n = 0; n < 40 && target.hitTestable().evaluate().isEmpty; n++) {
    await tester.drag(scrollable, const Offset(0, -180));
    await tester.pumpAndSettle();
  }
  expect(target.hitTestable(), findsOneWidget);
}
