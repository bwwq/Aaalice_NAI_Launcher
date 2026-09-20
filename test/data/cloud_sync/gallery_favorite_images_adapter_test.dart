import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_launcher/core/database/connection_pool_holder.dart';
import 'package:nai_launcher/core/database/datasources/gallery_data_source.dart';
import 'package:nai_launcher/core/utils/app_logger.dart';
import 'package:nai_launcher/data/cloud_sync/cloud_sync_data_adapter.dart';
import 'package:nai_launcher/data/cloud_sync/gallery_favorite_backup_store.dart';
import 'package:nai_launcher/data/cloud_sync/gallery_favorite_images_adapter.dart';
import 'package:nai_launcher/data/cloud_sync/portable_sync_record.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporary;
  late GalleryDataSource gallery;
  late GalleryFavoriteBackupStore store;
  late Directory original;
  late Directory restored;
  final favoriteTime = DateTime.utc(2024, 3, 2).millisecondsSinceEpoch;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await AppLogger.initialize(isTestEnvironment: true);
  });
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('favorite-backup-');
    await ConnectionPoolHolder.initialize(
      dbPath: '${temporary.path}/gallery.db',
      maxConnections: 2,
    );
    gallery = GalleryDataSource();
    await gallery.initialize();
    store = GalleryFavoriteBackupStore(gallery);
    original = await Directory('${temporary.path}/original').create();
    restored = await Directory('${temporary.path}/restored').create();
  });
  tearDown(() async {
    await gallery.dispose();
    await ConnectionPoolHolder.dispose();
    await temporary.delete(recursive: true);
  });

  GalleryFavoriteImagesAdapter adapter(Directory root) =>
      GalleryFavoriteImagesAdapter(
        store: store,
        getRootPath: () async => root.path,
      );

  Future<(File, int)> image(
    String name, {
    bool favorite = true,
    int red = 90,
  }) async {
    final png = img.Image(width: 8, height: 8);
    img.fill(png, color: img.ColorRgb8(red, 40, 20));
    final file = await File(
      p.join(original.path, name),
    ).writeAsBytes(img.encodePng(png));
    final stat = await file.stat();
    final id = await gallery.upsertImage(
      filePath: file.path,
      fileName: name,
      fileSize: stat.size,
      createdAt: stat.modified,
      modifiedAt: stat.modified,
    );
    await store.setFavorite(id, favorite, time: favoriteTime);
    if (favorite) await gallery.setImageTags(id, ['favorite tag', 'custom']);
    return (file, id);
  }

  test(
    'only favorites export, preserving original bytes, time, and tags',
    () async {
      final (file, _) = await image('favorite.png');
      await image('ordinary.png', favorite: false);
      final records = await adapter(original).exportRecords().toList();
      expect(records, hasLength(1));
      expect(records.single.data['favoritedAt'], favoriteTime);
      expect(records.single.data['tags'], ['custom', 'favorite tag']);
      expect(records.single.data['relativePath'], 'favorite.png');
      expect(
        await records.single.resource!
            .openRead()
            .expand((bytes) => bytes)
            .toList(),
        await file.readAsBytes(),
      );
    },
  );

  test(
    'restore preserves files, reuses identical data, and restores favorites',
    () async {
      final (file, _) = await image('same.png');
      final records = await adapter(original).exportRecords().toList();
      final target = adapter(restored);
      await target.preflight(records);
      await target.apply(records);
      await target.apply(records);
      final files = await restored
          .list()
          .where((entry) => entry is File)
          .toList();
      expect(files, hasLength(1));
      expect(
        await File(files.single.path).readAsBytes(),
        await file.readAsBytes(),
      );
      final id = (await gallery.getImageIdByPath(files.single.path))!;
      expect(await gallery.isFavorite(id), isTrue);
      expect(await store.favoriteTime(id), favoriteTime);
      expect(
        await gallery.getImageTags(id),
        unorderedEquals(['custom', 'favorite tag']),
      );
    },
  );

  test(
    'same name with different bytes keeps both and maps album references',
    () async {
      final (file, _) = await image('collision.png');
      final existing = await File(
        '${restored.path}/collision.png',
      ).writeAsBytes([1, 2, 3]);
      final records = await adapter(original).exportRecords().toList();
      final target = adapter(restored);
      await target.apply(records);
      await target.apply(records);
      expect(await existing.readAsBytes(), [1, 2, 3]);
      expect(await restored.list().length, 2);
      final relative = await store.restoredPath('collision.png');
      expect(relative, isNot('collision.png'));
      expect(
        await File(p.join(restored.path, relative)).readAsBytes(),
        await file.readAsBytes(),
      );
    },
  );

  test('album path follows the currently restored device snapshot', () async {
    final (firstFile, _) = await image('same.png');
    final first = (await adapter(original).exportRecords().toList()).single;
    final (secondFile, _) = await image('other.png', red: 180);
    final exported = await adapter(original).exportRecords().toList();
    final other = exported.singleWhere((record) => record.id != first.id);
    final second = PortableSyncRecord(
      adapterId: other.adapterId,
      id: other.id,
      kind: other.kind,
      data: {...other.data, 'relativePath': 'same.png'},
      resource: other.resource,
    );
    final target = adapter(restored);
    await target.apply([first]);
    await target.apply([second]);
    store = GalleryFavoriteBackupStore(gallery);
    final secondPath = await store.restoredPath('same.png');
    expect(secondPath, isNot('same.png'));
    expect(await File(p.join(restored.path, secondPath)).readAsBytes(),
        await secondFile.readAsBytes());
    expect(await store.lookup(first.id), isNotNull);
    expect(await store.lookup(second.id), isNotNull);
    await adapter(restored).apply([first]);
    expect(await store.restoredPath('same.png'), 'same.png');
    expect(await File(p.join(restored.path, 'same.png')).readAsBytes(),
        await firstFile.readAsBytes());
    expect(await restored.list().length, 2);
  });

  test('unfavorite tombstone never deletes the original image', () async {
    final (file, imageId) = await image('keep.png');
    final record = (await adapter(original).exportRecords().toList()).single;
    await adapter(original).apply([
      PortableSyncRecord(
        adapterId: record.adapterId,
        id: record.id,
        kind: record.kind,
        deleted: true,
      ),
    ]);
    expect(await file.exists(), isTrue);
    expect(await gallery.isFavorite(imageId), isFalse);
  });

  test(
    'missing favorite blocks the backup instead of silently skipping it',
    () async {
      final (file, _) = await image('missing.png');
      await file.delete();
      await expectLater(
        adapter(original).exportRecords().toList(),
        throwsA(isA<CloudSyncPreflightException>()),
      );
    },
  );

  test(
    'changes after capture fail replay before upload is committed',
    () async {
      final (file, _) = await image('changed.png');
      final records = await adapter(original).exportRecords().toList();
      await file.writeAsBytes([7, 8, 9]);
      await expectLater(
        records.single.resource!.openRead().toList(),
        throwsA(isA<CloudSyncPreflightException>()),
      );
    },
  );
}
