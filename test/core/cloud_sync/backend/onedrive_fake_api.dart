import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';

class StoredOneDriveFile {
  StoredOneDriveFile(this.bytes, this.eTag);

  Uint8List bytes;
  String eTag;
}

class OneDriveUploadSession {
  const OneDriveUploadSession(this.path);

  final String path;
}

class _FakeResponse {
  const _FakeResponse(
    this.status, [
    this.body = const [],
    this.headers = const {},
  ]);

  factory _FakeResponse.json(
    int status,
    Object body, [
    Map<String, List<String>> headers = const {},
  ]) => _FakeResponse(status, utf8.encode(jsonEncode(body)), headers);

  final int status;
  final List<int> body;
  final Map<String, List<String>> headers;
}

class RateLimitedDownloadOneDriveApi extends FakeOneDriveApi {
  final downloadStarted = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (request.method == 'GET' && request.uri.path.endsWith(':/content')) {
      if (!downloadStarted.isCompleted) downloadStarted.complete();
      return ResponseBody.fromBytes(
        const [],
        429,
        headers: {
          'retry-after': ['10'],
        },
      );
    }
    return super.fetch(request, requestStream, cancelFuture);
  }
}

class FakeOneDriveApi implements HttpClientAdapter {
  int? appRootFailuresRemaining;
  final Map<String, StoredOneDriveFile> files = {};
  final Set<String> folders = {};
  final Map<String, OneDriveUploadSession> sessions = {};
  final List<RequestOptions> requests = [];
  final List<Map<String, Object>> additionalChildren = [];
  int metadataRateLimitsRemaining = 0;
  int metadataRateLimitResponses = 0;
  bool observedStalePrecondition = false;
  bool observedCreateConflict = false;
  bool appRootRequested = false;
  int appRootRequests = 0;
  int? appRootFailureStatus;
  String appRootFailureCode = 'serviceNotAvailable';
  String? appRootInnerFailureCode;
  String? appRootFailureMessage;
  int _revision = 0;
  int _session = 0;

  void putFile(String path, List<int> bytes) {
    _ensureFolders(path);
    files[path] = StoredOneDriveFile(Uint8List.fromList(bytes), _nextETag());
  }

  List<int>? fileBytes(String path) => files[path]?.bytes;

