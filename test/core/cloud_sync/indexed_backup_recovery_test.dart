import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/backend/cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/data_source.dart';
import 'package:nai_launcher/core/cloud_sync/encrypted_backup_codec.dart';
import 'package:nai_launcher/core/cloud_sync/models.dart';
import 'package:nai_launcher/core/cloud_sync/operation.dart';
import 'backend/incremental_backend_fixture.dart';
import 'indexed_backup_test_support.dart';
import 'packed_snapshot_contract.dart';

void main() {
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('index-recovery-');
  });
  tearDown(() => temporary.delete(recursive: true));

  test(
    'old v4 learns portable proofs once without rewriting its index',
    () async {
      final fixture = IncrementalBackendFixture('s3');
      final writer = IndexedBackupClient(
        fixture,
        Directory('${temporary.path}/old'),
      );
      final record = indexedRecord('image', 1, 4096);
      final object = record.payload!.sha256;
      await writer.backend.prepareSnapshotUpload('old', OperationToken());
      await writer.backend.putObject(object, record.bytes!, sha256: object);
      final plan = (await writer.cache.readPlan('objects', object))!;
      fixture.contentIds.addAll((plan['parts'] as List).cast<String>());
      plan.remove('partMetadata');
      await writer.cache.writePlan('objects', object, plan);
      await writer.backend.prepareSnapshotUpload('old', OperationToken());
      final manifest = SnapshotManifest(
        snapshotId: 'old',
        createdAt: DateTime.utc(2025),
        records: [recordRef(record)],
      );
      final bytes = Uint8List.fromList(manifest.encode());
      final hash = EncryptedBackupCodec.hash(bytes);
      await writer.backend.putSnapshotManifest('old', bytes, sha256: hash);
      await writer.backend.commitHead(
        Uint8List.fromList(
          SnapshotHead(
            snapshotId: 'old',
            manifestSha256: hash,
            updatedAt: DateTime.utc(2025),
          ).encode(),
        ),
        expectedRevision: null,
      );
      final oldEnvelope = List<int>.of(
        fixture.s3!.files['/bucket/cloud/snapshots/old.json']!,
      );
      final snapshot = CloudSyncSnapshotData([record]);
      var start = fixture.samples.length;
      await IndexedBackupClient(
        fixture,
        Directory('${temporary.path}/upgrade'),
      ).upload(snapshot, 'upgrade');
      expect(fixture.metrics(start)['contentReadBytes'], greaterThan(0));
      expect(fixture.metrics(start)['contentWrittenBytes'], 0);
      start = fixture.samples.length;
      await IndexedBackupClient(
        fixture,
        Directory('${temporary.path}/fresh'),
      ).upload(snapshot, 'fresh');
      expect(fixture.metrics(start)['contentReadBytes'], 0);
      expect(
        fixture.s3!.files['/bucket/cloud/snapshots/old.json'],
        oldEnvelope,
      );
    },
  );

  for (final version in [2, 3]) {
    test(
      'schema $version remains restorable from its original namespace',
      () async {
        final fixture = IncrementalBackendFixture('s3');
        final legacy = fixture.create('legacy');
        final record = indexedRecord('image', 5, 1024);
        final object = record.payload!.sha256;
        await legacy.putObject(object, record.bytes!, sha256: object);
        final manifest = SnapshotManifest(
          version: version,
          snapshotId: 'old',
          createdAt: DateTime.utc(2025),
          records: [recordRef(record)],
        );
        final bytes = Uint8List.fromList(manifest.encode());
        final hash = EncryptedBackupCodec.hash(bytes);
        await legacy.putSnapshotManifest('old', bytes, sha256: hash);
        await legacy.commitHead(
          Uint8List.fromList(
            SnapshotHead(
              version: version,
              snapshotId: 'old',
              manifestSha256: hash,
              updatedAt: DateTime.utc(2025),
            ).encode(),
          ),
          expectedRevision: null,
        );
        final before = fixture.s3!.files.keys.toSet();
        expect(
          (await IndexedBackupClient(
            fixture,
            Directory('${temporary.path}/restore'),
          ).restore()).records,
          CloudSyncSnapshotData([record]).records,
        );
        expect(fixture.s3!.files.keys.toSet(), before);
      },
    );
  }

  test('changed remote version rereads only that volume', () async {
    final fixture = IncrementalBackendFixture('s3');
    final writer = IndexedBackupClient(
      fixture,
      Directory('${temporary.path}/writer'),
    );
    final snapshot = CloudSyncSnapshotData([
      indexedRecord('image', 1, 4 * 1024 * 1024),
    ]);
    await writer.upload(snapshot, 'before');
    final id = fixture.contentIds.first;
    final path = '/bucket/cloud/objects/$id';
    fixture.s3!.versions[path] = fixture.s3!.versions[path]! + 1;
    final start = fixture.samples.length;
    await IndexedBackupClient(
      fixture,
      Directory('${temporary.path}/fresh'),
    ).upload(snapshot, 'after');
    expect(
      fixture.metrics(start)['contentReadBytes'],
      fixture.s3!.files[path]!.length,
    );
    expect(fixture.metrics(start)['contentWrittenBytes'], 0);
  });

  for (final fresh in [false, true]) {
    test('missing volume is repaired with fresh device $fresh', () async {
      final fixture = IncrementalBackendFixture('s3');
      final cacheDirectory = Directory('${temporary.path}/writer');
      final snapshot = CloudSyncSnapshotData([
        indexedRecord('image', 2, 4 * 1024 * 1024),
      ]);
      await IndexedBackupClient(
        fixture,
        cacheDirectory,
      ).upload(snapshot, 'before');
      final id = fixture.contentIds.last;
      fixture.s3!.files.remove('/bucket/cloud/objects/$id');
      final next = IndexedBackupClient(
        fixture,
        fresh ? Directory('${temporary.path}/fresh') : cacheDirectory,
      );
      await next.upload(snapshot, 'after');
      expect(
        (await IndexedBackupClient(
          fixture,
          Directory('${temporary.path}/restore'),
        ).restore()).records,
        snapshot.records,
      );
    });
  }

  for (final fallback in ['head-unsupported', 'no-validator', 'etag-only']) {
    test('S3 $fallback retains functional fallback and manual mode', () async {
      final fixture = IncrementalBackendFixture('s3');
      fixture.s3!.supportsHead = fallback != 'head-unsupported';
      fixture.s3!.providesVersion = false;
      fixture.s3!.providesEtag = fallback == 'etag-only';
      final snapshot = CloudSyncSnapshotData([indexedRecord('image', 1, 4096)]);
      await IndexedBackupClient(
        fixture,
        Directory('${temporary.path}/writer'),
      ).upload(snapshot, 'before');
      final start = fixture.samples.length;
      final fresh = IndexedBackupClient(
        fixture,
        Directory('${temporary.path}/fresh'),
      );
      await fresh.upload(snapshot, 'after');
      expect(fixture.metrics(start)['contentWrittenBytes'], 0);
      expect(
        fixture.metrics(start)['contentReadBytes'],
        fallback == 'etag-only' ? 0 : greaterThan(0),
      );
      expect(
        (await fresh.backend.testCapability()).mode,
        CloudBackendMode.manualBackupOnly,
      );
    });
  }

  test(
    'repair retry keeps its new mapping when old HEAD still references a missing volume',
    () async {
      final fixture = IncrementalBackendFixture('s3');
      final snapshot = CloudSyncSnapshotData([indexedRecord('image', 9, 8192)]);
      await IndexedBackupClient(
        fixture,
        Directory('${temporary.path}/old'),
      ).upload(snapshot, 'old');
      fixture.s3!.files.remove(
        '/bucket/cloud/objects/${fixture.contentIds.single}',
      );
      final directory = Directory('${temporary.path}/repair');
      final first = IndexedBackupClient(
        fixture,
        directory,
        currentOverride: _LostResponseBackend(
          fixture.create('cloud'),
          'object',
        ),
      );
      await expectLater(
        first.upload(snapshot, 'repair'),
        throwsA(isA<CloudBackendException>()),
      );
      final object = snapshot.records.values.single.payload!.sha256;
      final planned = (await first.cache.readPlan('objects', object))!;
      final resumed = IndexedBackupClient(fixture, directory);
      resumed.source.artifacts.addAll(first.source.artifacts);
      resumed.journals.addAll(first.journals);
      await resumed.upload(snapshot, 'repair');
      expect(
        (await resumed.cache.readPlan('objects', object))!['parts'],
        planned['parts'],
      );
      expect(
        (await IndexedBackupClient(
          fixture,
          Directory('${temporary.path}/restored'),
        ).restore()).records,
        snapshot.records,
      );
    },
  );

  test(
    'manual WebDAV with weak validators reads content without reuploading it',
    () async {
      final fixture = IncrementalBackendFixture('webdav');
      fixture.webdav!.strongEtags = false;
      final snapshot = CloudSyncSnapshotData([indexedRecord('image', 4, 4096)]);
      await IndexedBackupClient(
        fixture,
        Directory('${temporary.path}/writer'),
      ).upload(snapshot, 'before');
      final start = fixture.samples.length;
      await IndexedBackupClient(
        fixture,
        Directory('${temporary.path}/fresh'),
      ).upload(snapshot, 'after');
      expect(fixture.metrics(start)['contentReadBytes'], greaterThan(0));
      expect(fixture.metrics(start)['contentWrittenBytes'], 0);
    },
  );

  test('cancelled inventory does not publish another snapshot', () async {
    final fixture = IncrementalBackendFixture('s3');
    final client = IndexedBackupClient(
      fixture,
      Directory('${temporary.path}/writer'),
    );
    final record = indexedRecord('image', 5, 1024);
    await client.upload(CloudSyncSnapshotData([record]), 'first');
    final before = List<int>.of(fixture.s3!.files['/bucket/cloud/HEAD.json']!);
    final token = OperationToken();
    await client.backend.prepareSnapshotUpload('cancelled', token);
    token.cancel();
    await expectLater(
      client.backend.findExistingObjects({
        record.payload!.sha256: 1024,
      }, token: token),
      throwsA(anything),
    );
    expect(fixture.s3!.files['/bucket/cloud/HEAD.json'], before);
  });

  test(
    'pending upload reports advanced HEAD and preserves the newer snapshot',
    () async {
      final fixture = IncrementalBackendFixture('s3');
      final snapshot = CloudSyncSnapshotData([indexedRecord('image', 1, 4096)]);
      final directory = Directory('${temporary.path}/pending');
      final first = IndexedBackupClient(
        fixture,
        directory,
        currentOverride: _LostResponseBackend(
          fixture.create('cloud'),
          'manifest',
        ),
      );
      await expectLater(
        first.upload(snapshot, 'pending'),
        throwsA(isA<CloudBackendException>()),
      );
      final newer = CloudSyncSnapshotData([indexedRecord('image', 2, 4096)]);
      await IndexedBackupClient(
        fixture,
        Directory('${temporary.path}/other'),
      ).upload(newer, 'newer');
      final resumed = IndexedBackupClient(fixture, directory);
      resumed.source.artifacts.addAll(first.source.artifacts);
      resumed.journals.addAll(first.journals);
      await expectLater(
        resumed.upload(snapshot, 'pending'),
        throwsA(
          isA<CloudBackendException>().having(
            (e) => e.kind,
            'kind',
            CloudBackendErrorKind.conflict,
          ),
        ),
      );
      expect(
        (await IndexedBackupClient(
          fixture,
          Directory('${temporary.path}/restore'),
        ).restore()).records,
        newer.records,
      );
    },
  );

  test('retaining one GitHub version preserves its shared volumes', () async {
    final fixture = IncrementalBackendFixture('github');
    final snapshot = CloudSyncSnapshotData([indexedRecord('image', 8, 8192)]);
    final client = IndexedBackupClient(
      fixture,
      Directory('${temporary.path}/writer'),
    );
    client.backend.keepSnapshots = 1;
    await client.upload(snapshot, 'first');
    await client.upload(snapshot, 'second');
    expect(await client.backend.listSnapshotIds(), ['second']);
    expect(
      (await IndexedBackupClient(
        fixture,
        Directory('${temporary.path}/restore'),
      ).restore()).records,
      snapshot.records,
    );
  });

  for (final provider in ['s3', 'github']) {
    for (final stage in ['object', 'manifest', 'head']) {
      test(
        '$provider resumes identical artifacts after lost $stage response',
        () async {
          final fixture = IncrementalBackendFixture(provider);
          final directory = Directory('${temporary.path}/writer');
          final snapshot = CloudSyncSnapshotData([
            indexedRecord('image', 7, 8192),
          ]);
          final first = IndexedBackupClient(
            fixture,
            directory,
            currentOverride: _LostResponseBackend(
              fixture.create('cloud'),
              stage,
            ),
          );
          await expectLater(
            first.upload(snapshot, 'pending'),
            throwsA(isA<CloudBackendException>()),
          );
          final object = snapshot.records.values.single.payload!.sha256;
          final before = (await first.cache.readPlan('objects', object))!;
          final beforeEnvelope = (await first.cache.readPlan(
            'snapshots',
            'pending',
          ))?['envelope'];
          final resumed = IndexedBackupClient(fixture, directory);
          resumed.source.artifacts.addAll(first.source.artifacts);
          resumed.journals.addAll(first.journals);
          await resumed.upload(snapshot, 'pending');
          final after = (await resumed.cache.readPlan('objects', object))!;
          expect(after['parts'], before['parts']);
          expect(after['key'], before['key']);
          if (beforeEnvelope != null) {
            expect(
              (await resumed.cache.readPlan(
                'snapshots',
                'pending',
              ))!['envelope'],
              beforeEnvelope,
            );
          }
          expect(
            (await IndexedBackupClient(
              fixture,
              Directory('${temporary.path}/restore'),
            ).restore()).records,
            snapshot.records,
          );
        },
      );
    }
  }
}

