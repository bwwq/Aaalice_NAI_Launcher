import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:nai_launcher/core/cloud_sync/backend/cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/backend/github_cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/backend/google_drive_cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/backend/onedrive_cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/backend/s3_backend_config.dart';
import 'package:nai_launcher/core/cloud_sync/backend/s3_cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/backend/webdav_cloud_sync_backend.dart';
import 'backend_test_support.dart';
import 'github_fake_api.dart';
import 'google_drive_fake_api.dart';
import 'onedrive_fake_api.dart';
import 's3_fake_api.dart';
import 'webdav_fake_api.dart';

const incrementalProviders = [
  'github',
  'onedrive',
  'google-drive',
  's3',
  'webdav',
];

class IncrementalBackendFixture {
  IncrementalBackendFixture(this.provider) {
    late HttpClientAdapter delegate;
    String? Function(RequestOptions) identify = (r) =>
        r.uri.pathSegments.lastOrNull;
    switch (provider) {
      case 'github':
        final api = FakeGitHubApi();
        delegate = api;
        identify = (r) {
          if (!r.uri.path.contains('/git/blobs')) return null;
          if (r.method == 'POST') {
            final body = jsonDecode(r.data as String) as Map;
            return sha256
                .convert(base64Decode(body['content'] as String))
                .toString();
          }
          final bytes = api.blobs[r.uri.pathSegments.last];
          return bytes == null ? null : sha256.convert(bytes).toString();
        };
        create = (ns) => GitHubCloudSyncBackend(
          owner: 'owner',
          repository: 'repo',
          branch: 'sync',
          token: 'fixture',
          namespace: ns,
          apiBaseUri: Uri.parse('https://api.github.test/'),
          dio: dio(),
        );
      case 'onedrive':
        final api = FakeOneDriveApi();
        delegate = api;
        identify = (r) {
          final path = r.uri.host == 'signed.onedrive.test'
              ? r.method == 'PUT'
                    ? api.sessions[r.uri.pathSegments.last]?.path
                    : r.uri.queryParameters['path']
              : null;
          return path?.split('/').last;
        };
        create = (ns) => OneDriveCloudSyncBackend(
          accessTokenProvider: () async => 'fixture',
          namespace: ns,
          graphBaseUri: Uri.parse('https://graph.microsoft.test/v1.0/'),
          dio: dio(),
        );
      case 'google-drive':
        final api = FakeDriveApi();
        delegate = api;
        identify = (r) {
          if (r.method == 'GET' && r.uri.queryParameters['alt'] == 'media') {
            return api.files[r.uri.pathSegments.last]?.name.replaceFirst(
              'aaalice-cloud-sync-object-',
              '',
            );
          }
          if (r.method == 'POST' && r.data is Uint8List) {
            final bytes = r.data as Uint8List;
            final body = utf8.decode(
              Uint8List.sublistView(bytes, 0, bytes.length.clamp(0, 2048)),
              allowMalformed: true,
            );
            return RegExp(
              r'aaalice-cloud-sync-object-([a-f0-9]{64})',
            ).firstMatch(body)?.group(1);
          }
          return null;
        };
        create = (ns) => GoogleDriveCloudSyncBackend(
          accessTokenProvider: () async => 'access-token-secret',
          namespace: ns,
          apiBaseUri: Uri.parse('https://google.test/'),
          dio: dio(),
        );
      case 's3':
        s3 = FakeS3Api();
        delegate = RecordingAdapter(s3!.handle);
        create = (ns) => S3CloudSyncBackend(
          config: S3BackendConfig(
            endpoint: Uri.parse('https://s3.test/'),
            bucket: 'bucket',
            namespace: ns,
          ),
          accessKey: 'fixture',
          secretKey: 'fixture',
          dio: dio(),
        );
      case 'webdav':
        final api = StatefulWebDavApi();
        webdav = api;
        delegate = RecordingAdapter(api.handle);
        create = (ns) => WebDavCloudSyncBackend(
          baseUri: Uri.parse('https://dav.example/sync/'),
          username: 'alice',
          password: 'fixture',
          namespace: ns,
          dio: dio(),
        );
      default:
        throw ArgumentError(provider);
    }
    adapter = _MeasuredAdapter(delegate, identify, samples);
  }

  final String provider;
  FakeS3Api? s3;
  StatefulWebDavApi? webdav;
  late final HttpClientAdapter adapter;
  late final CloudSyncBackend Function(String) create;
  final samples = <TransferSample>[];
  final contentIds = <String>{};
  Dio dio() => Dio()..httpClientAdapter = adapter;

  Map<String, int> metrics(int start) {
    final result = <String, int>{
      'requests': samples.length - start,
      'contentRequests': 0,
      'indexRequests': 0,
      'contentReadBytes': 0,
      'contentWrittenBytes': 0,
      'indexReadBytes': 0,
      'indexWrittenBytes': 0,
    };
    for (final sample in samples.skip(start)) {
      final content =
          contentIds.contains(sample.objectId) &&
          sample.method != 'HEAD' &&
          sample.method != 'PROPFIND';
      final category = content ? 'content' : 'index';
      result['${category}Requests'] = result['${category}Requests']! + 1;
      result['${category}ReadBytes'] =
          result['${category}ReadBytes']! + sample.read;
      result['${category}WrittenBytes'] =
          result['${category}WrittenBytes']! + sample.written;
    }
    return result;
  }
}

class TransferSample {
  TransferSample(this.method, this.objectId);
  final String method;
  final String? objectId;
  int read = 0;
  int written = 0;
}

class _MeasuredAdapter implements HttpClientAdapter {
  _MeasuredAdapter(this.delegate, this.identify, this.samples);
  final HttpClientAdapter delegate;
  final String? Function(RequestOptions) identify;
  final List<TransferSample> samples;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    final sample = TransferSample(options.method, identify(options));
    final data = options.data;
    final declared = data is String
        ? utf8.encode(data).length
        : data is List<int>
        ? data.length
        : 0;
    sample.written = declared;
    samples.add(sample);
    var streamed = 0;
    final response = await delegate.fetch(
      options,
      stream?.map((bytes) {
        streamed += bytes.length;
        if (streamed > sample.written) sample.written = streamed;
        return bytes;
      }),
      cancel,
    );
    response.stream = response.stream.map((bytes) {
      sample.read += bytes.length;
      return bytes;
    });
    return response;
  }

  @override
  void close({bool force = false}) {}
}
