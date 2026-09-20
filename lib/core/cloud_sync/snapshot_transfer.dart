import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;

import 'backend/cloud_sync_backend.dart';
import 'bounded_transfer_scheduler.dart';
import 'data_source.dart';
import 'models.dart';
import 'operation.dart';
import 'sync_types.dart';
import 'telemetry.dart';

class CloudSnapshotTransfer {
  const CloudSnapshotTransfer({
    required this.backend,
    required this.dataSource,
    this.transferLimits,
  });

  final CloudSyncBackend backend;
  final CloudSyncDataSource dataSource;
  final CloudTransferLimits? transferLimits;

  CloudTransferLimits get _transferLimits =>
      transferLimits ?? cloudTransferPlatformLimits;

  Future<CloudSyncSnapshotData> downloadHead(
    SnapshotHead head,
    OperationToken token,
    SyncProgressCallback? onProgress,
  ) async {
    final read = await backend.readSnapshotManifest(head.snapshotId);
    if (read == null) {
      throw const CloudFormatException('snapshot manifest is missing');
    }
    head.verifyManifest(read.bytes);
    return _decodeAndDownload(head.snapshotId, read.bytes, token, onProgress);
  }

  Future<CloudSyncSnapshotData> downloadId(
    String snapshotId,
    OperationToken token,
    SyncProgressCallback? onProgress,
  ) async {
    final read = await backend.readSnapshotManifest(snapshotId);
    if (read == null) {
      throw const CloudFormatException('snapshot manifest is missing');
    }
    return _decodeAndDownload(snapshotId, read.bytes, token, onProgress);
  }

  /// Read the metadata already committed with the snapshot. Original resources
  /// remain lazy and are fetched only when a content viewer opens them.
  Future<CloudSyncSnapshotData> browseId(
    String snapshotId,
    OperationToken token,
    SyncProgressCallback? onProgress,
  ) async {
    await token.checkpoint();
    final read = await backend.readSnapshotManifest(snapshotId);
    if (read == null) {
      throw const CloudFormatException('snapshot manifest is missing');
    }
    final manifest = SnapshotManifest.decode(read.bytes);
    if (manifest.snapshotId != snapshotId) {
      throw const CloudFormatException('snapshot manifest identity mismatch');
    }
    return browseManifest(manifest, token, onProgress);
  }

  Future<CloudSyncSnapshotData> browseManifest(
    SnapshotManifest manifest,
    OperationToken token,
    SyncProgressCallback? onProgress,
  ) async {
    final requiredIds = {
      for (final ref in manifest.records)
        if (!ref.deleted && ref.kind == 'metadata') ref.objectId!,
    };
    final selectedPacks = <String, List<String>>{};
    for (final pack in manifest.packs.entries) {
      if (pack.value.any(requiredIds.contains)) {
        selectedPacks[pack.key] = pack.value;
        requiredIds.addAll(pack.value);
      }
    }
    final metadata = await downloadManifest(
      SnapshotManifest(
        snapshotId: manifest.snapshotId,
        createdAt: manifest.createdAt,
        version: manifest.version,
        packs: selectedPacks,
        records: manifest.records
            .where((ref) => ref.deleted || requiredIds.contains(ref.objectId))
            .toList(),
      ),
      token,
      onProgress,
    );
    final sizes = {
      for (final ref in manifest.records)
        if (!ref.deleted) ref.objectId!: ref.size!,
    };
    final packByMember = {
      for (final pack in manifest.packs.entries)
        for (final id in pack.value) id: pack.key,
    };
    return CloudSyncSnapshotData([
      for (final ref in manifest.records)
        if (metadata.records.containsKey(ref.recordId))
          metadata.records[ref.recordId]!
        else
          CloudSyncRecord(
            id: ref.recordId,
            kind: ref.kind,
            binary: ref.binary,
            deleted: false,
            payload: CloudSyncPayload(
              length: ref.size!,
              sha256: ref.objectId!,
              openRead: () async* {
                final bytes = await token.runInScope(() async {
                  await token.checkpoint();
                  final packId = packByMember[ref.objectId];
                  final id = packId ?? ref.objectId!;
                  final size = packId == null
                      ? ref.size!
                      : manifest.packs[packId]!.fold<int>(
                          0,
                          (sum, member) => sum + sizes[member]!,
                        );
                  final object = await _readObject(id, size);
                  await token.checkpoint();
                  final bytes =
                      object.bytes ?? await object.payload!.readBytes();
                  if (packId == null) return bytes;
                  var offset = 0;
                  for (final member in manifest.packs[packId]!) {
                    if (member == ref.objectId) {
                      return Uint8List.sublistView(
                        bytes,
                        offset,
                        offset + ref.size!,
                      );
                    }
                    offset += sizes[member]!;
                  }
                  throw const CloudFormatException(
                    'packed resource is missing',
                  );
                });
                yield bytes;
              },
            ),
          ),
    ]);
  }

