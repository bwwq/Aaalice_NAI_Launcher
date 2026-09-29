import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/services/tag_library_thumbnail_store.dart';

void main() {
  late Directory temp;
  late Directory thumbnails;
  late File old;
  late File source;
  late TagLibraryThumbnailStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('thumbnail_commit_');
    thumbnails = await Directory('${temp.path}/thumbnails').create();
    old = await File('${thumbnails.path}/old.png').writeAsBytes([1]);
    source = await File('${temp.path}/source.png').writeAsBytes([2, 3]);
    store = TagLibraryThumbnailStore(thumbnails);
  });
  tearDown(() => temp.delete(recursive: true));

  test(
    'copies before commit and retires the old image only after persistence',
    () async {
      String? saved;
      await store.commit(
        selectedPath: source.path,
        previousPath: old.path,
        persist: (path) async {
          expect(await old.exists(), isTrue);
          expect(path, isNot(source.path));
          expect(await File(path!).readAsBytes(), [2, 3]);
          saved = path;
        },
      );
      expect(await old.exists(), isFalse);
      await source.delete();
      expect(await File(saved!).readAsBytes(), [2, 3]);
    },
  );

  test(
    'failed save retains old and draft files and removes the uncommitted copy',
    () async {
      await expectLater(
        store.commit(
          selectedPath: source.path,
          previousPath: old.path,
          persist: (_) async => throw StateError('storage unavailable'),
        ),
        throwsStateError,
      );
      expect(await old.readAsBytes(), [1]);
      expect(await source.readAsBytes(), [2, 3]);
      expect(await thumbnails.list().length, 1);
    },
  );

  test(
    'clear commits null before deleting, and keeps shared old images',
    () async {
      await store.commit(
        selectedPath: null,
        previousPath: old.path,
        isReferenced: (_) => true,
        persist: (path) async {
          expect(path, isNull);
          expect(await old.exists(), isTrue);
        },
      );
      expect(await old.exists(), isTrue);
      await store.commit(
        selectedPath: null,
        previousPath: old.path,
        persist: (_) async {},
      );
      expect(await old.exists(), isFalse);
    },
  );

  test('missing selected file fails before changing the record', () async {
    await source.delete();
    await expectLater(
      store.commit(
        selectedPath: source.path,
        previousPath: old.path,
        persist: (_) async => fail('must not persist'),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await old.exists(), isTrue);
  });
}
