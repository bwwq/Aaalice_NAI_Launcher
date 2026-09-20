import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/backend/cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/data_source.dart';
import 'package:nai_launcher/core/cloud_sync/models.dart';
import 'package:nai_launcher/core/cloud_sync/operation.dart';
import 'package:nai_launcher/core/cloud_sync/snapshot_transfer.dart';

import 'coordinator_test_backend.dart';

void main() {
  for (final version in [2, 3, 4]) {
    test(
      'browse schema $version reads metadata only and loads original on demand',
      () async {
        final backend = _ConcurrentReadBackend();
        final one = Uint8List.fromList([1]);
        final two = Uint8List.fromList([2]);
        final original = Uint8List(2 * 1024 * 1024)..[0] = 7;
        final oneId = sha256.convert(one).toString();
        final twoId = sha256.convert(two).toString();
        final imageId = sha256.convert(original).toString();
        final pack = Uint8List.fromList([...one, ...two]);
        final packId = sha256.convert(pack).toString();
        for (final bytes in [one, two, original, pack]) {
          backend.objects[sha256.convert(bytes).toString()] = CloudObjectRead(
            bytes: bytes,
            revision: 'r',
          );
        }
        final manifest = SnapshotManifest(
          version: version,
          snapshotId: 'old',
          createdAt: DateTime.utc(2026),
          records: [
            SnapshotRecordRef(
              recordId: 'a',
              kind: 'metadata',
              binary: true,
              deleted: false,
              objectId: oneId,
              size: 1,
            ),
            SnapshotRecordRef(
              recordId: 'b',
              kind: 'metadata',
              binary: false,
              deleted: false,
              objectId: twoId,
              size: 1,
            ),
            SnapshotRecordRef(
              recordId: 'c',
              kind: 'resource',
              binary: true,
              deleted: false,
              objectId: imageId,
              size: original.length,
            ),
          ],
          packs: version == 2
              ? {}
              : {
                  packId: [oneId, twoId],
                },
        );
        final transfer = CloudSnapshotTransfer(
          backend: backend,
          dataSource: _NoopSource(),
        );
        final token = OperationToken();
        final snapshot = await transfer.browseManifest(manifest, token, null);
        expect(backend.readCalls, version == 2 ? 2 : 1);
        expect(await snapshot.records['a']!.readBytes(), one);
        expect(await snapshot.records['c']!.readBytes(), original);
        expect(backend.readCalls, version == 2 ? 3 : 2);
        final reads = backend.readCalls;
        token.cancel();
        await expectLater(
          snapshot.records['c']!.readBytes(),
          throwsA(isA<OperationCancelledException>()),
        );
        expect(backend.readCalls, reads);
      },
    );
  }

  test(
    'unique objects download concurrently and rebuild manifest order',
    () async {
      final backend = _ConcurrentReadBackend();
      final payloads = <Uint8List>[
        Uint8List.fromList([1]),
        Uint8List.fromList([2, 2]),
        Uint8List.fromList([3, 3, 3]),
      ];
      final refs = <SnapshotRecordRef>[];
      for (var index = 0; index < payloads.length; index++) {
        final objectId = sha256.convert(payloads[index]).toString();
        backend.objects[objectId] = CloudObjectRead(
          bytes: payloads[index],
          revision: 'r$index',
        );
        refs.add(
          SnapshotRecordRef(
            recordId: 'record-$index',
            kind: 'resource',
            binary: true,
            deleted: false,
            objectId: objectId,
            size: payloads[index].length,
          ),
        );
      }
      final progressBytes = <int>[];
      final source = _CountingSource();
      final transfer = CloudSnapshotTransfer(
        backend: backend,
        dataSource: source,
      );

      final snapshot = await transfer.downloadManifest(
        SnapshotManifest(
          snapshotId: 'snapshot',
          createdAt: DateTime.utc(2025),
          records: refs,
        ),
        OperationToken(),
        (progress) => progressBytes.add(progress.bytesCompleted),
      );

      expect(backend.maxActiveReads, greaterThan(1));
      expect(backend.readCalls, payloads.length);
      expect(source.materializations, payloads.length);
      expect(
        await Future.wait(
          snapshot.records.values.map((record) => record.readBytes()),
        ),
        payloads,
      );
      expect(progressBytes, orderedEquals([...progressBytes]..sort()));
      expect(
        progressBytes.last,
        payloads.fold<int>(0, (sum, item) => sum + item.length),
      );
    },
  );

  test('verified local objects bypass remote downloads', () async {
    final bytes = Uint8List.fromList([4, 5, 6]);
    final objectId = sha256.convert(bytes).toString();
    final backend = _ConcurrentReadBackend();
    final source = _ResolvingSource(bytes, objectId);

    final snapshot =
        await CloudSnapshotTransfer(
          backend: backend,
          dataSource: source,
        ).downloadManifest(
          SnapshotManifest(
            snapshotId: 'snapshot',
            createdAt: DateTime.utc(2025),
            records: [
              SnapshotRecordRef(
                recordId: 'local',
                kind: 'resource',
                binary: true,
                deleted: false,
                objectId: objectId,
                size: bytes.length,
              ),
            ],
          ),
          OperationToken(),
          null,
        );

    expect(backend.readCalls, 0);
    expect(await snapshot.records['local']!.readBytes(), bytes);
  });

  test('one failed object prevents publishing a partial snapshot', () async {
    final backend = _ConcurrentReadBackend();
    final good = Uint8List.fromList([1]);
    final goodId = sha256.convert(good).toString();
    final missingId = sha256.convert([2]).toString();
    backend.objects[goodId] = CloudObjectRead(bytes: good, revision: 'r1');
    final source = _NoopSource();
    final transfer = CloudSnapshotTransfer(
      backend: backend,
      dataSource: source,
    );

    await expectLater(
      transfer.downloadManifest(
        SnapshotManifest(
          snapshotId: 'snapshot',
          createdAt: DateTime.utc(2025),
          records: [
            SnapshotRecordRef(
              recordId: 'a',
              kind: 'resource',
              binary: true,
              deleted: false,
              objectId: goodId,
              size: good.length,
            ),
            SnapshotRecordRef(
              recordId: 'b',
              kind: 'resource',
              binary: true,
              deleted: false,
              objectId: missingId,
              size: 1,
            ),
          ],
        ),
        OperationToken(),
        null,
      ),
      throwsA(isA<CloudFormatException>()),
    );
    expect(source.stageCalls, 0);
  });
}

