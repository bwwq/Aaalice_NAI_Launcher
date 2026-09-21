import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/data_source.dart';
import 'package:nai_launcher/core/cloud_sync/models.dart';
import 'package:nai_launcher/core/cloud_sync/operation.dart';
import 'package:nai_launcher/core/cloud_sync/snapshot_upload_plan.dart';
import 'backend/incremental_backend_fixture.dart';
import 'indexed_backup_test_support.dart';
import 'packed_snapshot_contract.dart';

void main() {
  for (final change in ['edit', 'add', 'delete', 'shared-reference']) {
    test('stable packing preserves unrelated packs after $change', () async {
      final temporary = await Directory.systemTemp.createTemp('indexed-packs-');
      addTearDown(() => temporary.delete(recursive: true));
      final fixture = IncrementalBackendFixture('s3');
      final client = IndexedBackupClient(
        fixture,
        Directory('${temporary.path}/writer'),
      );
      final records = [
        for (var i = 0; i < 64; i++)
          indexedRecord('record-$i', i, 64 * 1024, binary: false),
      ];
      final first = await client.upload(
        CloudSyncSnapshotData(records),
        'before',
      );
      expect(first.packs, hasLength(4));
      final affected = first.packs.entries
          .firstWhere(
            (entry) => entry.value.contains(records.first.payload!.sha256),
          )
          .key;
      switch (change) {
        case 'edit':
          records[0] = indexedRecord('record-0', 999, 64 * 1024, binary: false);
        case 'add':
          records.add(indexedRecord('added', 999, 1024, binary: false));
        case 'delete':
          records.removeAt(0);
        case 'shared-reference':
          records.add(
            CloudSyncRecord(
              id: 'shared',
              kind: 'metadata',
              binary: false,
              deleted: false,
              payload: records.first.payload,
            ),
          );
      }
      final start = fixture.samples.length;
      final next = await client.upload(CloudSyncSnapshotData(records), 'after');
      final preserved = first.packs.keys.where(next.packs.containsKey).toSet();
      expect(
        preserved,
        containsAll(first.packs.keys.where((id) => id != affected)),
      );
      expect(
        fixture.metrics(start)['contentWrittenBytes'],
        lessThan(1100 * 1024),
      );
      if (change == 'shared-reference') {
        expect(preserved, hasLength(4));
        expect(fixture.metrics(start)['contentWrittenBytes'], 0);
      }
      expect(
        (await IndexedBackupClient(
          fixture,
          Directory('${temporary.path}/restore'),
        ).restore()).records,
        CloudSyncSnapshotData(records).records,
      );
    });
  }
  test(
    'pending manifest wins over a different current packing baseline',
    () async {
      final records = [for (var i = 0; i < 4; i++) configRecord('r$i', i)];
      final source = PackedSnapshotArtifacts();
      Future<SnapshotUploadPlan> prepare({SnapshotManifest? baseline}) =>
          SnapshotUploadPlan.prepare(
            dataSource: source,
            snapshot: CloudSyncSnapshotData(records),
            operationId: 'pending',
            snapshotId: 'pending',
            now: () => DateTime.utc(2026),
            token: OperationToken(),
            baseline: baseline,
          );
      final first = await prepare();
      final baseline = SnapshotManifest(
        snapshotId: 'different',
        createdAt: DateTime.utc(2026),
        records: records.map(recordRef).toList(),
      );
      final resumed = await prepare(baseline: baseline);
      expect(resumed.manifestBytes, first.manifestBytes);
      expect(resumed.manifest.packs, first.manifest.packs);
    },
  );
}
