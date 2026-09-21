import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'backend_test_support.dart';

class FakeS3Api {
  final files = <String, Uint8List>{};
  final versions = <String, int>{};
  bool supportsHead = true;
  bool providesVersion = true;
  bool providesEtag = true;

  TestHttpResponse handle(RequestOptions request) {
    final path = request.uri.path;
    if (request.uri.queryParameters['list-type'] == '2') {
      final prefix = request.uri.queryParameters['prefix']!;
      final keys = files.keys
          .map((p) => p.substring('/bucket/'.length))
          .where((key) => key.startsWith(prefix));
      return TestHttpResponse(
        200,
        '<ListBucketResult><IsTruncated>false</IsTruncated>'
        '${keys.map((key) => '<Contents><Key>$key</Key></Contents>').join()}'
        '</ListBucketResult>',
      );
    }
    if (request.method == 'PUT') {
      files[path] = Uint8List.fromList(request.data as List<int>);
      versions[path] = (versions[path] ?? 0) + 1;
      return const TestHttpResponse(200);
    }
    if (request.method == 'HEAD' && !supportsHead) {
      return const TestHttpResponse(405);
    }
    final bytes = files[path];
    if (bytes == null) return const TestHttpResponse(404);
    return TestHttpResponse(200, request.method == 'HEAD' ? '' : bytes, {
      'content-length': ['${bytes.length}'],
      if (providesVersion) 'x-amz-version-id': ['v${versions[path]}'],
      if (providesEtag) 'etag': ['"e${versions[path]}"'],
    });
  }
}
