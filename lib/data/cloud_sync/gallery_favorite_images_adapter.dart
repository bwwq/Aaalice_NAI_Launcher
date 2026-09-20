import '../../core/cloud_sync/backup_image_preview.dart';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/database/datasources/gallery_data_source.dart';
import '../services/gallery/gallery_album_sidecar_service.dart';
import '../services/gallery/local_gallery_repository.dart';
import 'cloud_sync_data_adapter.dart';
import 'gallery_favorite_backup_store.dart';
import 'portable_sync_record.dart';

class GalleryFavoriteImagesAdapter extends ValidatingCloudSyncDataAdapter
    implements GalleryFavoritePreviewAdapter {
  GalleryFavoriteImagesAdapter({
    required this.store,
    required this.getRootPath,
  });

  final GalleryFavoriteBackupStore store;
  final Future<String?> Function() getRootPath;
  GalleryDataSource get gallery => store.gallery;

  @override
  String get id => 'gallery-favorite-images';
  @override
  Set<String> get allowedKinds => const {'image'};

  @override
  Stream<PortableSyncRecord> exportRecords() async* {
    final root = await getRootPath();
    final ids = await gallery.getFavoriteImageIds();
    if (ids.isEmpty) return;
    if (root == null) {
      throw const CloudSyncPreflightException('Gallery folder is unavailable');
    }
    final failures = <String>[];
    for (final imageId in ids) {
      final image = await gallery.getImageById(imageId);
      if (image == null) {
        failures.add('Missing favorite record $imageId');
        continue;
      }
      final relative = GalleryAlbumSidecarService.toRelativePath(
        root,
        image.filePath,
      );
      if (relative == null) {
        failures.add(image.fileName);
        continue;
      }
      final file = File(image.filePath);
      try {
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) {
          throw const FileSystemException('Missing image');
        }
        final hash = (await sha256.bind(file.openRead()).first).toString();
        final portableId = await store.identity(imageId, relative, hash);
        final tags = (await gallery.getImageTags(imageId))..sort();
        yield PortableSyncRecord(
          adapterId: id,
          id: portableId,
          kind: 'image',
          data: {
            'relativePath': relative,
            'sha256': hash,
            'favoritedAt': await store.favoriteTime(imageId),
            'createdAt': image.createdAt.millisecondsSinceEpoch,
            'modifiedAt': stat.modified.millisecondsSinceEpoch,
            'tags': tags,
          },
          resource: PortableSyncResource(
            relativePath: 'gallery-favorites/$portableId/original',
            length: stat.size,
            openRead: () => _verifiedRead(file, stat.size, hash),
          ),
        );
      } on FileSystemException {
        failures.add(relative);
      }
    }
    if (failures.isNotEmpty) {
      throw CloudSyncPreflightException(
        'Favorite images unavailable: ${failures.join(', ')}',
      );
    }
  }

  @override
  void validateRecord(PortableSyncRecord record) {
    if (record.deleted) return;
    final data = record.data;
    if (record.resource == null ||
        data['relativePath'] is! String ||
        !GalleryAlbumSidecarService.isValidRelativeMemberPath(
          data['relativePath']! as String,
        ) ||
        data['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['sha256']! as String) ||
        data['favoritedAt'] is! int ||
        data['createdAt'] is! int ||
        data['modifiedAt'] is! int ||
        data['tags'] is! List ||
        !(data['tags']! as List).every((tag) => tag is String)) {
      throw const CloudSyncPreflightException('Invalid favorite image');
    }
  }

  @override
  Future<void> preflight(List<PortableSyncRecord> records) async {
    await super.preflight(records);
    // Verify every incoming resource before applying any gallery mutation.
    for (final record in records.where((record) => !record.deleted)) {
      final hash = await sha256.bind(record.resource!.openRead()).first;
      if (hash.toString() != record.data['sha256']) {
        throw const CloudSyncPreflightException(
          'Favorite image content changed',
        );
      }
    }
  }

  @override
  Future<BackupImagePreview> preview(
    List<PortableSyncRecord> records,
    int estimatedBytes,
  ) async {
    final root = await getRootPath();
    var bytes = 0, count = 0, added = 0, reused = 0, conflicts = 0;
    for (final record in records.where((record) => !record.deleted)) {
      count++;
      bytes += record.resource!.length;
      final mapping = await store.lookup(record.id);
      final relative =
          mapping?['restored_path'] as String? ??
          record.data['relativePath']! as String;
      if (root == null) {
        added++;
        continue;
      }
      final file = File(
        GalleryAlbumSidecarService.toAbsolutePath(root, relative),
      );
      if (!await file.exists()) {
        added++;
        continue;
      }
      if ((await sha256.bind(file.openRead()).first).toString() ==
          record.data['sha256']) {
        reused++;
      } else {
        conflicts++;
        added++;
      }
    }
    return BackupImagePreview(
      count: count,
      originalBytes: bytes,
      estimatedUploadBytes: estimatedBytes,
      added: added,
      reused: reused,
      nameConflicts: conflicts,
    );
  }

  @override
  Future<void> apply(List<PortableSyncRecord> records) async {
    final root = await getRootPath();
    if (root == null) {
      throw const CloudSyncPreflightException('Gallery folder is unavailable');
    }
    for (final record in records) {
      final mapping = await store.lookup(record.id);
      if (record.deleted) {
        if (mapping != null) {
          await store.setFavorite(mapping['image_id']! as int, false);
        }
        continue;
      }
      final original = record.data['relativePath']! as String;
      final hash = record.data['sha256']! as String;
      final preferred = mapping?['restored_path'] as String? ?? original;
      final destination = await _destination(root, preferred, hash);
      if (!await destination.exists()) {
        await destination.parent.create(recursive: true);
        final temporary = File('${destination.path}.${const Uuid().v4()}.tmp');
        try {
          final sink = temporary.openWrite();
          try {
            await sink.addStream(record.resource!.openRead());
          } finally {
            await sink.close();
          }
          if ((await sha256.bind(temporary.openRead()).first).toString() !=
              hash) {
            throw const CloudSyncPreflightException(
              'Favorite image checksum mismatch',
            );
          }
          // Recheck after streaming; never replace an existing different image.
          if (await destination.exists()) {
            throw const CloudSyncPreflightException(
              'Gallery changed during restore',
            );
          }
          await temporary.rename(destination.path);
          await destination.setLastModified(
            DateTime.fromMillisecondsSinceEpoch(
              record.data['modifiedAt']! as int,
            ),
          );
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      }
      await LocalGalleryRepository(dataSource: gallery).addImage(destination);
      final imageId = await gallery.getImageIdByPath(destination.path);
      if (imageId == null) {
        throw const CloudSyncPreflightException(
          'Restored image was not indexed',
        );
      }
      await store.remember(
        record.id,
        imageId,
        original,
        p.relative(destination.path, from: root).replaceAll('\\', '/'),
        hash,
      );
      await store.setFavorite(
        imageId,
        true,
        time: record.data['favoritedAt']! as int,
      );
      await gallery.setImageTags(
        imageId,
        (record.data['tags']! as List).cast<String>(),
      );
    }
  }

  Future<File> _destination(String root, String relative, String hash) async {
    var file = File(GalleryAlbumSidecarService.toAbsolutePath(root, relative));
    if (!await file.exists() ||
        (await sha256.bind(file.openRead()).first).toString() == hash) {
      return file;
    }
    final stem = p.withoutExtension(file.path);
    final extension = p.extension(file.path);
    for (var index = 0; ; index++) {
      file = File(
        '$stem-${hash.substring(0, 12)}${index == 0 ? '' : '-$index'}$extension',
      );
      if (!await file.exists() ||
          (await sha256.bind(file.openRead()).first).toString() == hash) {
        return file;
      }
    }
  }
}

Stream<List<int>> _verifiedRead(File file, int length, String expected) async* {
  final result = _DigestSink();
  final digest = sha256.startChunkedConversion(result);
  var count = 0;
  await for (final chunk in file.openRead()) {
    digest.add(chunk);
    count += chunk.length;
    if (count > length) {
      throw const CloudSyncPreflightException(
        'Favorite image changed during backup',
      );
    }
    yield chunk;
  }
  digest.close();
  if (count != length || result.value.toString() != expected) {
    throw const CloudSyncPreflightException(
      'Favorite image changed during backup',
    );
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
