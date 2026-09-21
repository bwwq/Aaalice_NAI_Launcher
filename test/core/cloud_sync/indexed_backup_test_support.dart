import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:nai_launcher/core/cloud_sync/data_source.dart';
import 'package:nai_launcher/core/cloud_sync/backend/cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/backend/webdav_cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/encrypted_backup_cache.dart';
import 'package:nai_launcher/core/cloud_sync/encrypted_cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/journal.dart';
import 'package:nai_launcher/core/cloud_sync/models.dart';
import 'package:nai_launcher/core/cloud_sync/operation.dart';
import 'package:nai_launcher/core/cloud_sync/snapshot_transfer.dart';
import 'package:nai_launcher/core/cloud_sync/snapshot_uploader.dart';
import 'backend/incremental_backend_fixture.dart';
import 'packed_snapshot_contract.dart';

CloudSyncRecord indexedRecord(
  String id,
  int seed,
  int size, {
  bool binary = true,
}) {
  final random = Random(seed);
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = random.nextInt(256);
  }
  return CloudSyncRecord(
    id: id,
    kind: binary ? 'resource' : 'metadata',
    binary: binary,
    deleted: false,
    bytes: bytes,
  );
}

class IndexedBackupClient {
  IndexedBackupClient(
    this.fixture,
    Directory directory, {
    CloudSyncBackend? currentOverride,
  }) : cache = EncryptedBackupCache(directory) {
    backend = EncryptedCloudSyncBackend(
      current: currentOverride ?? fixture.create('cloud'),
      legacy: fixture.create('legacy'),
      cache: cache,
    );
  }
  final IncrementalBackendFixture fixture;
  final EncryptedBackupCache cache;
  late final EncryptedCloudSyncBackend backend;
  final source = PackedSnapshotArtifacts();
  final journals = <String, SyncJournal>{};
  final _active = <OperationToken, Future<void>>{};

  Future<T> _run<T>(Future<T> Function(OperationToken) action) {
    final token = OperationToken();
    final deadline = Timer(const Duration(seconds: 25), token.cancel);
    final result = token.runInScope(() => action(token)).whenComplete(() {
      deadline.cancel();
      _active.remove(token);
    });
    _active[token] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> cancelAndDrain() async {
    final pending = Map.of(_active);
    for (final token in pending.keys) {
      token.cancel();
    }
    await Future.wait(pending.values);
  }

  Future<SnapshotManifest> upload(
    CloudSyncSnapshotData snapshot,
    String id,
  ) async {
    return _run((token) async {
      if (backend.current is WebDavCloudSyncBackend) {
        await (backend.current as WebDavCloudSyncBackend)
            .validateConnectionReadOnly();
      }
      final head = await backend.readHead();
      await ResumableSnapshotUploader(
        backend: backend,
        dataSource: source,
        now: () => DateTime.utc(2026),
      ).resume(
        journal: journals.putIfAbsent(
          id,
          () => SyncJournal(
            operationId: id,
            operation: JournalOperation.uploadLocal,
            phase: JournalPhase.prepared,
            updatedAt: DateTime.utc(2026),
            snapshotId: id,
            targetFingerprint: 'a' * 64,
            expectedRevision: head?.revision,
            uploadRequired: true,
          ),
        ),
        snapshot: snapshot,
        token: token,
        checkpoint: (journal) async {
          journals[id] = journal;
        },
      );
      final manifest = SnapshotManifest.decode(
        source.artifacts['$id/manifest.json']!,
      );
      final packed = manifest.packs.values.expand((ids) => ids).toSet();
      final objects = {
        ...manifest.packs.keys,
        for (final ref in manifest.records)
          if (!ref.deleted && !packed.contains(ref.objectId)) ref.objectId!,
      };
      for (final object in objects) {
        final plan = await cache.readPlan('objects', object);
        if (plan != null)
          fixture.contentIds.addAll((plan['parts'] as List).cast<String>());
      }
      return manifest;
    });
  }

  Future<CloudSyncSnapshotData> restore() {
    return _run(
      (token) async =>
          CloudSnapshotTransfer(
            backend: backend,
            dataSource: source,
          ).downloadHead(
            SnapshotHead.decode((await backend.readHead())!.bytes),
            token,
            null,
          ),
    );
  }
}
