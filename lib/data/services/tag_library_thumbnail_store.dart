import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Commits a private thumbnail copy before retiring the previous image.
class TagLibraryThumbnailStore {
  const TagLibraryThumbnailStore(this.directory);

  final Directory directory;

  Future<void> commit({
    required String? selectedPath,
    required String? previousPath,
    required Future<void> Function(String? path) persist,
    bool Function(String path)? isReferenced,
  }) async {
    String? savedPath;
    var copied = false;
    try {
      if (selectedPath != null) {
        final source = File(selectedPath);
        if (!await source.exists()) {
          throw FileSystemException('Thumbnail no longer exists', selectedPath);
        }
        if (_owns(selectedPath)) {
          savedPath = selectedPath;
        } else {
          await directory.create(recursive: true);
          savedPath = p.join(
            directory.path,
            '${const Uuid().v4()}${p.extension(selectedPath)}',
          );
          copied = true;
          await source.copy(savedPath);
        }
      }
      await persist(savedPath);
    } catch (_) {
      if (copied && savedPath != null) await _remove(savedPath);
      rethrow;
    }
    if (previousPath != null &&
        previousPath != savedPath &&
        !(isReferenced?.call(previousPath) ?? false)) {
      await _remove(previousPath);
    }
  }

  bool _owns(String path) => p.isWithin(
    p.normalize(p.absolute(directory.path)),
    p.normalize(p.absolute(path)),
  );

  Future<void> _remove(String path) async {
    if (!_owns(path)) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Cleanup cannot turn a successful persistence into a failed save.
    }
  }
}