  Future<CloudSyncSnapshotData> downloadManifest(
    SnapshotManifest manifest,
    OperationToken token,
    SyncProgressCallback? onProgress,
  ) async {
    final objectSizes = {
      for (final ref in manifest.records)
        if (!ref.deleted) ref.objectId!: ref.size!,
    };
    final transportSizes = {...objectSizes};
    for (final pack in manifest.packs.entries) {
      var length = 0;
      for (final id in pack.value) {
        length += transportSizes.remove(id)!;
      }
      transportSizes[pack.key] = length;
    }
    final entries = transportSizes.entries.toList(growable: false);
    final total = transportSizes.values.fold<int>(0, (sum, size) => sum + size);
    var bytesCompleted = 0;
    var objectsCompleted = 0;
    onProgress?.call(
      SyncProgress(
        phase: SyncPhase.downloading,
        objectsTotal: entries.length,
        bytesTotal: total,
      ),
    );

    final scheduler = BoundedTransferScheduler(
      maxConcurrentItems: _transferConcurrency,
      maxBytesInFlight: _transferLimits.maxBytesInFlight,
    );
    final downloaded = await scheduler
        .run<MapEntry<String, int>, _DownloadedObject>(
          items: [
            for (final entry in entries)
              BoundedTransferItem(value: entry, bytes: entry.value),
          ],
          token: token,
          transfer: (entry) async {
            final object = await _readObject(entry.key, entry.value);
            bytesCompleted += entry.value;
            objectsCompleted++;
            onProgress?.call(
              SyncProgress(
                phase: SyncPhase.downloading,
                objectId: entry.key,
                objectsCompleted: objectsCompleted,
                objectsTotal: entries.length,
                bytesCompleted: bytesCompleted,
                bytesTotal: total,
              ),
            );
            return object;
          },
        );
    onProgress?.call(
      SyncProgress(
        phase: SyncPhase.verifying,
        objectsCompleted: entries.length,
        objectsTotal: entries.length,
        bytesCompleted: total,
        bytesTotal: total,
      ),
    );
    final objects = <String, _DownloadedObject>{
      for (var index = 0; index < entries.length; index++)
        entries[index].key: downloaded[index],
    };
    await _expandPacks(manifest, objects, objectSizes, token);
    return _buildSnapshot(manifest, objects);
  }

  Future<_DownloadedObject> _readObject(String id, int size) async {
    if (dataSource case final CloudSyncLocalPayloadResolver resolver) {
      final payload = await resolver.resolveLocalPayload(
        expectedLength: size,
        expectedSha256: id,
      );
      if (payload != null) {
        _verifyPayloadIdentity(payload, id, size);
        return _DownloadedObject(payload: payload, bytes: null);
      }
    }
    final read = await backend.readObject(id);
    if (read == null) throw CloudFormatException('object $id is missing');
    return _materializeObject(id, size, read.bytes);
  }

