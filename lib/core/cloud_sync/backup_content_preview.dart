import 'dart:typed_data';
import 'data_source.dart';

class BackupContentItem {
  const BackupContentItem({
    required this.group,
    required this.title,
    this.text = '',
    this.bytes,
    this.readImage,
  });
  final String group;
  final String title;
  final String text;
  final int? bytes;
  final Future<Uint8List> Function()? readImage;
}

abstract interface class CloudBackupContentPreviewSource {
  Future<List<BackupContentItem>> previewContents(
    CloudSyncSnapshotData snapshot,
  );
}
