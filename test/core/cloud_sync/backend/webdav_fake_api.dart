import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'backend_test_support.dart';

class StatefulWebDavApi {
  bool strongEtags = true;
  final Map<String, Uint8List> _files = {};
  final Map<String, String> _etags = {};
  final Set<String> _collections = {'/sync/'};
  var _revision = 0;
  String _etag(String path) =>
      strongEtags ? _etags[path]! : 'W/${_etags[path]}';

  TestHttpResponse handle(RequestOptions request) {
    final path = request.uri.path;
    switch (request.method) {
      case 'MKCOL':
        if (_collections.contains(path)) return const TestHttpResponse(405);
        final parent = _parentCollection(path);
        if (!_collections.contains(parent)) return const TestHttpResponse(409);
        _collections.add(_collectionPath(path));
        return const TestHttpResponse(201);
      case 'GET':
        final bytes = _files[path];
        if (bytes == null) return const TestHttpResponse(404);
        return TestHttpResponse(200, bytes, {
          'etag': [_etag(path)],
        });
      case 'HEAD':
        final etag = _etags[path];
        if (etag == null) return const TestHttpResponse(404);
        return TestHttpResponse(200, '', {
          'etag': [_etag(path)],
        });
      case 'PUT':
        final existing = _files[path];
        if (request.headers['If-None-Match'] == '*' && existing != null) {
          return const TestHttpResponse(412);
        }
        final expected = request.headers['If-Match']?.toString();
        if (expected != null && expected != _etags[path]) {
          return const TestHttpResponse(412);
        }
        _files[path] = Uint8List.fromList(request.data as List<int>);
        final etag = '"stateful-${++_revision}"';
        _etags[path] = etag;
        return TestHttpResponse(existing == null ? 201 : 204, '', {
          'etag': [_etag(path)],
        });
      case 'DELETE':
        final expected = request.headers['If-Match']?.toString();
        if (!_files.containsKey(path)) return const TestHttpResponse(404);
        if (expected != null && expected != _etags[path]) {
          return const TestHttpResponse(412);
        }
        _files.remove(path);
        _etags.remove(path);
        return const TestHttpResponse(204);
      case 'PROPFIND':
        return _propfind(path, request.headers['Depth']?.toString());
      default:
        return TestHttpResponse(
          500,
          'unexpected ${request.method} ${request.uri}',
        );
    }
  }

  TestHttpResponse _propfind(String path, String? depth) {
    final isCollection = _collections.contains(_collectionPath(path));
    final isFile = _files.containsKey(path);
    if (!isCollection && !isFile) return const TestHttpResponse(404);

    final entries = <String>[
      _entry(
        isCollection ? _collectionPath(path) : path,
        collection: isCollection,
      ),
    ];
    if (depth == '1' && isCollection) {
      final collection = _collectionPath(path);
      entries.addAll(
        _collections
            .where(
              (candidate) =>
                  candidate != collection &&
                  _parentCollection(candidate) == collection,
            )
            .map((candidate) => _entry(candidate, collection: true)),
      );
      entries.addAll(
        _files.keys
            .where((candidate) => _parentCollection(candidate) == collection)
            .map((candidate) => _entry(candidate)),
      );
    }
    return TestHttpResponse(
      207,
      '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
      '${entries.join()}</d:multistatus>',
      const {
        'date': ['Thu, 12 Mar 2026 12:00:00 GMT'],
      },
    );
  }

  String _entry(String path, {bool collection = false}) {
    final etag = _etags[path];
    return '<d:response><d:href>$path</d:href><d:propstat>'
        '<d:status>HTTP/1.1 200 OK</d:status><d:prop>'
        '${etag == null ? '' : '<d:getetag>${_etag(path)}</d:getetag>'}'
        '<d:getlastmodified>Tue, 10 Mar 2026 12:00:00 GMT</d:getlastmodified>'
        '<d:getcontentlength>${_files[path]?.length ?? 0}</d:getcontentlength>'
        '<d:resourcetype>${collection ? '<d:collection/>' : ''}</d:resourcetype>'
        '</d:prop></d:propstat></d:response>';
  }

  static String _collectionPath(String path) =>
      path.endsWith('/') ? path : '$path/';

  static String _parentCollection(String path) {
    final normalized = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final slash = normalized.lastIndexOf('/');
    return normalized.substring(0, slash + 1);
  }
}
