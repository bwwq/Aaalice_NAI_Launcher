import 'dart:convert';

import 'package:crypto/crypto.dart';

/// AWS Signature Version 4 for S3 (single, bounded request payloads).
class S3Signature {
  static String encode(String value) => utf8.encode(value).map((byte) {
    if ((byte >= 65 && byte <= 90) ||
        (byte >= 97 && byte <= 122) ||
        (byte >= 48 && byte <= 57) ||
        [45, 46, 95, 126].contains(byte)) {
      return String.fromCharCode(byte);
    }
    return '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}';
  }).join();

  static Map<String, String> headers({
    required String method,
    required Uri uri,
    required String accessKey,
    required String secretKey,
    required String region,
    required String payloadHash,
    required DateTime now,
  }) {
    final stamp =
        now
            .toUtc()
            .toIso8601String()
            .replaceAll('-', '')
            .replaceAll(':', '')
            .split('.')
            .first +
        'Z';
    final day = stamp.substring(0, 8);
    final scope = '$day/$region/s3/aws4_request';
    final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    final values = <String, String>{
      'host': host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': stamp,
    };
    final query = <String>[];
    for (final entry in uri.queryParametersAll.entries) {
      for (final value in entry.value) {
        query.add('${encode(entry.key)}=${encode(value)}');
      }
    }
    query.sort();
    final path = '/${uri.pathSegments.map(encode).join('/')}';
    final names = values.keys.join(';');
    final canonicalHeaders = values.entries
        .map((e) => '${e.key}:${e.value}\n')
        .join();
    final canonical =
        '$method\n$path\n${query.join('&')}\n$canonicalHeaders\n$names\n$payloadHash';
    final toSign =
        'AWS4-HMAC-SHA256\n$stamp\n$scope\n${sha256.convert(utf8.encode(canonical))}';
    List<int> mac(List<int> key, String text) =>
        Hmac(sha256, key).convert(utf8.encode(text)).bytes;
    final key = mac(
      mac(mac(mac(utf8.encode('AWS4$secretKey'), day), region), 's3'),
      'aws4_request',
    );
    final signature = Hmac(sha256, key).convert(utf8.encode(toSign));
    return {
      ...values,
      'Authorization':
          'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, SignedHeaders=$names, Signature=$signature',
    };
  }
}
