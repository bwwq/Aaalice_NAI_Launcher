import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/adaptive/interaction_policy.dart';
import 'package:nai_launcher/presentation/widgets/common/card_drag_source.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:super_native_extensions/raw_clipboard.dart' as raw;

void main() {
  late Directory directory;
  late PathProviderPlatform previousPathProvider;
  const engineChannel = MethodChannel('dev.irondash.engine_context');

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    final nativeEngineReady = Completer<int>();
    // Mounting the SDK's draggable widget automatically bootstraps OLE.
    // These tests exercise real Flutter snapshots and configuration only.
    // Keep that bootstrap waiting at its Dart engine lookup; never supply a
    // fabricated native handle or let it enter FFI without an engine.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(engineChannel, (call) {
          if (call.method != 'getEngineHandle') {
            throw StateError('Unexpected engine operation: ${call.method}');
          }
          return nativeEngineReady.future;
        });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(engineChannel, null);
  });

  setUp(() async {
    final temporaryRoot = await Directory(
      'tool/.tmp/card-drag-source-test',
    ).create(recursive: true);
    directory = (await temporaryRoot.createTemp()).absolute;
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TemporaryDirectory(directory.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  for (final count in [1, 2]) {
    testWidgets(
      'Windows captures feedback before exporting $count image(s) and releases their files',
      (tester) async {
        final session = _Session();
        final exportReady = Completer<Uint8List>();
        final exportedIds = <String>[];
        final resources = [
          for (var index = 0; index < count; index++)
            CardDragResource(
              id: 'image-$index',
              fileName: 'image-$index.png',
              format: Formats.png,
              prepare: () {
                exportedIds.add('image-$index');
                return exportReady.future;
              },
            ),
        ];
        await tester.pumpWidget(_app(resources));

        // Exercise the SDK's actual feedback rasterization, rather than
        // calling only the application's data-provider callback.
        final captured = await _captureItem(tester, session);
        expect(captured.image.snapshot.isImage, isTrue);
        expect(captured.image.snapshot.image.width, greaterThan(0));
        expect(captured.image.snapshot.image.height, greaterThan(0));
        expect(exportedIds, isEmpty);
        expect(await _sharedFiles(tester, directory), isEmpty);

        final draggable = tester.widget<DraggableWidget>(
          find.byType(DraggableWidget),
        );
        final configuring = Future<DragConfiguration?>.value(
          draggable.onDragConfiguration!(
            DragConfiguration(
              items: [captured],
              allowedOperations: [DropOperation.copy],
            ),
            session,
          ),
        );
        var configurationFinished = false;
        DragConfiguration? configuration;
        configuring.then((value) {
          configuration = value;
          configurationFinished = true;
        });
        await tester.pump();
        expect(exportedIds, ['image-0']);
        expect(configurationFinished, isFalse);

        exportReady.complete(_png);
        await _pumpUntilFinished(
          tester,
          () => configurationFinished,
          stage: 'Windows file preparation after feedback capture',
        );
        expect(configuration, isNotNull);
        expect(configuration!.items, hasLength(count));
        expect(exportedIds, resources.map((resource) => resource.id).toList());

        final files = <File>[];
        for (final configured in configuration!.items) {
          final representations = await _representations(configured.item);
          expect(
            representations,
            everyElement(isA<raw.DataRepresentationSimple>()),
          );
          final contents = representations
              .whereType<raw.DataRepresentationSimple>()
              .singleWhere((value) => value.format == 'PNG');
          final path = representations
              .whereType<raw.DataRepresentationSimple>()
              .singleWhere((value) => value.format == 'NativeShell_CF_15');
          expect(contents.data, _png);
          final file = _fileFromWindowsPath(path.data as String);
          files.add(file);
          await tester.runAsync(() async {
            expect(await file.exists(), isTrue);
            expect(await file.readAsBytes(), _png);
          });
        }
        expect(files.map((file) => file.path).toSet(), hasLength(count));

        // No native OLE registration is performed here. Cancelling this
        // prepared, unregistered gesture must reclaim every transfer file.
        session.completed.value = DropOperation.userCancelled;
        await tester.pump();
        await _waitForCleanup(tester, files);
        await tester.pump(const Duration(seconds: 1));
        final disposedSnapshots = Set<Object>.identity();
        for (final item in configuration!.items) {
          for (final image in [item.image, item.liftImage]) {
            // The SDK's retain() shares the snapshot; dispose() destroys it
            // immediately rather than decrementing its retained count.
            if (image != null && disposedSnapshots.add(image.snapshot)) {
              image.dispose();
            }
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  testWidgets(
    'failed export keeps captured feedback out of native drag',
    (tester) async {
      final session = _Session();
      final exportReady = Completer<Uint8List>();
      var exports = 0;
      await tester.pumpWidget(
        _app([
          CardDragResource(
            id: 'failed-image',
            fileName: 'failed.png',
            format: Formats.png,
            prepare: () {
              exports++;
              return exportReady.future;
            },
          ),
        ]),
      );

      final captured = await _captureItem(tester, session);
      expect(exports, 0);
      final draggable = tester.widget<DraggableWidget>(
        find.byType(DraggableWidget),
      );
      final configuring = Future<DragConfiguration?>.value(
        draggable.onDragConfiguration!(
          DragConfiguration(
            items: [captured],
            allowedOperations: [DropOperation.copy],
          ),
          session,
        ),
      );
      var configurationFinished = false;
      DragConfiguration? configuration;
      configuring.then((value) {
        configuration = value;
        configurationFinished = true;
      });
      await tester.pump();
      expect(exports, 1);
      exportReady.completeError(StateError('synthetic export failure'));
      await _pumpUntilFinished(
        tester,
        () => configurationFinished,
        stage: 'Failed export configuration cleanup',
      );
      expect(configuration, isNull);
      expect(await _sharedFiles(tester, directory), isEmpty);
      final representations = await _representations(captured.item);
      expect(
        representations.map((value) => value.format),
        isNot(contains('NativeShell_CF_15')),
      );

      session.completed.value = DropOperation.userCancelled;
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'connected mouse can drag before the neutral policy observes hover',
    (tester) async {
      await tester.pumpWidget(
        _app(const [
          CardDragResource(id: 'mouse-image', fileName: 'mouse.png'),
        ], policy: InteractionPolicy.neutral),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      var mouseRemoved = false;
      addTearDown(() async {
        if (!mouseRemoved) await mouse.removePointer();
      });
      await mouse.addPointer(
        location: tester.getCenter(find.byType(CardDragSource)),
      );

      final sourceContext = tester.element(find.byType(CardDragSource));
      expect(tester.binding.mouseTracker.mouseIsConnected, isTrue);
      expect(
        InteractionPolicyScope.of(sourceContext).precisePointerAvailable,
        isFalse,
      );
      final dragItem = tester.widget<DragItemWidget>(
        find.byType(DragItemWidget),
      );
      final draggable = tester.widget<DraggableWidget>(
        find.byType(DraggableWidget),
      );
      expect(dragItem.allowedOperations(), [DropOperation.copy]);
      expect(
        draggable.isLocationDraggable(
          tester.getCenter(find.byType(CardDragSource)),
        ),
        isTrue,
      );

      await mouse.removePointer();
      mouseRemoved = true;
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'existing drag callbacks observe mouse policy before the next rebuild',
    (tester) async {
      await tester.pumpWidget(
        _app(const [
          CardDragResource(id: 'switch-image', fileName: 'switch.png'),
        ], policy: InteractionPolicy.touchFirst),
      );
      final dragItemFinder = find.byType(DragItemWidget);
      final oldDragItem = tester.widget<DragItemWidget>(dragItemFinder);
      final oldAllowedOperations = oldDragItem.allowedOperations;
      final oldIsLocationDraggable = tester
          .widget<DraggableWidget>(find.byType(DraggableWidget))
          .isLocationDraggable;
      final location = tester.getCenter(find.byType(CardDragSource));
      expect(tester.binding.mouseTracker.mouseIsConnected, isFalse);
      expect(oldAllowedOperations(), isEmpty);
      expect(oldIsLocationDraggable(location), isFalse);

      // Call the scope's actual input handler without dispatching a mouse
      // through MouseTracker or pumping a rebuild. This isolates live policy
      // reads from both the connected-mouse fallback and refreshed closures.
      final scopeListener = tester.widget<Listener>(
        find
            .descendant(
              of: find.byType(InteractionPolicyScope),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Listener &&
                    widget.onPointerHover != null &&
                    widget.onPointerSignal != null,
              ),
            )
            .first,
      );
      scopeListener.onPointerHover!(
        PointerHoverEvent(kind: PointerDeviceKind.mouse, position: location),
      );
      expect(tester.widget<DragItemWidget>(dragItemFinder), same(oldDragItem));
      expect(oldIsLocationDraggable(location), isTrue);
      expect(oldAllowedOperations(), [DropOperation.copy]);
      expect(tester.binding.mouseTracker.mouseIsConnected, isFalse);

      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );
}

Widget _app(
  List<CardDragResource> resources, {
  InteractionPolicy policy = const InteractionPolicy(
    modality: InteractionModality.pointer,
    touchAvailable: false,
    precisePointerAvailable: true,
  ),
}) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: InteractionPolicyScope(
      initialPolicy: policy,
      child: Scaffold(
        body: Center(
          child: CardDragSource(
            resource: () => resources.first,
            snapshot: (_) => resources,
            feedbackBuilder: (_, _) => const SizedBox(
              width: 120,
              height: 80,
              child: ColoredBox(color: Colors.teal),
            ),
            child: const SizedBox(
              width: 120,
              height: 80,
              child: ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<DragConfigurationItem> _captureItem(
  WidgetTester tester,
  DragSession session,
) async {
  final finder = find.byType(DragItemWidget);
  final state = tester.state<DragItemWidgetState>(finder);
  DragConfigurationItem? captured;
  var completed = false;
  final creating = state.createItem(tester.getCenter(finder), session).then((
    value,
  ) {
    captured = value;
    completed = true;
  });
  // A bounded number of frames makes the old ordering fail immediately even
  // though the deliberately blocked exporter never completes.
  for (var frame = 0; frame < 8 && !completed; frame++) {
    await tester.pump();
  }
  expect(completed, isTrue, reason: 'Export must not block feedback capture');
  await creating;
  expect(captured, isNotNull, reason: 'The actual SDK snapshot must exist');
  return captured!;
}

Future<List<raw.DataRepresentation>> _representations(DragItem item) async => [
  for (final data in item.data) ...(await data).representations,
];

File _fileFromWindowsPath(String path) =>
    File(Uri.file(path, windows: true).toFilePath(windows: Platform.isWindows));

Future<List<File>> _sharedFiles(
  WidgetTester tester,
  Directory directory,
) async => (await tester.runAsync(() async {
  final shared = Directory('${directory.path}/nai_launcher_share');
  return await shared.exists()
      ? await shared
            .list()
            .where((entry) => entry is File)
            .cast<File>()
            .toList()
      : <File>[];
}))!;

Future<void> _waitForCleanup(WidgetTester tester, List<File> files) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await _pumpWithFileIo(tester);
    final remaining = (await tester.runAsync(
      () => Future.wait(files.map((file) => file.exists())),
    ))!;
    if (!remaining.contains(true)) return;
  }
  fail('Ended gesture file cleanup did not finish after pumping file I/O');
}

Future<void> _pumpUntilFinished(
  WidgetTester tester,
  bool Function() finished, {
  required String stage,
}) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await _pumpWithFileIo(tester);
    if (finished()) return;
  }
  fail('$stage did not finish after pumping file I/O');
}

Future<void> _pumpWithFileIo(WidgetTester tester) async {
  // Export callbacks belong to the widget test's fake zone, while actual
  // filesystem operations require the real event loop. Never wait for a
  // fake-zone export future inside runAsync: only yield to real I/O there.
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pump();
}

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aOioAAAAASUVORK5CYII=',
);

class _TemporaryDirectory extends PathProviderPlatform {
  _TemporaryDirectory(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Session extends DragSession {
  final completed = ValueNotifier<DropOperation?>(null);
  final _dragging = ValueNotifier(false);
  final _location = ValueNotifier<Offset?>(null);
  @override
  ValueListenable<DropOperation?> get dragCompleted => completed;
  @override
  ValueListenable<bool> get dragging => _dragging;
  @override
  ValueListenable<Offset?> get lastScreenLocation => _location;
  @override
  Future<List<Object?>?> getLocalData() async => null;
  void dispose() {
    completed.dispose();
    _dragging.dispose();
    _location.dispose();
  }
}