  void removeNamespace(String path) {
    files.removeWhere(
      (filePath, _) => filePath == path || filePath.startsWith('$path/'),
    );
    folders.removeWhere(
      (folderPath) => folderPath == path || folderPath.startsWith('$path/'),
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(request);
    final response = await _handle(request, requestStream);
    return ResponseBody.fromBytes(
      response.body,
      response.status,
      headers: response.headers,
    );
  }

  Future<_FakeResponse> _handle(
    RequestOptions request,
    Stream<Uint8List>? requestStream,
  ) async {
    if (request.uri.host == 'signed.onedrive.test') {
      if (request.headers.keys.any(
        (key) => key.toLowerCase() == 'authorization',
      )) {
        return _FakeResponse.json(400, {'error': 'token leaked'});
      }
      if (request.method == 'PUT') {
        final session = sessions.remove(request.uri.path.split('/').last);
        if (session == null) return _FakeResponse.json(404, {});
        final bytes = await _requestBytes(request, requestStream);
        final stored = StoredOneDriveFile(bytes, _nextETag());
        files[session.path] = stored;
        return _FakeResponse.json(201, _item(session.path, stored));
      }
      if (request.method == 'GET' && request.uri.path == '/download') {
        final stored = files[request.uri.queryParameters['path']];
        return stored == null
            ? _FakeResponse.json(404, {})
            : _FakeResponse(200, stored.bytes);
      }
    }

    if (request.uri.path == '/v1.0/me/drive/special/approot') {
      if (request.method == 'GET') {
        appRootRequests++;
        final failureStatus = appRootFailureStatus;
        if (failureStatus != null &&
            (appRootFailuresRemaining == null ||
                appRootFailuresRemaining! > 0)) {
          if (appRootFailuresRemaining != null) {
            appRootFailuresRemaining = appRootFailuresRemaining! - 1;
          }
          return _FakeResponse.json(failureStatus, {
            'error': {
              'code': appRootFailureCode,
              if (appRootFailureMessage case final message?) 'message': message,
              if (appRootInnerFailureCode case final innerCode?)
                'innerError': {'code': innerCode},
            },
          });
        }
        appRootRequested = true;
        return _FakeResponse.json(200, {
          'id': 'approot-id',
          'name': 'Aaalice NAI Launcher',
          'eTag': '"approot"',
          'size': 0,
          'folder': <String, Object?>{},
          'specialFolder': {'name': 'approot'},
        });
      }
    }

    final graphPath = _graphItemPath(request.uri.path);
    if (request.method == 'POST' && request.uri.path.endsWith('/children')) {
      if (!appRootRequested) {
        return _FakeResponse.json(404, {
          'error': {'code': 'itemNotFound'},
        });
      }
      final body = jsonDecode(request.data as String) as Map<String, dynamic>;
      final name = body['name'] as String;
      final parent = graphPath ?? _folderPathForChildrenRequest(request.uri);
      if (parent == null) {
        return _FakeResponse.json(400, {
          'error': {'code': 'invalidRequest'},
        });
      }
      final path = parent.isEmpty ? name : '$parent/$name';
      if (folders.contains(path) || files.containsKey(path)) {
        return _FakeResponse.json(409, {
          'error': {'code': 'nameAlreadyExists'},
        });
      }
      folders.add(path);
      return _FakeResponse.json(201, {
        'id': _folderId(path),
        'name': name,
        'eTag': '"folder-$path"',
        'size': 0,
        'folder': <String, Object?>{},
      });
    }
    if (request.method == 'POST' &&
        request.uri.path.endsWith(':/createUploadSession')) {
      final path = graphPath!;
      final separator = path.lastIndexOf('/');
      final parent = separator <= 0 ? '' : path.substring(0, separator);
      if (parent.isNotEmpty && !folders.contains(parent)) {
        return _FakeResponse.json(404, {
          'error': {'code': 'itemNotFound'},
        });
      }
      final current = files[path];
      final expected = request.headers['If-Match']?.toString();
      if (expected != null && current?.eTag != expected) {
        observedStalePrecondition = true;
        return _FakeResponse.json(412, {
          'error': {'code': 'preconditionFailed'},
        });
      }
      final body = jsonDecode(request.data as String) as Map<String, dynamic>;
      final behavior =
          (body['item'] as Map)['@microsoft.graph.conflictBehavior'];
      if (expected == null && behavior == 'fail' && current != null) {
        observedCreateConflict = true;
        return _FakeResponse.json(409, {
          'error': {'code': 'nameAlreadyExists'},
        });
      }
      final id = '${++_session}';
      sessions[id] = OneDriveUploadSession(path);
      return _FakeResponse.json(200, {
        'uploadUrl': 'https://signed.onedrive.test/upload/$id',
      });
    }
    if (request.method == 'GET' && request.uri.path.endsWith(':/content')) {
      final path = graphPath!;
      final stored = files[path];
      if (stored == null) return _FakeResponse.json(404, {});
      if (request.headers['If-Match'] != stored.eTag) {
        return _FakeResponse.json(412, {});
      }
      return _FakeResponse(302, const [], {
        'location': [
          'https://signed.onedrive.test/download?path=${Uri.encodeQueryComponent(path)}',
        ],
      });
    }
    if (request.method == 'GET' && request.uri.path.endsWith(':/children')) {
      return _children(request, graphPath!);
    }
    if (request.method == 'GET' && graphPath != null) {
      if (metadataRateLimitsRemaining > 0) {
        metadataRateLimitsRemaining--;
        metadataRateLimitResponses++;
        return _FakeResponse.json(429, {}, const {
          'retry-after': ['0'],
        });
      }
      final stored = files[graphPath];
      if (stored != null) {
        return _FakeResponse.json(200, _item(graphPath, stored));
      }
      if (folders.contains(graphPath)) {
        return _FakeResponse.json(200, {
          'id': _folderId(graphPath),
          'name': graphPath.split('/').last,
          'eTag': '"folder-$graphPath"',
          'size': 0,
          'folder': <String, Object?>{},
        });
      }
      return _FakeResponse.json(404, {});
    }
    if (request.method == 'DELETE' && graphPath != null) {
      final existed =
          files.remove(graphPath) != null || folders.remove(graphPath);
      files.removeWhere((path, _) => path.startsWith('$graphPath/'));
      folders.removeWhere((path) => path.startsWith('$graphPath/'));
      return _FakeResponse(existed ? 204 : 404);
    }
    return _FakeResponse.json(500, {
      'unexpected': '${request.method} ${request.uri}',
    });
  }

  String? _folderPathForChildrenRequest(Uri uri) {
    final segments = uri.pathSegments;
    if (segments.length != 6 ||
        segments[0] != 'v1.0' ||
        segments[1] != 'me' ||
        segments[2] != 'drive' ||
        segments[3] != 'items' ||
        segments[5] != 'children') {
      return null;
    }
    final id = segments[4];
    if (id == 'approot-id') return '';
    if (!id.startsWith('folder-')) return null;
    return Uri.decodeComponent(id.substring('folder-'.length));
  }

  String _folderId(String path) => 'folder-${Uri.encodeComponent(path)}';

  _FakeResponse _children(RequestOptions request, String directory) {
    final names = files.entries.where((entry) {
      final parent = entry.key.contains('/')
          ? entry.key.substring(0, entry.key.lastIndexOf('/'))
          : '';
      return parent == directory;
    }).toList()..sort((first, second) => first.key.compareTo(second.key));
    final page = int.tryParse(request.uri.queryParameters['page'] ?? '') ?? 1;
    final start = (page - 1) * 2;
    final values = names
        .skip(start)
        .take(2)
        .map((entry) => _item(entry.key, entry.value))
        .toList();
    if (page == 1) values.addAll(additionalChildren);
    final hasNext = start + 2 < names.length;
    return _FakeResponse.json(200, {
      'value': values,
      if (hasNext)
        '@odata.nextLink':
            'https://graph.microsoft.test/v1.0/me/drive/special/approot:/${Uri.encodeComponent(directory)}:/children?page=${page + 1}',
    });
  }

  Map<String, Object> _item(String path, StoredOneDriveFile stored) => {
    'id': 'file-${Uri.encodeComponent(path)}',
    'name': path.split('/').last,
    'eTag': stored.eTag,
    'size': stored.bytes.length,
    'file': <String, Object?>{},
  };

  static String? graphItemPath(String uriPath) {
    const marker = '/v1.0/me/drive/special/approot:/';
    if (!uriPath.startsWith(marker)) return null;
    var value = uriPath.substring(marker.length);
    for (final suffix in [':/createUploadSession', ':/content', ':/children']) {
      if (value.endsWith(suffix)) {
        value = value.substring(0, value.length - suffix.length);
        break;
      }
    }
    return Uri.decodeComponent(value);
  }

  String? _graphItemPath(String uriPath) => graphItemPath(uriPath);

  void _ensureFolders(String path) {
    final segments = path.split('/');
    for (var index = 1; index < segments.length; index++) {
      folders.add(segments.take(index).join('/'));
    }
  }

  String _nextETag() => '"e${++_revision}"';

  static Future<Uint8List> _requestBytes(
    RequestOptions request,
    Stream<Uint8List>? stream,
  ) async {
    if (request.data is Uint8List) return request.data as Uint8List;
    if (request.data is List<int>) {
      return Uint8List.fromList(request.data as List<int>);
    }
    final builder = BytesBuilder(copy: false);
    if (stream != null) {
      await for (final chunk in stream) {
        builder.add(chunk);
      }
    }
    return builder.takeBytes();
  }

  @override
  void close({bool force = false}) {}
}
