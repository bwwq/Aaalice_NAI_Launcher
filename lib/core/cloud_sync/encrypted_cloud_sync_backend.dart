import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'backend/cloud_sync_backend.dart';
import 'encrypted_backup_cache.dart';
import 'encrypted_backup_codec.dart';
import 'models.dart';
import 'operation.dart';

/// Keeps record semantics local while the provider sees only schema-4 envelopes
/// and content-addressed ciphertext. The legacy namespace is read-only here.
class EncryptedCloudSyncBackend
    implements
        CloudSyncBackend,
        CloudObjectInventoryBackend,
        CloudSnapshotUploadTransport,
        ConcurrentCloudObjectUploadBackend,
        ReadOnlyCloudSyncBackendValidation {
  EncryptedCloudSyncBackend({
    required this.current,
    required this.legacy,
    required this.cache,
    this.keepSnapshots = 5,
  });

  final CloudSyncBackend current;
  final CloudSyncBackend legacy;
  final EncryptedBackupCache cache;
  int keepSnapshots;
  final _objects = <String, Map<String, dynamic>>{};
  final _uploaded = <String>{};
  final _snapshotObjects = <String, Set<String>>{};
  Set<String>? _readingPages;
  bool _legacyRead = false;
  OperationToken? _token;
  int pendingCleanup = 0;
  List<String> _published = [];

  @override
  int get maxConcurrentObjectUploads =>
      current is ConcurrentCloudObjectUploadBackend
      ? (current as ConcurrentCloudObjectUploadBackend)
            .maxConcurrentObjectUploads
      : 1;

  @override
  Future<CloudBackendCapability> testCapability() => current.testCapability();

  @override
  Future<void> validateConnectionReadOnly() async {
    if (current is ReadOnlyCloudSyncBackendValidation) {
      await (current as ReadOnlyCloudSyncBackendValidation)
          .validateConnectionReadOnly();
    } else {
      await current.readHead();
    }
  }

  @override
  Future<void> prepareSnapshotUpload(
    String snapshotId,
    OperationToken token,
  ) async {
    _token = token;
    _uploaded.clear();
    final head = await current.readHead();
    if (head != null) {
      final logical = SnapshotHead.decode(await _decodeHead(head.bytes));
      await _readEncryptedManifest(logical.snapshotId);
    }
    _legacyRead = false;
  }

  @override
  Future<CloudHeadRead?> readHead() async {
    final head = await current.readHead();
    if (head != null) {
      return CloudHeadRead(
        bytes: await _decodeHead(head.bytes),
        revision: 'v4:${head.revision}',
      );
    }
    final old = await legacy.readHead();
    if (old == null) return null;
    return CloudHeadRead(bytes: old.bytes, revision: 'v3:${old.revision}');
  }

  Future<Uint8List> _decodeHead(Uint8List bytes) async {
    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (envelope['version'] != 4) {
      throw const CloudFormatException('Unsupported encrypted HEAD');
    }
    final clear = await EncryptedBackupCodec.open(
      base64Decode(envelope['data'] as String),
      EncryptedBackupCodec.recoveryKey(envelope['keyVersion'] as int),
      'head',
    );
    final document = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    _published = (document['published'] as List).cast<String>();
    if (_published.length > 100 ||
        _published.toSet().length != _published.length) {
      throw const CloudFormatException('Invalid committed snapshot catalog');
    }
    return Uint8List.fromList(utf8.encode(jsonEncode(document['head'])));
  }

  @override
  Future<CloudObjectRead?> readSnapshotManifest(String snapshotId) async {
    final manifest = await _readEncryptedManifest(snapshotId);
    if (manifest != null) {
      _legacyRead = false;
      return manifest;
    }
    final old = await legacy.readSnapshotManifest(snapshotId);
    if (old != null) _legacyRead = true;
    return old;
  }

  Future<CloudObjectRead?> _readEncryptedManifest(String id) async {
    final remote = await current.readSnapshotManifest(id);
    if (remote == null) return null;
    final envelope =
        jsonDecode(utf8.decode(remote.bytes)) as Map<String, dynamic>;
    if (envelope['version'] != 4 || envelope['snapshotId'] != id) {
      throw const CloudFormatException('Encrypted snapshot identity mismatch');
    }
    final root = envelope['root'] as Map<String, dynamic>;
    final keyObjectId = envelope['keyObjectId'] as String;
    final keyObject =
        jsonDecode(utf8.decode((await _cipherObject(keyObjectId)).bytes))
            as Map<String, dynamic>;
    final key = SecretKey(
      await EncryptedBackupCodec.open(
        base64Decode(keyObject['wrappedKey'] as String),
        EncryptedBackupCodec.recoveryKey(keyObject['keyVersion'] as int),
        'manifest-key/$id/${root['id']}',
      ),
    );
    final pages = <String>{keyObjectId};
    _readingPages = pages;
    final buffer = BytesBuilder(copy: false);
    await for (final bytes in _readTree(root, key)) {
      buffer.add(bytes);
    }
    final document =
        jsonDecode(utf8.decode(buffer.takeBytes())) as Map<String, dynamic>;
    final mapping = document['objects'] as Map<String, dynamic>;
    for (final entry in mapping.entries) {
      _objects[entry.key] = Map<String, dynamic>.from(entry.value as Map);
      pages.addAll((_objects[entry.key]!['parts'] as List).cast<String>());
    }
    _snapshotObjects[id] = pages;
    _readingPages = null;
    final logical = Uint8List.fromList(
      utf8.encode(jsonEncode(document['manifest'])),
    );
    final manifest = SnapshotManifest.fromJson(document['manifest']);
    if (manifest.snapshotId != id) {
      throw const CloudFormatException('Decrypted snapshot identity mismatch');
    }
    return CloudObjectRead(bytes: logical, revision: 'v4:${remote.revision}');
  }

  Stream<Uint8List> _readTree(
    Map<String, dynamic> ref,
    SecretKey key, [
    int depth = 0,
  ]) async* {
    if (depth > 32) {
      throw const CloudFormatException('Invalid manifest page tree');
    }
    await OperationToken.current?.checkpoint();
    _readingPages?.add(ref['id'] as String);
    final remote = await _cipherObject(ref['id'] as String);
    final bytes = await EncryptedBackupCodec.openAndDecompress(
      remote.bytes,
      key,
    );
    if (ref['leaf'] == true) {
      yield bytes;
      return;
    }
    final children = jsonDecode(utf8.decode(bytes)) as List;
    for (final child in children) {
      yield* _readTree(Map<String, dynamic>.from(child as Map), key, depth + 1);
    }
  }

  Future<CloudObjectRead> _cipherObject(String id) async {
    final remote = await current.readObject(id);
    if (remote == null || EncryptedBackupCodec.hash(remote.bytes) != id) {
      throw const CloudFormatException(
        'Encrypted backup volume is missing or incomplete',
      );
    }
    return remote;
  }

  @override
  Future<CloudObjectRead?> readObject(String objectId) async {
    if (_legacyRead) return legacy.readObject(objectId);
    final plan =
        _objects[objectId] ?? await cache.readPlan('objects', objectId);
    if (plan == null) return null;
    _objects[objectId] = plan;
    final key = SecretKey(base64Decode(plan['key'] as String));
    final buffer = BytesBuilder(copy: false);
    for (final id in (plan['parts'] as List).cast<String>()) {
      final remote = await current.readObject(id);
      if (remote == null) return null;
      if (EncryptedBackupCodec.hash(remote.bytes) != id) {
        throw const CloudFormatException('Encrypted object checksum mismatch');
      }
      buffer.add(
        await EncryptedBackupCodec.openAndDecompress(remote.bytes, key),
      );
    }
    final bytes = buffer.takeBytes();
    if (bytes.length != plan['length'] ||
        EncryptedBackupCodec.hash(bytes) != objectId) {
      throw const CloudFormatException('Decrypted object checksum mismatch');
    }
    return CloudObjectRead(
      bytes: bytes,
      revision: (plan['parts'] as List).join(':'),
    );
  }

  @override
  Future<CloudObjectInventoryResult> findExistingObjects(
    Map<String, int> expectedObjects, {
    Map<String, String> trustedRevisions = const {},
    OperationToken? token,
    CloudObjectInventoryProgressCallback? onProgress,
  }) async {
    final revisions = <String, String>{};
    var done = 0;
    var bytesDone = 0;
    final total = expectedObjects.values.fold<int>(0, (a, b) => a + b);
    for (final entry in expectedObjects.entries) {
      await token?.checkpoint();
      final plan = _objects[entry.key];
      if (plan != null && plan['length'] == entry.value) {
        final read = await readObject(entry.key);
        if (read != null) revisions[entry.key] = read.revision;
      }
      done++;
      bytesDone += entry.value;
      onProgress?.call(
        CloudObjectInventoryProgress(
          objectsCompleted: done,
          objectsTotal: expectedObjects.length,
          bytesCompleted: bytesDone,
          bytesTotal: total,
        ),
      );
    }
    return CloudObjectInventoryResult(
      existingObjectIds: revisions.keys.toSet(),
      verifiedRevisions: revisions,
    );
  }

  @override
  Future<CloudCommitResult> putObject(
    String objectId,
    Uint8List bytes, {
    required String sha256,
    bool payloadVerified = false,
  }) async {
    if (EncryptedBackupCodec.hash(bytes) != objectId || sha256 != objectId) {
      throw const CloudFormatException(
        'Object checksum mismatch before encryption',
      );
    }
    var plan = await cache.readPlan('objects', objectId);
    if (plan == null) {
      final key = await EncryptedBackupCodec.newKey();
      final parts = <String>[];
      for (
        var offset = 0;
        offset < bytes.length || (offset == 0 && bytes.isEmpty);
        offset += EncryptedBackupCodec.volumeBytes
      ) {
        final end = (offset + EncryptedBackupCodec.volumeBytes).clamp(
          0,
          bytes.length,
        );
        parts.add(
          await cache.store(
            await EncryptedBackupCodec.compressAndSeal(
              bytes.sublist(offset, end),
              key,
            ),
          ),
        );
      }
      plan = {
        'key': base64Encode(await key.extractBytes()),
        'parts': parts,
        'length': bytes.length,
      };
      await cache.writePlan('objects', objectId, plan);
    }
    _objects[objectId] = plan;
    for (final id in (plan['parts'] as List).cast<String>()) {
      await _uploadCipher(id);
    }
    return CloudCommitResult(revision: (plan['parts'] as List).join(':'));
  }

  Future<void> _uploadCipher(String id) async {
    await _token?.checkpoint();
    if (_uploaded.contains(id)) return;
    final bytes = await cache.read(id);
    await current.putObject(id, bytes, sha256: id);
    _uploaded.add(id);
  }

  @override
  Future<CloudCommitResult> putSnapshotManifest(
    String snapshotId,
    Uint8List bytes, {
    required String sha256,
    bool payloadVerified = false,
  }) async {
    if (EncryptedBackupCodec.hash(bytes) != sha256) {
      throw const CloudFormatException('Manifest checksum mismatch');
    }
    var plan = await cache.readPlan('snapshots', snapshotId);
    if (plan == null) {
      final manifest = SnapshotManifest.fromJson(
        jsonDecode(utf8.decode(bytes)),
      );
      final packed = manifest.packs.values.expand((ids) => ids).toSet();
      final ids = {
        ...manifest.packs.keys,
        for (final record in manifest.records)
          if (!record.deleted && !packed.contains(record.objectId))
            record.objectId!,
      };
      final mapping = <String, dynamic>{};
      for (final id in ids) {
        final entry = _objects[id] ?? await cache.readPlan('objects', id);
        if (entry == null) {
          throw const CloudFormatException(
            'Encrypted object mapping is missing',
          );
        }
        mapping[id] = entry;
      }
      final key = await EncryptedBackupCodec.newKey();
      final pageIds = <String>[];
      final root = await _storeTree(
        utf8.encode(
          jsonEncode({'manifest': manifest.toJson(), 'objects': mapping}),
        ),
        key,
        pageIds,
      );
      final keyObject = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'keyVersion': EncryptedBackupCodec.keyVersion,
            'wrappedKey': base64Encode(
              await EncryptedBackupCodec.seal(
                await key.extractBytes(),
                EncryptedBackupCodec.recoveryKey(
                  EncryptedBackupCodec.keyVersion,
                ),
                'manifest-key/$snapshotId/${root['id']}',
              ),
            ),
          }),
        ),
      );
      final keyObjectId = await cache.store(keyObject);
      pageIds.add(keyObjectId);
      final envelope = {
        'version': 4,
        'snapshotId': snapshotId,
        'keyObjectId': keyObjectId,
        'root': root,
      };
      plan = {'plainHash': sha256, 'envelope': envelope, 'pages': pageIds};
      await cache.writePlan('snapshots', snapshotId, plan);
    }
    if (plan['plainHash'] != sha256) {
      throw const CloudFormatException('Pending encrypted manifest changed');
    }
    for (final id in (plan['pages'] as List).cast<String>()) {
      await _uploadCipher(id);
    }
    final encrypted = Uint8List.fromList(
      utf8.encode(jsonEncode(plan['envelope'])),
    );
    return current.putSnapshotManifest(
      snapshotId,
      encrypted,
      sha256: EncryptedBackupCodec.hash(encrypted),
    );
  }

  Future<Map<String, dynamic>> _storeTree(
    List<int> bytes,
    SecretKey key,
    List<String> pageIds,
  ) async {
    var level = <Map<String, dynamic>>[];
    for (
      var offset = 0;
      offset < bytes.length;
      offset += EncryptedBackupCodec.volumeBytes
    ) {
      final end = (offset + EncryptedBackupCodec.volumeBytes).clamp(
        0,
        bytes.length,
      );
      final id = await cache.store(
        await EncryptedBackupCodec.compressAndSeal(
          bytes.sublist(offset, end),
          key,
        ),
      );
      pageIds.add(id);
      level.add({'id': id, 'leaf': true});
    }
    while (level.length > 1) {
      final next = <Map<String, dynamic>>[];
      for (var offset = 0; offset < level.length; offset += 1024) {
        final end = (offset + 1024).clamp(0, level.length);
        final id = await cache.store(
          await EncryptedBackupCodec.compressAndSeal(
            utf8.encode(jsonEncode(level.sublist(offset, end))),
            key,
          ),
        );
        pageIds.add(id);
        next.add({'id': id, 'leaf': false});
      }
      level = next;
    }
    return level.single;
  }

  @override
  Future<CloudCommitResult> commitHead(
    Uint8List bytes, {
    required String? expectedRevision,
  }) async {
    String? expected;
    if (expectedRevision?.startsWith('v4:') ?? false) {
      expected = expectedRevision!.substring(3);
    } else if (expectedRevision != null) {
      final old = await legacy.readHead();
      if ('v3:${old?.revision}' != expectedRevision) {
        throw const CloudBackendException(
          CloudBackendErrorKind.conflict,
          'Legacy backup changed during upgrade',
        );
      }
    }
    final currentHead = await current.readHead();
    if (currentHead != null) await _decodeHead(currentHead.bytes);
    final logical = SnapshotHead.decode(bytes);
    final published = {logical.snapshotId, ..._published}.take(100).toList();
    final document = utf8.encode(
      jsonEncode({'head': logical.toJson(), 'published': published}),
    );
    final envelope = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 4,
          'keyVersion': EncryptedBackupCodec.keyVersion,
          'data': base64Encode(
            await EncryptedBackupCodec.seal(
              document,
              EncryptedBackupCodec.recoveryKey(EncryptedBackupCodec.keyVersion),
              'head',
            ),
          ),
        }),
      ),
    );
    final result = await current.commitHead(
      envelope,
      expectedRevision: expected,
    );
    _token = null;
    try {
      await retainRecentSnapshots(result.revision);
    } catch (_) {
      pendingCleanup = pendingCleanup > 0 ? pendingCleanup : 1;
    }
    return CloudCommitResult(revision: 'v4:${result.revision}');
  }

  Future<void> retainRecentSnapshots(String expectedRevision) async {
    final currentHead = await current.readHead();
    if (currentHead == null || currentHead.revision != expectedRevision) {
      throw const CloudBackendException(
        CloudBackendErrorKind.conflict,
        'Backup changed before cleanup',
      );
    }
    await _decodeHead(currentHead.bytes);
    final allCurrentIds = await current.listSnapshotIds(limit: 2147483647);
    final currentIds = allCurrentIds.where(_published.contains).toList();
    final oldIds = await legacy.listSnapshotIds(limit: 2147483647);
    final entries =
        <({String id, DateTime time, bool encrypted, Set<String> objects})>[];
    for (final id in currentIds) {
      final read = await _readEncryptedManifest(id);
      if (read == null) {
        throw const CloudFormatException('Snapshot missing during cleanup');
      }
      final manifest = SnapshotManifest.fromJson(
        jsonDecode(utf8.decode(read.bytes)),
      );
      entries.add((
        id: id,
        time: manifest.createdAt,
        encrypted: true,
        objects: _snapshotObjects[id]!,
      ));
    }
    for (final id in oldIds) {
      final read = await legacy.readSnapshotManifest(id);
      if (read == null) {
        throw const CloudFormatException(
          'Legacy snapshot missing during cleanup',
        );
      }
      final manifest = SnapshotManifest.decode(read.bytes);
      final packed = manifest.packs.values.expand((ids) => ids).toSet();
      entries.add((
        id: id,
        time: manifest.createdAt,
        encrypted: false,
        objects: {
          ...manifest.packs.keys,
          for (final ref in manifest.records)
            if (!ref.deleted && !packed.contains(ref.objectId)) ref.objectId!,
        },
      ));
    }
    final head = await current.readHead();
    if (head?.revision != expectedRevision) {
      throw const CloudBackendException(
        CloudBackendErrorKind.conflict,
        'Backup changed during cleanup',
      );
    }
    final liveId = SnapshotHead.decode(
      await _decodeHead(head!.bytes),
    ).snapshotId;
    entries.sort((a, b) {
      if (a.encrypted && a.id == liveId) return -1;
      if (b.encrypted && b.id == liveId) return 1;
      return b.time.compareTo(a.time);
    });
    pendingCleanup = (allCurrentIds.length + oldIds.length - keepSnapshots)
        .clamp(0, allCurrentIds.length + oldIds.length);
    if (pendingCleanup == 0 || current is! AtomicCloudSnapshotPruningBackend) {
      return;
    }
    final retained = entries.take(keepSnapshots).toList();
    final oldHead = await legacy.readHead();
    final oldLiveId = oldHead == null
        ? null
        : SnapshotHead.decode(oldHead.bytes).snapshotId;
    await (current as AtomicCloudSnapshotPruningBackend).pruneSnapshots(
      expectedRevision,
      {
        current: CloudNamespaceRetention(
          snapshotIds: {
            for (final e in retained.where((e) => e.encrypted)) e.id,
          },
          objectIds: {
            for (final e in retained.where((e) => e.encrypted)) ...e.objects,
          },
        ),
        legacy: CloudNamespaceRetention(
          snapshotIds: {
            for (final e in retained.where((e) => !e.encrypted)) e.id,
          },
          objectIds: {
            for (final e in retained.where((e) => !e.encrypted)) ...e.objects,
          },
          deleteHead:
              oldLiveId != null &&
              !retained.any((e) => !e.encrypted && e.id == oldLiveId),
        ),
      },
    );
    pendingCleanup = 0;
  }

  @override
  Future<List<String>> listSnapshotIds({int limit = 20}) async {
    final head = await current.readHead();
    if (head != null) await _decodeHead(head.bytes);
    final currentIds = await current.listSnapshotIds(limit: 2147483647);
    final ids = {
      ...currentIds.where(_published.contains),
      ...await legacy.listSnapshotIds(limit: limit),
    }.toList()..sort((a, b) => b.compareTo(a));
    pendingCleanup = (ids.length - keepSnapshots).clamp(0, ids.length);
    return ids.take(limit).toList();
  }

  @override
  Future<void> deleteNamespace() async {
    await current.deleteNamespace();
    await legacy.deleteNamespace();
  }
}
