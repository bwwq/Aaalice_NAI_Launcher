import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/backend/cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/backend/s3_backend_config.dart';
import 'package:nai_launcher/core/cloud_sync/backend/s3_cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/backend/s3_signature.dart';

import 'backend_test_support.dart';

void main() {
  test('SigV4 matches independent fixture with Unicode and encoded query', () {
    final headers = S3Signature.headers(
      method: 'GET',
      uri: Uri.parse(
        'https://s3.example.test/bucket/a%20b/%E5%9B%BE.png?list-type=2&continuation-token=a%2Bb%3D',
      ),
      accessKey: 'example-access',
      secretKey: 'example-secret',
      region: 'us-east-1',
      payloadHash: sha256.convert([]).toString(),
      now: DateTime.utc(2026, 9, 20),
    );
    expect(
      headers['Authorization'],
      endsWith(
        'Signature=f746d017faf1404def33cde5e49b97be5debcbaccaae0e8901fe08f78e5949c9',
      ),
    );
    expect(headers['x-amz-date'], '20260920T000000Z');
  });

  test('path and virtual-host addressing preserve endpoint prefix', () {
    for (final pathStyle in [true, false]) {
      final config = S3BackendConfig(
        endpoint: Uri.parse('https://s3.test:9443/api/'),
        bucket: 'my-bucket',
        pathStyle: pathStyle,
      );
      final uri = config.uri(key: 'backup/图 +%.bin');
      expect(uri.host, pathStyle ? 's3.test' : 'my-bucket.s3.test');
      expect(uri.port, 9443);
      expect(uri.pathSegments, [
        'api',
        if (pathStyle) 'my-bucket',
        'backup',
        '图 +%.bin',
      ]);
    }
  });

  test(
    'manual upload verifies data, reuses objects and detects changed HEAD',
    () async {
      final objects = <String, List<int>>{};
      final api = RecordingAdapter((request) {
        expect(
          request.headers['Authorization'],
          startsWith('AWS4-HMAC-SHA256 '),
        );
        final path = request.uri.path;
        if (request.uri.queryParameters['list-type'] == '2') {
          return const TestHttpResponse(
            200,
            '<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>',
          );
        }
        if (request.method == 'GET') {
          return objects.containsKey(path)
              ? TestHttpResponse(200, objects[path]!)
              : const TestHttpResponse(404);
        }
        if (request.method == 'PUT') {
          objects[path] = List<int>.from(request.data as List<int>);
          return const TestHttpResponse(200);
        }
        throw StateError(request.method);
      });
      final backend = _backend(api);
      final capability = await backend.testCapability();
      expect(capability.mode, CloudBackendMode.manualBackupOnly);
      expect(capability.supportsDelete, isFalse);
      expect(api.requests.every((r) => r.method == 'GET'), isTrue);
      final bytes = Uint8List.fromList(utf8.encode('original data'));
      final digest = sha256.convert(bytes).toString();
      await backend.putObject(digest, bytes, sha256: digest);
      await backend.putObject(digest, bytes, sha256: digest);
      expect(api.requests.where((r) => r.method == 'PUT'), hasLength(1));
      expect((await backend.readObject(digest))!.bytes, bytes);
      await backend.putSnapshotManifest('snapshot', bytes, sha256: digest);
      await expectLater(
        backend.putSnapshotManifest(
          'snapshot',
          Uint8List(0),
          sha256: sha256.convert([]).toString(),
        ),
        throwsA(isA<CloudBackendException>()),
      );
      final head = await backend.commitHead(bytes, expectedRevision: null);
      expect((await backend.readHead())!.revision, head.revision);
      await expectLater(
        backend.commitHead(Uint8List.fromList([2]), expectedRevision: null),
        throwsA(isA<CloudBackendException>()),
      );
    },
  );

  test('ListObjectsV2 follows opaque pagination and sorts newest first', () async {
    final api = RecordingAdapter((r) {
      expect(r.uri.queryParameters['prefix'], 'aaalice-sync/snapshots/');
      if (!r.uri.queryParameters.containsKey('continuation-token')) {
        return const TestHttpResponse(
          200,
          '<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated><NextContinuationToken>a+b=</NextContinuationToken><Contents><Key>aaalice-sync%2Fsnapshots%2F001.json</Key></Contents></ListBucketResult>',
        );
      }
      expect(r.uri.queryParameters['continuation-token'], 'a+b=');
      return const TestHttpResponse(
        200,
        '<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>aaalice-sync/snapshots/003.json</Key></Contents><Contents><Key>aaalice-sync/snapshots/002.json</Key></Contents></ListBucketResult>',
      );
    });
    expect(await _backend(api).listSnapshotIds(limit: 2), ['003', '002']);
    expect(api.requests, hasLength(2));
  });

  test('failed writes are reported and do not submit HEAD', () async {
    final api = RecordingAdapter(
      (r) => TestHttpResponse(r.method == 'GET' ? 404 : 403),
    );
    final bytes = Uint8List.fromList([1]);
    final digest = sha256.convert(bytes).toString();
    await expectLater(
      _backend(api).putObject(digest, bytes, sha256: digest),
      throwsA(
        isA<CloudBackendException>().having(
          (e) => e.kind,
          'kind',
          CloudBackendErrorKind.authorization,
        ),
      ),
    );
    expect(api.requests.any((r) => r.uri.path.endsWith('HEAD.json')), isFalse);
  });
}

S3CloudSyncBackend _backend(RecordingAdapter api) => S3CloudSyncBackend(
  config: S3BackendConfig(
    endpoint: Uri.parse('https://s3.test'),
    bucket: 'my-bucket',
  ),
  accessKey: 'test-access',
  secretKey: 'test-secret',
  dio: Dio()..httpClientAdapter = api,
);
