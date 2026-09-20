import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'models.dart';

/// Application-recoverable encryption, not a user-exclusive secret. Keep old
/// key versions available so reinstalling the app can restore older backups.
class EncryptedBackupCodec {
  static const version = 4;
  static const keyVersion = 1;
  static const volumeBytes = 3 * 1024 * 1024;
  static final _cipher = AesGcm.with256bits();
  static final _recoveryKeys = <int, SecretKey>{
    1: SecretKey(base64Decode('hGZR2iDKd38Mcl92KZLTbpFwOuxZ2kVhpL9kqxNvR5s=')),
  };

  static String hash(List<int> bytes) =>
      hashes.sha256.convert(bytes).toString();
  static Future<SecretKey> newKey() => _cipher.newSecretKey();

  static SecretKey recoveryKey(int version) {
    final key = _recoveryKeys[version];
    if (key == null) {
      throw const CloudFormatException(
        'Update the app to read this backup key',
      );
    }
    return key;
  }

  static Future<Uint8List> seal(
    List<int> bytes,
    SecretKey key,
    String purpose,
  ) async {
    final box = await _cipher.encrypt(
      bytes,
      secretKey: key,
      nonce: _cipher.newNonce(),
      aad: utf8.encode('aaalice-backup-v4/$purpose'),
    );
    return Uint8List.fromList([
      ...box.nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
  }

  static Future<Uint8List> open(
    List<int> bytes,
    SecretKey key,
    String purpose,
  ) async {
    if (bytes.length < 28 || bytes.length > maxCloudObjectBytes) {
      throw const CloudFormatException('Invalid encrypted volume length');
    }
    try {
      return Uint8List.fromList(
        await _cipher.decrypt(
          SecretBox(
            bytes.sublist(28),
            nonce: bytes.sublist(0, 12),
            mac: Mac(bytes.sublist(12, 28)),
          ),
          secretKey: key,
          aad: utf8.encode('aaalice-backup-v4/$purpose'),
        ),
      );
    } on SecretBoxAuthenticationError {
      throw const CloudFormatException(
        'Encrypted backup could not be verified',
      );
    }
  }

  static Future<Uint8List> compressAndSeal(
    List<int> bytes,
    SecretKey key,
  ) async {
    if (bytes.length > volumeBytes) {
      throw const CloudFormatException('Backup volume is too large');
    }
    final archive = Archive()
      ..addFile(ArchiveFile('payload', bytes.length, bytes));
    final compressed = ZipEncoder().encode(archive)!;
    final result = await seal(compressed, key, 'volume');
    if (result.length > maxCloudObjectBytes) {
      throw const CloudFormatException('Encrypted volume is too large');
    }
    return result;
  }

  static Future<Uint8List> openAndDecompress(
    List<int> bytes,
    SecretKey key,
  ) async {
    final zip = await open(bytes, key, 'volume');
    final archive = ZipDecoder().decodeBytes(zip, verify: true);
    if (archive.files.length != 1 ||
        archive.first.name != 'payload' ||
        !archive.first.isFile ||
        archive.first.size > volumeBytes) {
      throw const CloudFormatException('Invalid backup volume archive');
    }
    final result = Uint8List.fromList(archive.first.content as List<int>);
    if (result.length != archive.first.size) {
      throw const CloudFormatException('Backup volume length mismatch');
    }
    return result;
  }
}
