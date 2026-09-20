import 'package:uuid/uuid.dart';

import '../../core/database/datasources/gallery_data_source.dart';

/// Device-local identities and restored paths; never exports SQLite row IDs.
class GalleryFavoriteBackupStore {
  GalleryFavoriteBackupStore(this.gallery);

  final GalleryDataSource gallery;
  Future<void>? _ready;

  Future<void> initialize() => _ready ??= gallery.execute(
    'initializeFavoriteBackup',
    (db) async {
      await db.execute('''CREATE TABLE IF NOT EXISTS gallery_backup_images (
      portable_id TEXT PRIMARY KEY, image_id INTEGER NOT NULL,
      original_path TEXT NOT NULL, restored_path TEXT NOT NULL,
      content_hash TEXT NOT NULL
    )''');
      await db.execute('''CREATE TABLE IF NOT EXISTS gallery_backup_paths (
        original_path TEXT PRIMARY KEY, restored_path TEXT NOT NULL
      )''');
    },
  );

  Future<String> identity(int imageId, String relativePath, String hash) async {
    await initialize();
    return gallery.executeTransaction('favoriteBackupIdentity', (txn) async {
      final rows = await txn.query(
        'gallery_backup_images',
        where: 'image_id = ?',
        whereArgs: [imageId],
        limit: 1,
      );
      if (rows.isNotEmpty) return rows.first['portable_id']! as String;
      final id = const Uuid().v4();
      await txn.insert('gallery_backup_images', {
        'portable_id': id,
        'image_id': imageId,
        'original_path': relativePath,
        'restored_path': relativePath,
        'content_hash': hash,
      });
      return id;
    });
  }

  Future<Map<String, Object?>?> lookup(String id) async {
    await initialize();
    return gallery.execute('lookupFavoriteBackup', (db) async {
      final rows = await db.query(
        'gallery_backup_images',
        where: 'portable_id = ?',
        whereArgs: [id],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.first;
    });
  }

  Future<String> restoredPath(String originalPath) async {
    await initialize();
    return gallery.execute('favoriteBackupPath', (db) async {
      final current = await db.query(
        'gallery_backup_paths',
        where: 'original_path = ?',
        whereArgs: [originalPath],
        limit: 1,
      );
      if (current.isNotEmpty) {
        return current.first['restored_path']! as String;
      }
      final rows = await db.query(
        'gallery_backup_images',
        where: 'original_path = ?',
        whereArgs: [originalPath],
        orderBy: 'rowid DESC',
        limit: 1,
      );
      return rows.isEmpty
          ? originalPath
          : rows.first['restored_path']! as String;
    });
  }

  Future<void> remember(
    String id,
    int imageId,
    String originalPath,
    String restoredPath,
    String hash,
  ) async {
    await initialize();
    await gallery.executeTransaction('rememberFavoriteBackup', (txn) async {
      await txn.delete(
        'gallery_backup_images',
        where: 'portable_id = ? OR image_id = ?',
        whereArgs: [id, imageId],
      );
      await txn.insert('gallery_backup_images', {
        'portable_id': id,
        'image_id': imageId,
        'original_path': originalPath,
        'restored_path': restoredPath,
        'content_hash': hash,
      });
      // Album paths belong to the snapshot most recently applied, while each
      // image keeps its own portable identity for later repeat restores.
      await txn.rawInsert(
        'INSERT OR REPLACE INTO gallery_backup_paths '
        '(original_path, restored_path) VALUES (?, ?)',
        [originalPath, restoredPath],
      );
    });
  }

  Future<int> favoriteTime(int imageId) =>
      gallery.execute('favoriteBackupTime', (db) async {
        final rows = await db.query(
          'gallery_favorites',
          columns: ['favorited_at'],
          where: 'image_id = ?',
          whereArgs: [imageId],
        );
        if (rows.isEmpty) throw StateError('Favorite changed during backup');
        return rows.first['favorited_at']! as int;
      });

  Future<void> setFavorite(int imageId, bool favorite, {int? time}) async {
    if (await gallery.isFavorite(imageId) != favorite) {
      await gallery.toggleFavorite(imageId);
    }
    if (favorite && time != null) {
      await gallery.execute(
        'restoreFavoriteTime',
        (db) => db.update(
          'gallery_favorites',
          {'favorited_at': time},
          where: 'image_id = ?',
          whereArgs: [imageId],
        ),
      );
    }
  }
}
