import 'backend/cloud_sync_backend.dart';
import 'models.dart';
import 'operation.dart';

/// Checks ciphertext versions without materializing unchanged logical payloads.
Future<CloudObjectInventoryResult> verifyEncryptedObjects({
  required CloudSyncBackend backend,
  required Map<String, int> expectedObjects,
  required Map<String, Map<String, dynamic>> plans,
  required Future<CloudObjectRead?> Function(String) readLogicalObject,
  required void Function(String, Map<String, dynamic>) verifiedPart,
  OperationToken? token,
  CloudObjectInventoryProgressCallback? onProgress,
}) async {
  final sizes = <String, int>{};
  final trusted = <String, String>{};
  final indexed = <String>{};
  for (final entry in expectedObjects.entries) {
    await token?.checkpoint();
    final plan = plans[entry.key];
    if (plan == null || plan['length'] != entry.value) continue;
    final parts = (plan['parts'] as List).cast<String>();
    final metadata = plan['partMetadata'];
    if (metadata is! Map || !parts.every(metadata.containsKey)) continue;
    for (final id in parts) {
      final part = metadata[id];
      if (part is! Map ||
          part['size'] is! int ||
          (part['size'] as int) <= 0 ||
          (part['size'] as int) > maxCloudObjectBytes) {
        throw const CloudFormatException('Invalid encrypted part metadata');
      }
      final size = part['size'] as int;
      if (sizes.containsKey(id) && sizes[id] != size) {
        throw const CloudFormatException('Conflicting encrypted part sizes');
      }
      sizes[id] = size;
      final proof = part['verificationRevision'];
      if (proof is String && proof.isNotEmpty) trusted[id] = proof;
    }
    indexed.add(entry.key);
  }
  final inventory = backend is CloudObjectInventoryBackend && sizes.isNotEmpty
      ? await (backend as CloudObjectInventoryBackend).findExistingObjects(
          sizes,
          trustedRevisions: trusted,
          token: token,
        )
      : null;
  final existing = <String>{};
  var done = 0;
  var bytesDone = 0;
  final total = expectedObjects.values.fold(0, (int sum, size) => sum + size);
  for (final entry in expectedObjects.entries) {
    await token?.checkpoint();
    final plan = plans[entry.key];
    if (plan != null && plan['length'] == entry.value) {
      final parts = (plan['parts'] as List).cast<String>();
      if (inventory != null && indexed.contains(entry.key)) {
        for (final id in parts.where(inventory.existingObjectIds.contains)) {
          final metadata = <String, dynamic>{
            'size': sizes[id]!,
            if (inventory.verifiedRevisions[id] case final String proof)
              'verificationRevision': proof,
          };
          (plan['partMetadata'] as Map)[id] = metadata;
          verifiedPart(id, metadata);
        }
        if (parts.every(inventory.existingObjectIds.contains)) {
          existing.add(entry.key);
        }
      } else if (await readLogicalObject(entry.key) != null) {
        // Old indexes acquire portable proofs during their one full read.
        existing.add(entry.key);
      }
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
    existingObjectIds: existing,
    verifiedRevisions: const {},
  );
}
