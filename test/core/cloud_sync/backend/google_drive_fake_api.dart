import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeDriveApi implements HttpClientAdapter {
  FakeDriveApi({this.forceSingleItemPages = false});

  final bool forceSingleItemPages;
  final Map<String, FakeDriveFile> files = {};
  final List<RequestOptions> requests = [];
  var remainingRateLimits = 0;
  var rateLimitResponses = 0;
  String? rateLimitPath;
  bool loseNextCreateResponse = false;
  var _nextId = 1;

  void addFile({
    required String name,
    required String type,
    required Uint8List bytes,
    String? namespaceHash,
  }) {
    final id = 'file-${_nextId++}';
    files[id] = FakeDriveFile(
      id: id,
      name: name,
      bytes: bytes,
      version: 1,
      appProperties: {
        'protocol': 'aaalice-cloud-sync-v2',
        'namespace':
            namespaceHash ?? sha256.convert(utf8.encode('cloud')).toString(),
        'recordType': type,
      },
      parents: const ['appDataFolder'],
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    expect(options.headers['authorization'], 'Bearer access-token-secret');
    final path = options.uri.path;
    if (remainingRateLimits > 0 &&
        (rateLimitPath == null || rateLimitPath == path)) {
      remainingRateLimits--;
      rateLimitResponses++;
      return _response(
        429,
        '{"error":{"errors":[{"reason":"rateLimitExceeded"}]}}',
        {
          'retry-after': ['0'],
        },
      );
    }

    if (options.method == 'GET' && path == '/drive/v3/files') {
      return _list(options.uri);
    }
    if (options.method == 'GET' &&
        path.startsWith('/drive/v3/files/') &&
        options.uri.queryParameters['alt'] == 'media') {
      final id = Uri.decodeComponent(path.substring('/drive/v3/files/'.length));
      final file = files[id];
      return file == null
          ? _response(404, '')
          : ResponseBody(Stream.value(file.bytes), 200);
    }
    if (options.method == 'POST' && path == '/upload/drive/v3/files') {
      final contentType = options.headers['content-type'] as String;
      final boundary = contentType.substring(
        contentType.indexOf('boundary=') + 9,
      );
      final body = options.data as Uint8List;
      final parsed = _parseMultipart(body, boundary);
      final metadata =
          jsonDecode(utf8.decode(parsed.metadata)) as Map<String, dynamic>;
      final properties = (metadata['appProperties'] as Map)
          .cast<String, String>();
      addFile(
        name: metadata['name'] as String,
        type: properties['recordType']!,
        bytes: parsed.bytes,
        namespaceHash: properties['namespace'],
      );
      final file = files.values.last;
      expect(metadata['parents'], ['appDataFolder']);
      if (loseNextCreateResponse) {
        loseNextCreateResponse = false;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: const SocketException('create response lost'),
        );
      }
      return _response(200, jsonEncode(file.metadata));
    }
    if (options.method == 'PATCH' &&
        path.startsWith('/upload/drive/v3/files/')) {
      final id = Uri.decodeComponent(
        path.substring('/upload/drive/v3/files/'.length),
      );
      final file = files[id];
      if (file == null) return _response(404, '');
      file.bytes = Uint8List.fromList(options.data as List<int>);
      file.version++;
      return _response(200, jsonEncode(file.metadata));
    }
    if (options.method == 'DELETE' && path.startsWith('/drive/v3/files/')) {
      final id = Uri.decodeComponent(path.substring('/drive/v3/files/'.length));
      return files.remove(id) == null ? _response(404, '') : _response(204, '');
    }
    return _response(500, 'unexpected ${options.method} $path');
  }

  ResponseBody _list(Uri uri) {
    final query = uri.queryParameters['q'] ?? '';
    final name = RegExp(r"name = '([^']+)'").firstMatch(query)?.group(1);
    final type = RegExp(
      r"key='recordType' and value='([^']+)'",
    ).firstMatch(query)?.group(1);
    final namespace = RegExp(
      r"key='namespace' and value='([^']+)'",
    ).firstMatch(query)?.group(1);
    final filtered = files.values
        .where((file) => name == null || file.name == name)
        .where(
          (file) =>
              namespace == null || file.appProperties['namespace'] == namespace,
        )
        .where(
          (file) => type == null || file.appProperties['recordType'] == type,
        )
        .toList();
    final offset = int.tryParse(uri.queryParameters['pageToken'] ?? '') ?? 0;
    final requested =
        int.tryParse(uri.queryParameters['pageSize'] ?? '') ?? 100;
    final count = forceSingleItemPages ? 1 : requested;
    final end = (offset + count).clamp(0, filtered.length);
    final page = filtered.sublist(offset.clamp(0, filtered.length), end);
    return _response(
      200,
      jsonEncode({
        'files': page.map((file) => file.metadata).toList(),
        if (end < filtered.length) 'nextPageToken': '$end',
      }),
    );
  }

  @override
  void close({bool force = false}) {}

  static ResponseBody _response(
    int status,
    String body, [
    Map<String, List<String>> headers = const {},
  ]) => ResponseBody.fromString(body, status, headers: headers);
}

class FakeDriveFile {
  FakeDriveFile({
    required this.id,
    required this.name,
    required this.bytes,
    required this.version,
    required this.appProperties,
    required this.parents,
  });

  final String id;
  final String name;
  Uint8List bytes;
  int version;
  final Map<String, String> appProperties;
  final List<String> parents;

  Map<String, Object?> get metadata => {
    'id': id,
    'name': name,
    'size': '${bytes.length}',
    'md5Checksum': md5.convert(bytes).toString(),
    'modifiedTime': '2026-01-01T00:00:00Z',
    'version': '$version',
    'appProperties': appProperties,
  };
}

class _Multipart {
  const _Multipart(this.metadata, this.bytes);

  final Uint8List metadata;
  final Uint8List bytes;
}

_Multipart _parseMultipart(Uint8List body, String boundary) {
  final firstHeaderEnd = _indexOf(body, utf8.encode('\r\n\r\n'));
  final secondBoundary = _indexOf(
    body,
    utf8.encode('\r\n--$boundary\r\n'),
    firstHeaderEnd + 4,
  );
  final secondHeaderEnd = _indexOf(
    body,
    utf8.encode('\r\n\r\n'),
    secondBoundary,
  );
  final closing = _indexOf(
    body,
    utf8.encode('\r\n--$boundary--\r\n'),
    secondHeaderEnd + 4,
  );
  return _Multipart(
    Uint8List.sublistView(body, firstHeaderEnd + 4, secondBoundary),
    Uint8List.sublistView(body, secondHeaderEnd + 4, closing),
  );
}

int _indexOf(Uint8List source, List<int> pattern, [int start = 0]) {
  for (var index = start; index <= source.length - pattern.length; index++) {
    var matches = true;
    for (var offset = 0; offset < pattern.length; offset++) {
      if (source[index + offset] != pattern[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return index;
  }
  throw StateError('multipart marker not found');
}
