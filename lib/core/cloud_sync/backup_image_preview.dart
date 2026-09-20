import 'data_source.dart';

class BackupImagePreview {
  const BackupImagePreview({
    this.count = 0,
    this.originalBytes = 0,
    this.estimatedUploadBytes = 0,
    this.added = 0,
    this.reused = 0,
    this.nameConflicts = 0,
  });
  final int count;
  final int originalBytes;
  final int estimatedUploadBytes;
  final int added;
  final int reused;
  final int nameConflicts;
}

abstract interface class CloudBackupImagePreviewSource {
  Future<BackupImagePreview> previewImages(
    CloudSyncSnapshotData snapshot, {
    CloudSyncSnapshotData? remote,
  });
}
