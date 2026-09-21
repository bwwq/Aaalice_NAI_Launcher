import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/data_source.dart';
import 'backend/incremental_backend_fixture.dart';
import 'indexed_backup_test_support.dart';

void main() {
  final reports = <String, Object?>{};
  final benchmark = Platform.environment['CLOUD_INDEX_BENCHMARK'] == '1';
  for (final provider in incrementalProviders) {
    group(provider, () {
      late Directory temporary;
      late IncrementalBackendFixture fixture;
      late CloudSyncSnapshotData snapshot;
      late IndexedBackupClient writer;
      final clients = <IndexedBackupClient>[];
      final phases = <String, Object?>{};
      final size = (benchmark ? 64 : 4) * 1024 * 1024;

      IndexedBackupClient client(String directory) {
        final result = IndexedBackupClient(
          fixture,
          Directory('${temporary.path}/$directory'),
        );
        clients.add(result);
        return result;
      }

      setUpAll(() async {
        temporary = await Directory.systemTemp.createTemp('indexed-backup-');
        fixture = IncrementalBackendFixture(provider);
        snapshot = CloudSyncSnapshotData([
          for (var i = 0; i < size ~/ (1024 * 1024); i++)
            indexedRecord('image-$i', i + 1, 1024 * 1024),
        ]);
        writer = client('writer');
        reports[provider] = {'logicalBytes': size, 'phases': phases};
      });
      tearDown(() async {
        // Drain cancelled work before any subsequent phase or cache cleanup.
        for (final item in clients) {
          await item.cancelAndDrain();
        }
      });
      tearDownAll(() async {
        for (final item in clients) {
          await item.cancelAndDrain();
        }
        await temporary.delete(recursive: true);
      });

      test('initial upload', () async {
        final watch = Stopwatch()..start();
        await writer.upload(snapshot, 'first');
        phases['first'] = {
          ...fixture.metrics(0),
          'elapsedMs': watch.elapsedMilliseconds,
        };
      });

      for (final phase in ['same-device', 'restart', 'fresh-device']) {
        test('$phase reuses all content', () async {
          expect(phases, contains('first'));
          final current = phase == 'same-device'
              ? writer
              : client(phase == 'restart' ? 'writer' : 'fresh');
          final start = fixture.samples.length;
          final watch = Stopwatch()..start();
          await current.upload(snapshot, phase);
          final metrics = fixture.metrics(start);
          expect(metrics['contentReadBytes'], 0, reason: '$provider/$phase');
          expect(metrics['contentWrittenBytes'], 0, reason: '$provider/$phase');
          expect(metrics['indexReadBytes'], greaterThan(0));
          phases[phase] = {...metrics, 'elapsedMs': watch.elapsedMilliseconds};
        });
      }

      test('one changed record transfers only its new content', () async {
        expect(phases, contains('fresh-device'));
        snapshot = CloudSyncSnapshotData([
          indexedRecord('image-0', 1000, 1024 * 1024),
          ...snapshot.records.values.skip(1),
        ]);
        final start = fixture.samples.length;
        final watch = Stopwatch()..start();
        await client('changed').upload(snapshot, 'changed');
        final metrics = fixture.metrics(start);
        expect(metrics['contentWrittenBytes'], greaterThan(1024 * 1024));
        expect(metrics['contentWrittenBytes'], lessThan(2 * 1024 * 1024));
        expect(metrics['contentReadBytes'], lessThan(2 * 1024 * 1024));
        phases['changed-record'] = {
          ...metrics,
          'elapsedMs': watch.elapsedMilliseconds,
        };
      });

      test('restores the full changed snapshot', () async {
        expect(phases, contains('changed-record'));
        final start = fixture.samples.length;
        final watch = Stopwatch()..start();
        final restored = await client('restore').restore();
        expect(restored.records, snapshot.records);
        phases['restore'] = {
          ...fixture.metrics(start),
          'elapsedMs': watch.elapsedMilliseconds,
        };
      });
    });
  }
  tearDownAll(() async {
    final path = Platform.environment['CLOUD_INDEX_REPORT'];
    if (path != null) {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(reports),
      );
    }
  });
}
