import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'encrypted_backup_codec.dart';
import 'models.dart';

/// Durable ciphertext and immutable plans. A restart must reuse nonce/key/data.
class EncryptedBackupCache {
  EncryptedBackupCache(Directory root) : _root = (() async => root);
  EncryptedBackupCache.lazy(this._root);
  final Future<Directory> Function() _root;

  Future<File> _file(String group, String id) async {
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id)) {
      throw const CloudFormatException('Invalid encrypted cache identity');
    }
    return File(p.join((await _root()).path, group, id));
  }

  Future<Map<String, dynamic>?> readPlan(String group, String id) async {
    final file = await _file(group, id);
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<void> writePlan(
    String group,
    String id,
    Map<String, dynamic> plan,
  ) async => _write(await _file(group, id), utf8.encode(jsonEncode(plan)));

  Future<String> store(Uint8List bytes) async {
    final id = EncryptedBackupCodec.hash(bytes);
    final file = await _file('ciphertext', id);
    if (!await file.exists()) await _write(file, bytes);
    return id;
  }

  Future<Uint8List> read(String id) async {
    final bytes = await (await _file('ciphertext', id)).readAsBytes();
    if (EncryptedBackupCodec.hash(bytes) != id) {
      throw const CloudFormatException('Cached ciphertext checksum mismatch');
    }
    return bytes;
  }

  Future<void> _write(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