class _LostResponseBackend
    implements CloudSyncBackend, CloudObjectInventoryBackend {
  _LostResponseBackend(this.delegate, this.stage);
  final CloudSyncBackend delegate;
  final String stage;
  bool lost = false;
  Future<CloudCommitResult> _write(
    String point,
    Future<CloudCommitResult> write,
  ) async {
    final result = await write;
    if (!lost && stage == point) {
      lost = true;
      throw const CloudBackendException(
        CloudBackendErrorKind.network,
        'response lost',
      );
    }
    return result;
  }

  @override
  Future<CloudCommitResult> putObject(
    String id,
    Uint8List bytes, {
    required String sha256,
    bool payloadVerified = false,
  }) => _write(
    'object',
    delegate.putObject(
      id,
      bytes,
      sha256: sha256,
      payloadVerified: payloadVerified,
    ),
  );
  @override
  Future<CloudCommitResult> putSnapshotManifest(
    String id,
    Uint8List bytes, {
    required String sha256,
    bool payloadVerified = false,
  }) => _write(
    'manifest',
    delegate.putSnapshotManifest(
      id,
      bytes,
      sha256: sha256,
      payloadVerified: payloadVerified,
    ),
  );
  @override
  Future<CloudCommitResult> commitHead(
    Uint8List bytes, {
    required String? expectedRevision,
  }) => _write(
    'head',
    delegate.commitHead(bytes, expectedRevision: expectedRevision),
  );
  @override
  Future<CloudObjectInventoryResult> findExistingObjects(
    Map<String, int> expectedObjects, {
    Map<String, String> trustedRevisions = const {},
    OperationToken? token,
    CloudObjectInventoryProgressCallback? onProgress,
  }) => (delegate as CloudObjectInventoryBackend).findExistingObjects(
    expectedObjects,
    trustedRevisions: trustedRevisions,
    token: token,
    onProgress: onProgress,
  );
  @override
  Future<CloudHeadRead?> readHead() => delegate.readHead();
  @override
  Future<CloudObjectRead?> readObject(String id) => delegate.readObject(id);
  @override
  Future<CloudObjectRead?> readSnapshotManifest(String id) =>
      delegate.readSnapshotManifest(id);
  @override
  Future<CloudBackendCapability> testCapability() => delegate.testCapability();
  @override
  Future<List<String>> listSnapshotIds({int limit = 20}) =>
      delegate.listSnapshotIds(limit: limit);
  @override
  Future<void> deleteNamespace() => delegate.deleteNamespace();
}