  Future<_DownloadedObject> _materializeObject(
    String id,
    int size,
    Uint8List bytes,
  ) async {
    if (dataSource case final CloudSyncPayloadMaterializer materializer) {
      final payload = await materializer.materializeRemotePayload(
        bytes,
        expectedLength: size,
        expectedSha256: id,
      );
      _verifyPayloadIdentity(payload, id, size);
      return _DownloadedObject(payload: payload, bytes: null);
    }
    CloudSyncTelemetry.recordHashPass();
    if (bytes.length != size || hashes.sha256.convert(bytes).toString() != id) {
      throw CloudFormatException(
        'object $id failed size or SHA-256 validation',
      );
    }
    return _DownloadedObject(payload: null, bytes: bytes);
  }

  void _verifyPayloadIdentity(CloudSyncPayload payload, String id, int size) {
    if (payload.length != size || payload.sha256 != id) {
      throw const CloudFormatException(
        'materialized payload identity mismatch',
      );
    }
  }

  Future<void> _expandPacks(
    SnapshotManifest manifest,
    Map<String, _DownloadedObject> objects,
    Map<String, int> objectSizes,
    OperationToken token,
  ) async {
    for (final pack in manifest.packs.entries) {
      await token.checkpoint();
      final object = objects.remove(pack.key)!;
      final bytes = object.bytes ?? await object.payload!.readBytes();
      var offset = 0;
      for (final id in pack.value) {
        await token.checkpoint();
        final size = objectSizes[id]!;
        final member = Uint8List.sublistView(bytes, offset, offset + size);
        offset += size;
        objects[id] = await _materializeObject(id, size, member);
      }
    }
  }

  CloudSyncSnapshotData _buildSnapshot(
    SnapshotManifest manifest,
    Map<String, _DownloadedObject> objects,
  ) {
    final records = <CloudSyncRecord>[];
    for (final ref in manifest.records) {
      if (ref.deleted) {
        records.add(
          CloudSyncRecord(
            id: ref.recordId,
            kind: ref.kind,
            binary: ref.binary,
            deleted: true,
            tombstoneIdentity: ref.tombstoneIdentity,
          ),
        );
      } else {
        records.add(
          CloudSyncRecord(
            id: ref.recordId,
            kind: ref.kind,
            binary: ref.binary,
            deleted: false,
            bytes: objects[ref.objectId!]!.bytes,
            payload: objects[ref.objectId!]!.payload,
          ),
        );
      }
    }
    return CloudSyncSnapshotData(records);
  }

  Future<bool> matches(
    String snapshotId,
    CloudSyncSnapshotData snapshot,
    OperationToken token,
  ) async {
    await token.checkpoint();
    final remote = await downloadId(snapshotId, token, null);
    if (remote.records.length != snapshot.records.length) return false;
    for (final entry in remote.records.entries) {
      if (snapshot.records[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<CloudSyncSnapshotData> _decodeAndDownload(
    String snapshotId,
    List<int> encodedManifest,
    OperationToken token,
    SyncProgressCallback? onProgress,
  ) async {
    final manifest = SnapshotManifest.decode(encodedManifest);
    if (manifest.snapshotId != snapshotId) {
      throw const CloudFormatException('snapshot manifest identity mismatch');
    }
    return downloadManifest(manifest, token, onProgress);
  }

  int get _transferConcurrency {
    final requested = backend is ConcurrentCloudObjectUploadBackend
        ? (backend as ConcurrentCloudObjectUploadBackend)
              .maxConcurrentObjectUploads
        : 4;
    return requested.clamp(1, _transferLimits.maxConcurrentItems);
  }
}

final class _DownloadedObject {
  const _DownloadedObject({required this.payload, required this.bytes});

  final CloudSyncPayload? payload;
  final Uint8List? bytes;
}
