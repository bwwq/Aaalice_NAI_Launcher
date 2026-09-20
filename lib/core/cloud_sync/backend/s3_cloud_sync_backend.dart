import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import '../operation.dart';
import 'backend_http.dart';
import 'cloud_sync_backend.dart';
import 's3_backend_config.dart';
import 's3_signature.dart';

/// S3-compatible services differ in conditional-write support. Use explicit
/// manual backup, verify writes, and never advertise cross-object atomic GC.
class S3CloudSyncBackend
    implements
        CloudSyncBackend,
        ReadOnlyCloudSyncBackendValidation,
        ConcurrentCloudObjectUploadBackend {
  S3CloudSyncBackend({
    required this.config,
    required String accessKey,
    required String secretKey,
    Dio? dio,
    DateTime Function()? clock,
  }) : _accessKey = accessKey,
       _secretKey = secretKey,
       _http = BackendHttp(dio: dio),
       _clock = clock ?? DateTime.now {
    if (accessKey.trim().isEmpty || secretKey.isEmpty) {
      throw const FormatException('S3 access key and secret key are required.');
    }
  }

  final S3BackendConfig config;
  final String _accessKey;
  final String _secretKey;
  final BackendHttp _http;
  final DateTime Function() _clock;
  @override
  int get maxConcurrentObjectUploads => 1;
  String get _prefix => '${config.namespace}/';
  String get _head => '${_prefix}HEAD.json';
  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,160}$');
  static final _hash = RegExp(r'^[a-f0-9]{64}$');
  static String _digest(List<int> bytes) =>
      crypto.sha256.convert(bytes).toString();
  void _validateId(String id) {
    if (!_id.hasMatch(id)) {
      throw const FormatException('Invalid backup object ID.');
    }
  }

  Future<Response<Uint8List>> _request(
    String method, {
    String? key,
    Map<String, String>? query,
    Uint8List? bytes,
    String? digest,
    int maxBytes = maxCloudListingResponseBytes,
    bool? retryable,
  }) {
    final uri = config.uri(key: key, query: query);
    final payloadHash = digest ?? _digest(bytes ?? const []);
    return _http.request(
      method,
      uri,
      data: bytes,
      headersForAttempt: () => S3Signature.headers(
        method: method,
        uri: uri,
        accessKey: _accessKey,
        secretKey: _secretKey,
        region: config.region,
        payloadHash: payloadHash,
        now: _clock(),
      ),
      followRedirects: false,
      retryable: retryable,
      maxResponseBytes: maxBytes,
    );
  }

  void _expect(Response<Uint8List> response, Set<int> allowed) {
    if (allowed.contains(response.statusCode)) return;
    final status = response.statusCode;
    final kind = switch (status) {
      401 => CloudBackendErrorKind.authentication,
      403 => CloudBackendErrorKind.authorization,
      404 => CloudBackendErrorKind.notFound,
      409 || 412 => CloudBackendErrorKind.conflict,
      413 || 507 => CloudBackendErrorKind.quota,
      429 => CloudBackendErrorKind.rateLimited,
      301 || 302 || 307 || 308 => CloudBackendErrorKind.redirectRejected,
      _ => CloudBackendErrorKind.invalidResponse,
    };
    throw CloudBackendException(
      kind,
      'S3 request failed (HTTP $status). Check endpoint, bucket, region and permissions.',
      statusCode: status,
    );
  }

  @override
  Future<void> validateConnectionReadOnly() async {
    await _listPage(prefix: _prefix, maximum: 1);
  }

  @override
  Future<CloudBackendCapability> testCapability() async {
    await validateConnectionReadOnly();
    return const CloudBackendCapability(
      mode: CloudBackendMode.manualBackupOnly,
      message: 'S3 manual backup; do not write from multiple devices at once.',
      supportsHistory: true,
      supportsDelete: false,
    );
  }

  Future<CloudObjectRead?> _get(String key, int maxBytes) async {
    final response = await _request('GET', key: key, maxBytes: maxBytes);
    if (response.statusCode == 404) return null;
    _expect(response, {200});
    final bytes = response.data ?? Uint8List(0);
    return CloudObjectRead(bytes: bytes, revision: _digest(bytes));
  }

  @override
  Future<CloudHeadRead?> readHead() async {
    final read = await _get(_head, maxCloudHeadResponseBytes);
    return read == null
        ? null
        : CloudHeadRead(bytes: read.bytes, revision: read.revision);
  }

  @override
  Future<CloudObjectRead?> readObject(String objectId) {
    _validateId(objectId);
    return _get('${_prefix}objects/$objectId', maxCloudObjectResponseBytes);
  }

  @override
  Future<CloudObjectRead?> readSnapshotManifest(String snapshotId) {
    _validateId(snapshotId);
    return _get(
      '${_prefix}snapshots/$snapshotId.json',
      maxCloudManifestResponseBytes,
    );
  }

  Future<CloudCommitResult> _put(
    String key,
    Uint8List bytes,
    String digest,
    int maximum,
    bool verified,
  ) async {
    if (bytes.length > maximum ||
        !_hash.hasMatch(digest) ||
        (!verified && _digest(bytes) != digest)) {
      throw const FormatException('Invalid backup payload size or checksum.');
    }
    final existing = await _get(key, maximum);
    if (existing != null) {
      if (existing.revision != digest) {
        throw const CloudBackendException(
          CloudBackendErrorKind.conflict,
          'S3 already contains different data for this backup object.',
        );
      }
      return CloudCommitResult(revision: digest);
    }
    final response = await _request(
      'PUT',
      key: key,
      bytes: bytes,
      digest: digest,
      retryable: true,
    );
    _expect(response, {200, 201, 204});
    return _verifyWrite(key, digest, maximum);
  }

  Future<CloudCommitResult> _verifyWrite(
    String key,
    String digest,
    int maximum,
  ) async {
    final stored = await _get(key, maximum);
    if (stored?.revision != digest) {
      throw const CloudBackendException(
        CloudBackendErrorKind.invalidResponse,
        'S3 backup write could not be verified.',
      );
    }
    return CloudCommitResult(revision: digest);
  }

  @override
  Future<CloudCommitResult> putObject(
    String objectId,
    Uint8List bytes, {
    required String sha256,
    bool payloadVerified = false,
  }) {
    _validateId(objectId);
    if (objectId != sha256) {
      throw const FormatException('Object ID must match checksum.');
    }
    return _put(
      '${_prefix}objects/$objectId',
      bytes,
      sha256,
      maxCloudObjectResponseBytes,
      payloadVerified,
    );
  }

  @override
  Future<CloudCommitResult> putSnapshotManifest(
    String snapshotId,
    Uint8List bytes, {
    required String sha256,
    bool payloadVerified = false,
  }) {
    _validateId(snapshotId);
    return _put(
      '${_prefix}snapshots/$snapshotId.json',
      bytes,
      sha256,
      maxCloudManifestResponseBytes,
      payloadVerified,
    );
  }

  @override
  Future<CloudCommitResult> commitHead(
    Uint8List bytes, {
    required String? expectedRevision,
  }) async {
    if (bytes.length > maxCloudHeadResponseBytes) {
      throw const FormatException('Backup HEAD exceeds the object limit.');
    }
    final digest = _digest(bytes);
    final before = await readHead();
    if (before?.revision == digest) return CloudCommitResult(revision: digest);
    if (before?.revision != expectedRevision) {
      throw const CloudBackendException(
        CloudBackendErrorKind.conflict,
        'S3 backup changed; refresh before uploading.',
      );
    }
    // Read-before-write is not CAS; capability remains manualBackupOnly.
    final response = await _request(
      'PUT',
      key: _head,
      bytes: bytes,
      digest: digest,
      retryable: false,
    );
    _expect(response, {200, 201, 204});
    return _verifyWrite(_head, digest, maxCloudHeadResponseBytes);
  }

  Future<({List<String> keys, String? next})> _listPage({
    required String prefix,
    String? continuation,
    int maximum = 1000,
  }) async {
    final response = await _request(
      'GET',
      query: {
        'list-type': '2',
        'prefix': prefix,
        'max-keys': '$maximum',
        'encoding-type': 'url',
        if (continuation != null) 'continuation-token': continuation,
      },
    );
    _expect(response, {200});
    try {
      final root = XmlDocument.parse(utf8.decode(response.data!)).rootElement;
      if (root.name.local != 'ListBucketResult') throw const FormatException();
      String? field(XmlElement node, String name) => node.childElements
          .where((e) => e.name.local == name)
          .firstOrNull
          ?.innerText;
      final encoded = field(root, 'EncodingType') == 'url';
      final keys = <String>[];
      for (final item in root.childElements.where(
        (e) => e.name.local == 'Contents',
      )) {
        final raw = field(item, 'Key');
        if (raw == null) throw const FormatException();
        final key = encoded ? Uri.decodeComponent(raw) : raw;
        if (!key.startsWith(prefix)) throw const FormatException();
        keys.add(key);
      }
      final truncated = field(root, 'IsTruncated');
      if (truncated != 'true' && truncated != 'false') {
        throw const FormatException();
      }
      final next = truncated == 'true'
          ? field(root, 'NextContinuationToken')
          : null;
      if (truncated == 'true' && (next == null || next.isEmpty)) {
        throw const FormatException();
      }
      return (keys: keys, next: next);
    } on Object {
      throw const CloudBackendException(
        CloudBackendErrorKind.invalidResponse,
        'S3 returned an invalid object listing.',
      );
    }
  }

  @override
  Future<List<String>> listSnapshotIds({int limit = 20}) async {
    if (limit <= 0) return [];
    final prefix = '${_prefix}snapshots/';
    final ids = <String>{};
    final tokens = <String>{};
    String? next;
    do {
      await OperationToken.current?.checkpoint();
      final page = await _listPage(prefix: prefix, continuation: next);
      for (final key in page.keys) {
        final name = key.substring(prefix.length);
        if (name.endsWith('.json')) {
          final id = name.substring(0, name.length - 5);
          if (_id.hasMatch(id)) ids.add(id);
        }
      }
      next = page.next;
      if (next != null && !tokens.add(next)) {
        throw const CloudBackendException(
          CloudBackendErrorKind.invalidResponse,
          'S3 repeated a listing continuation token.',
        );
      }
    } while (next != null);
    return (ids.toList()..sort((a, b) => b.compareTo(a))).take(limit).toList();
  }

  @override
  Future<void> deleteNamespace() => Future.error(
    const CloudBackendException(
      CloudBackendErrorKind.authorization,
      'Delete this backup prefix through the S3 provider console.',
    ),
  );
}