class _ConcurrentReadBackend extends CoordinatorTestBackend {
  var activeReads = 0;
  var maxActiveReads = 0;
  var readCalls = 0;

  @override
  Future<CloudObjectRead?> readObject(String objectId) async {
    readCalls++;
    activeReads++;
    if (activeReads > maxActiveReads) maxActiveReads = activeReads;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return super.readObject(objectId);
    } finally {
      activeReads--;
    }
  }
}

class _CountingSource extends _NoopSource
    implements CloudSyncPayloadMaterializer {
  var materializations = 0;

  @override
  Future<CloudSyncPayload> materializeRemotePayload(
    List<int> bytes, {
    required int expectedLength,
    required String expectedSha256,
  }) async {
    materializations++;
    final actual = Uint8List.fromList(bytes);
    expect(actual, hasLength(expectedLength));
    expect(sha256.convert(actual).toString(), expectedSha256);
    return CloudSyncPayload(
      length: actual.length,
      sha256: expectedSha256,
      openRead: () => Stream.value(actual),
    );
  }
}

class _ResolvingSource extends _NoopSource
    implements CloudSyncLocalPayloadResolver {
  _ResolvingSource(this.bytes, this.objectId);

  final Uint8List bytes;
  final String objectId;

  @override
  Future<CloudSyncPayload?> resolveLocalPayload({
    required int expectedLength,
    required String expectedSha256,
  }) async => expectedLength == bytes.length && expectedSha256 == objectId
      ? CloudSyncPayload(
          length: bytes.length,
          sha256: objectId,
          openRead: () => Stream.value(bytes),
        )
      : null;
}

class _NoopSource implements CloudSyncDataSource {
  var stageCalls = 0;

  @override
  Future<void> stage(
    String operationId,
    CloudSyncSnapshotData snapshot, {
    CloudSyncSnapshotData? recoveryPoint,
  }) async {
    stageCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
