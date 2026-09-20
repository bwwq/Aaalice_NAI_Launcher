import 'package:nai_launcher/core/cloud_sync/backend/cloud_sync_backend.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/encrypted_backup_cache.dart';
import 'package:nai_launcher/core/cloud_sync/encrypted_backup_codec.dart';
import 'package:nai_launcher/core/cloud_sync/encrypted_cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/models.dart';
import 'package:nai_launcher/core/cloud_sync/operation.dart';

import 'coordinator_test_backend.dart';

void main() {
  late Directory temporary;
  late CoordinatorTestBackend remote;
  late CoordinatorTestBackend legacy;
  EncryptedCloudSyncBackend client(String name) => EncryptedCloudSyncBackend(
    current: remote,
    legacy: legacy,
    cache: EncryptedBackupCache(Directory('${temporary.path}/$name')),
  );
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('encrypted-backup-');
    remote = CoordinatorTestBackend();
    legacy = CoordinatorTestBackend();
  });
  tearDown(() => temporary.delete(recursive: true));

  Future<SnapshotManifest> upload(
    EncryptedCloudSyncBackend backend,
    String id,
    Uint8List bytes,
  ) async {
    final previous = await backend.readHead();
    await backend.prepareSnapshotUpload(id, OperationToken());
    final hash = EncryptedBackupCodec.hash(bytes);
    await backend.putObject(hash, bytes, sha256: hash);
    final manifest = SnapshotManifest(
      snapshotId: id,
      createdAt: DateTime.utc(2026),
      records: [
        SnapshotRecordRef(
          recordId: 'image',
          kind: 'resource',
          binary: true,
          deleted: false,
          objectId: hash,
          size: bytes.length,
        ),
      ],
    );
    final encoded = Uint8List.fromList(manifest.encode());
    final manifestHash = EncryptedBackupCodec.hash(encoded);
    await backend.putSnapshotManifest(id, encoded, sha256: manifestHash);
    await backend.commitHead(
      Uint8List.fromList(
        SnapshotHead(
          snapshotId: id,
          manifestSha256: manifestHash,
          updatedAt: DateTime.utc(2026),
        ).encode(),
      ),
      expectedRevision: previous?.revision,
    );
    return manifest;
  }

  test('fresh device restores without any local key or cache', () async {
    final bytes = Uint8List.fromList(
      utf8.encode('original PNG metadata and tags'),
    );
    final manifest = await upload(client('first'), 'snapshot-A', bytes);
    final fresh = client('fresh');
    final head = SnapshotHead.decode((await fresh.readHead())!.bytes);
    final read = await fresh.readSnapshotManifest(head.snapshotId);
    head.verifyManifest(read!.bytes);
    expect(SnapshotManifest.decode(read.bytes).toJson(), manifest.toJson());
    expect(
      (await fresh.readObject(EncryptedBackupCodec.hash(bytes)))!.bytes,
      bytes,
    );
    expect(jsonDecode(utf8.decode(remote.head!.bytes))['version'], 4);
    for (final entry in remote.objects.entries) {
      expect(entry.value.bytes.length, lessThanOrEqualTo(maxCloudObjectBytes));
      expect(
        utf8.decode(entry.value.bytes, allowMalformed: true),
        isNot(contains('original PNG')),
      );
    }
  });

  test(
    'maximum logical object is split into bounded encrypted volumes',
    () async {
      final bytes = Uint8List.fromList(
        List.generate(maxCloudObjectBytes, (i) => i % 251),
      );
      await upload(client('large'), 'large', bytes);
      final fresh = client('large-reader');
      await fresh.readSnapshotManifest('large');
      expect(
        (await fresh.readObject(EncryptedBackupCodec.hash(bytes)))!.bytes,
        bytes,
      );
      expect(
        remote.objects.values.every(
          (value) => value.bytes.length <= maxCloudObjectBytes,
        ),
        isTrue,
      );
    },
  );

  test(
    'restart reuses persisted ciphertext and identical snapshot envelope',
    () async {
      final first = client('restart');
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final hash = EncryptedBackupCodec.hash(bytes);
      await first.prepareSnapshotUpload('pending', OperationToken());
      remote.loseFirstObjectResponse = true;
      await expectLater(
        first.putObject(hash, bytes, sha256: hash),
        throwsA(anything),
      );
      final before = remote.objects.keys.toSet();
      final restarted = client('restart');
      await restarted.prepareSnapshotUpload('pending', OperationToken());
      await restarted.putObject(hash, bytes, sha256: hash);
      expect(remote.objects.keys.toSet(), before);
      expect(remote.putAttempts.values.single.length, 2);
      expect(
        remote.putAttempts.values.single[0],
        remote.putAttempts.values.single[1],
      );
    },
  );

  test('new snapshot reuses existing image ciphertext', () async {
    final bytes = Uint8List.fromList([9, 8, 7]);
    final first = client('writer');
    await upload(first, 'first', bytes);
    final firstObjects = remote.objects.keys
        .where((id) => !id.startsWith('snapshot.'))
        .toSet();
    final second = client('writer');
    await second.prepareSnapshotUpload('second', OperationToken());
    final existing = await second.findExistingObjects({
      EncryptedBackupCodec.hash(bytes): bytes.length,
    });
    expect(existing, contains(EncryptedBackupCodec.hash(bytes)));
    await upload(second, 'second', bytes);
    expect(remote.objects.keys.toSet().containsAll(firstObjects), isTrue);
  });

  test('legacy remains readable and is not rewritten on connection', () async {
    final bytes = Uint8List.fromList([4, 5, 6]);
    final hash = EncryptedBackupCodec.hash(bytes);
    await legacy.putObject(hash, bytes, sha256: hash);
    final manifest = SnapshotManifest(
      version: 3,
      snapshotId: 'old',
      createdAt: DateTime.utc(2025),
      records: [
        SnapshotRecordRef(
          recordId: 'old-image',
          kind: 'image',
          binary: true,
          deleted: false,
          objectId: hash,
          size: 3,
        ),
      ],
    );
    final encoded = Uint8List.fromList(manifest.encode());
    await legacy.putSnapshotManifest(
      'old',
      encoded,
      sha256: EncryptedBackupCodec.hash(encoded),
    );
    await legacy.commitHead(
      Uint8List.fromList(
        SnapshotHead(
          version: 3,
          snapshotId: 'old',
          manifestSha256: EncryptedBackupCodec.hash(encoded),
          updatedAt: DateTime.utc(2025),
        ).encode(),
      ),
      expectedRevision: null,
    );
    final fresh = client('legacy-reader');
    expect((await fresh.readHead())!.revision, startsWith('v3:'));
    await fresh.readSnapshotManifest('old');
    expect((await fresh.readObject(hash))!.bytes, bytes);
    expect(remote.objects, isEmpty);
  });
  test(
    'large manifests are encrypted as pages and restore without local state',
    () async {
      final writer = client('paged');
      await writer.prepareSnapshotUpload('paged', OperationToken());
      final bytes = Uint8List.fromList([1]);
      final hash = EncryptedBackupCodec.hash(bytes);
      await writer.putObject(hash, bytes, sha256: hash);
      final manifest = SnapshotManifest(
        snapshotId: 'paged',
        createdAt: DateTime.utc(2026),
        records: List.generate(
          9000,
          (i) => SnapshotRecordRef(
            recordId:
                '${i.toString().padLeft(5, '0')}${List.filled(240, 'x').join()}',
            kind: 'metadata',
            binary: false,
            deleted: false,
            objectId: hash,
            size: 1,
          ),
        ),
      );
      final encoded = Uint8List.fromList(manifest.encode());
      expect(encoded.length, greaterThan(EncryptedBackupCodec.volumeBytes));
      await writer.putSnapshotManifest(
        'paged',
        encoded,
        sha256: EncryptedBackupCodec.hash(encoded),
      );
      final fresh = client('page-reader');
      final read = await fresh.readSnapshotManifest('paged');
      expect(read!.bytes, encoded);
      expect(SnapshotManifest.decode(read.bytes).records, hasLength(9000));
    },
  );

  test(
    'unsupported deletion reports pending cleanup and keeps recoverable data',
    () async {
      final writer = client('retention')..keepSnapshots = 1;
      await upload(writer, 'snapshot-1', Uint8List.fromList([1]));
      await upload(writer, 'snapshot-2', Uint8List.fromList([2]));
      expect(writer.pendingCleanup, 1);
      expect(await writer.listSnapshotIds(), hasLength(2));
      expect(await writer.readSnapshotManifest('snapshot-1'), isNotNull);
    },
  );

  test(
    'atomic retention keeps shared image volumes and current HEAD',
    () async {
      remote = _AtomicBackend();
      final writer = client('atomic')..keepSnapshots = 1;
      final bytes = Uint8List.fromList([1, 9, 2]);
      await upload(writer, 'snapshot-1', bytes);
      await upload(writer, 'snapshot-2', bytes);
      expect(await writer.listSnapshotIds(), ['snapshot-2']);
      expect(writer.pendingCleanup, 0);
      final fresh = client('atomic-new-machine');
      await fresh.readSnapshotManifest('snapshot-2');
      expect(
        (await fresh.readObject(EncryptedBackupCodec.hash(bytes)))!.bytes,
        bytes,
      );
    },
  );

  test('uncommitted manifest does not enter successful history', () async {
    final writer = client('uncommitted')..keepSnapshots = 1;
    await upload(writer, 'completed', Uint8List.fromList([1]));
    await writer.prepareSnapshotUpload('unfinished', OperationToken());
    final manifest = SnapshotManifest(
      snapshotId: 'unfinished',
      createdAt: DateTime.utc(2027),
      records: [],
    );
    final bytes = Uint8List.fromList(manifest.encode());
    await writer.putSnapshotManifest(
      'unfinished',
      bytes,
      sha256: EncryptedBackupCodec.hash(bytes),
    );
    expect(await writer.listSnapshotIds(), ['completed']);
    expect(remote.objects, contains('snapshot.completed'));
  });
}

class _AtomicBackend extends CoordinatorTestBackend
    implements AtomicCloudSnapshotPruningBackend {
  @override
  Future<void> pruneSnapshots(
    String expectedRevision,
    Map<CloudSyncBackend, CloudNamespaceRetention> retained,
  ) async {
    if (head?.revision != expectedRevision) throw StateError('stale revision');
    for (final entry in retained.entries) {
      final backend = entry.key as CoordinatorTestBackend;
      backend.objects.removeWhere(
        (id, _) => id.startsWith('snapshot.')
            ? !entry.value.snapshotIds.contains(id.substring(9))
            : !entry.value.objectIds.contains(id),
      );
      if (entry.value.deleteHead) backend.head = null;
    }
  }
}
