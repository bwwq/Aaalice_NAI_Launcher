import '../bounded_transfer_scheduler.dart';
import '../operation.dart';
import 'cloud_sync_backend.dart';

class CloudObjectInventoryCandidate {
  const CloudObjectInventoryCandidate({
    required this.objectId,
    required this.size,
    required this.revision,
    required this.verificationRevision,
  });

  final String objectId;
  final int size;
  final String revision;
  final String? verificationRevision;
}

Future<CloudObjectInventoryResult> verifyCloudObjectInventory({
  required Iterable<CloudObjectInventoryCandidate> candidates,
  required Map<String, String> trustedRevisions,
  required int maxConcurrentItems,
  required Future<void> Function(CloudObjectInventoryCandidate candidate)
  verify,
  OperationToken? token,
  CloudObjectInventoryProgressCallback? onProgress,
}) async {
  final cancellation = token ?? OperationToken.current ?? OperationToken();
  if (!identical(OperationToken.current, cancellation)) {
    return cancellation.runInScope(
      () => verifyCloudObjectInventory(
        candidates: candidates,
        trustedRevisions: trustedRevisions,
        maxConcurrentItems: maxConcurrentItems,
        verify: verify,
        token: cancellation,
        onProgress: onProgress,
      ),
    );
  }

  final items = candidates.toList(growable: false);
  if (items.isEmpty) return CloudObjectInventoryResult.empty();
  final totalBytes = items.fold<int>(0, (sum, item) => sum + item.size);
  var completedObjects = 0;
  var completedBytes = 0;
  final verifiedRevisions = <String, String>{};
  final existingObjectIds = <String>{};

  void reportProgress() {
    onProgress?.call(
      CloudObjectInventoryProgress(
        objectsCompleted: completedObjects,
        objectsTotal: items.length,
        bytesCompleted: completedBytes,
        bytesTotal: totalBytes,
      ),
    );
  }

  reportProgress();
  final limits = cloudTransferPlatformLimits;
  final scheduler = BoundedTransferScheduler(
    maxConcurrentItems: maxConcurrentItems.clamp(1, limits.maxConcurrentItems),
    maxBytesInFlight: limits.maxBytesInFlight,
  );
  await scheduler.run<CloudObjectInventoryCandidate, void>(
    items: [
      for (final item in items)
        BoundedTransferItem(value: item, bytes: item.size),
    ],
    token: cancellation,
    transfer: (candidate) async {
      await cancellation.checkpoint();
      if (candidate.verificationRevision == null ||
          trustedRevisions[candidate.objectId] !=
              candidate.verificationRevision) {
        await verify(candidate);
      }
      await cancellation.checkpoint();
      existingObjectIds.add(candidate.objectId);
      final proof = candidate.verificationRevision;
      if (proof != null) verifiedRevisions[candidate.objectId] = proof;
      completedObjects++;
      completedBytes += candidate.size;
      reportProgress();
    },
  );
  return CloudObjectInventoryResult(
    existingObjectIds: existingObjectIds,
    verifiedRevisions: verifiedRevisions,
  );
}
