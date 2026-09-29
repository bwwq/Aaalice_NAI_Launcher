import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_launcher/data/services/gallery/local_gallery_service.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/image_generation_provider.dart';
import 'package:nai_launcher/presentation/screens/tag_library_page/widgets/thumbnail_source_picker.dart';
import 'package:nai_launcher/presentation/widgets/common/image_picker_card/image_picker_result.dart';

void main() {
  for (final width in [320.0, 600.0, 840.0, 1180.0, 1600.0]) {
    testWidgets(
      'sources, file action and cancel remain reachable at $width / 3x',
      (tester) async {
        await _pump(tester, width: width, scale: 3);
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(find.text('暂无收藏图片'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('thumbnail-source-file')),
          findsOneWidget,
        );
        final segmented = find.byType(SegmentedButton<bool>);
        tester.widget<SegmentedButton<bool>>(segmented).onSelectionChanged!({
          true,
        });
        await tester.pumpAndSettle();
        expect(find.text('暂无历史记录'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('取消'));
        await tester.pumpAndSettle();
        expect(find.byType(ThumbnailSourcePicker), findsNothing);
      },
    );
  }

  testWidgets(
    'chooses an unsaved history image and cancel returns no selection',
    (tester) async {
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 2, height: 2)),
      );
      final image = GeneratedImage(
        id: 'unsaved',
        bytes: bytes,
        width: 2,
        height: 2,
      );
      ImagePickerResult? selected;
      var completions = 0;
      await _pump(
        tester,
        history: [image],
        onResult: (result) {
          selected = result;
          completions++;
        },
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('历史记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('历史记录 1'));
      await tester.pumpAndSettle();
      expect(selected?.bytes, bytes);
      expect(selected?.path, isNull);
      expect(completions, 1);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('取消'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(completions, 2);
    },
  );

  testWidgets('failed image conversion keeps picker open with retry', (
    tester,
  ) async {
    final image = GeneratedImage(
      id: 'bad',
      bytes: Uint8List(0),
      width: 1,
      height: 1,
    );
    var completed = false;
    await _pump(
      tester,
      history: [image],
      normalizationError: true,
      onResult: (_) => completed = true,
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('历史记录 1'));
    await tester.pumpAndSettle();
    expect(completed, isFalse);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(ThumbnailSourcePicker), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  double width = 840,
  double scale = 1,
  List<GeneratedImage> history = const [],
  bool normalizationError = false,
  void Function(ImagePickerResult?)? onResult,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        thumbnailFavoritesProvider.overrideWith(
          (ref, page) async => LocalGalleryQueryPage(
            records: const [],
            page: page,
            pageSize: 50,
            totalCount: 0,
          ),
        ),
        thumbnailHistoryReadyProvider.overrideWith((ref) async {}),
        thumbnailImageNormalizerProvider.overrideWithValue((bytes) async {
          if (normalizationError) throw const FormatException('invalid image');
          return bytes;
        }),
        imageGenerationNotifierProvider.overrideWith(
          () => _Generation(history),
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
              onPressed: () async {
                final result = await ThumbnailSourcePicker.show(context);
                onResult?.call(result);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Generation extends ImageGenerationNotifier {
  _Generation(this.history);
  final List<GeneratedImage> history;
  @override
  ImageGenerationState build() => ImageGenerationState(history: history);
}
