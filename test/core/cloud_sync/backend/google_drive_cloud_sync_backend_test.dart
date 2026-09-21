import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/backend/cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/backend/google_drive_cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/operation.dart';

import 'backend_test_support.dart';
import 'cloud_sync_backend_contract.dart';

import 'google_drive_fake_api.dart';

void main() {
  runCloudSyncBackendContract(
    provider: 'Google Drive',
    createBackend: () => _backend(FakeDriveApi()),
    expectations: const CloudSyncBackendContractExpectations(
      mode: CloudBackendMode.manualBackupOnly,
    ),
  );

  test('cancellation interrupts the private access-token wait', () async {
    final tokenResult = Completer<String>();
    final adapter = RecordingAdapter(
      (_) => const TestHttpResponse(200, '{"files":[]}'),
    );
    final backend = GoogleDriveCloudSyncBackend(
      accessTokenProvider: () => tokenResult.future,
      namespace: 'cloud',
      apiBaseUri: Uri.parse('https://google.test/'),
      dio: Dio()..httpClientAdapter = adapter,
    );
    final operation = OperationToken();
    final capability = operation.runInScope(backend.testCapability);

    operation.cancel();

    await expectLater(capability, throwsA(isA<OperationCancelledException>()));
    expect(adapter.requests, isEmpty);
    tokenResult.complete('late-token');
  });

  test(
    'capability is explicitly manual-only and warns about missing CAS',
    () async {
      final api = FakeDriveApi();

      final capability = await _backend(api).testCapability();

      expect(capability.mode, CloudBackendMode.manualBackupOnly);
      expect(capability.supportsBidirectional, isFalse);
      expect(capability.warnings, [CloudBackendWarning.googleDriveWeakCas]);
      expect(
        api.requests.single.uri.queryParameters['spaces'],
        'appDataFolder',
      );
    },
  );

  test('readObject rejects content stored under the wrong hash id', () async {
    final api = FakeDriveApi();
    final expectedId = sha256.convert(const [1, 2, 3]).toString();
    api.addFile(
      name: 'aaalice-cloud-sync-object-$expectedId',
      type: 'object',
      bytes: Uint8List.fromList(const [9, 9, 9]),
    );

    await expectLater(
      _backend(api).readObject(expectedId),
      throwsA(
        isA<CloudBackendException>().having(
          (error) => error.kind,
          'kind',
          CloudBackendErrorKind.conflict,
        ),
      ),
    );
  });

  test(
    'uploads and downloads hidden deterministic appDataFolder records',
    () async {
      final api = FakeDriveApi();
      final backend = _backend(api);
      final object = Uint8List.fromList([1, 2, 3, 4]);
      final manifest = Uint8List.fromList(utf8.encode('{"snapshot":"s1"}'));

      await backend.putObject(
        's1.0',
        object,
        sha256: sha256.convert(object).toString(),
      );
      await backend.putSnapshotManifest(
        's1',
        manifest,
        sha256: sha256.convert(manifest).toString(),
      );

      expect((await backend.readObject('s1.0'))!.bytes, object);
      expect((await backend.readSnapshotManifest('s1'))!.bytes, manifest);
      expect(
        api.files.values.map((file) => file.name),
        containsAll([
          'aaalice-cloud-sync-object-s1.0',
          'aaalice-cloud-sync-snapshot-s1.json',
        ]),
      );
      for (final file in api.files.values) {
        expect(file.parents, ['appDataFolder']);
        expect(file.appProperties['protocol'], 'aaalice-cloud-sync-v2');
        expect(file.appProperties['namespace'], hasLength(64));
      }
    },
  );

  test('builds one complete paginated protocol inventory', () async {
    final bytes = Uint8List.fromList([1]);
    final objectId = sha256.convert(bytes).toString();
    final api = FakeDriveApi(forceSingleItemPages: true)
      ..addFile(
        name: 'aaalice-cloud-sync-object-$objectId',
        type: 'object',
        bytes: bytes,
      )
      ..addFile(
        name: 'aaalice-cloud-sync-snapshot-s3.json',
        type: 'manifest',
        bytes: Uint8List.fromList([3]),
      )
      ..addFile(
        name: 'aaalice-cloud-sync-snapshot-s2.json',
        type: 'manifest',
        bytes: Uint8List.fromList([2]),
      );
    final backend = _backend(api);

    expect(await backend.findExistingObjects({objectId: 1}), {objectId});
    expect(await backend.listSnapshotIds(limit: 2), ['s3', 's2']);

    final lists = api.requests
        .where((request) => request.uri.path == '/drive/v3/files')
        .toList();
    expect(lists, hasLength(3));
    expect(lists.last.uri.queryParameters['pageToken'], isNotNull);
    for (final request in lists) {
      expect(request.uri.queryParameters['pageSize'], '1000');
      expect(
        request.uri.queryParameters['fields'],
        'nextPageToken,files(id,name,size,md5Checksum,modifiedTime,version,appProperties)',
      );
      final query = request.uri.queryParameters['q']!;
      expect(
        query,
        contains("key='protocol' and value='aaalice-cloud-sync-v2'"),
      );
      expect(query, contains("key='namespace' and value='"));
      expect(query, isNot(contains("key='recordType'")));
      expect(query, isNot(contains('name =')));
    }
  });

  test('each operation builds at most one fresh inventory', () async {
    final api = FakeDriveApi();
    final backend = _backend(api);

    await OperationToken().runInScope(() async {
      await backend.readHead();
      await backend.findExistingObjects(const {'missing': 1});
      await backend.listSnapshotIds();
    });
    expect(
      api.requests.where((request) => request.uri.path == '/drive/v3/files'),
      hasLength(1),
    );

    await OperationToken().runInScope(backend.readHead);
    expect(
      api.requests.where((request) => request.uri.path == '/drive/v3/files'),
      hasLength(2),
    );
  });

  test('concurrent readers share one inventory listing', () async {
    final bytes = Uint8List.fromList([1]);
    final objectId = sha256.convert(bytes).toString();
    final api = FakeDriveApi()
      ..addFile(
        name: 'aaalice-cloud-sync-object-$objectId',
        type: 'object',
        bytes: bytes,
      );
    final backend = _backend(api);

    final results = await Future.wait([
      backend.findExistingObjects({objectId: 1}),
      backend.findExistingObjects({objectId: 1}),
    ]);

    expect(results, everyElement({objectId}));
    expect(
      api.requests.where((request) => request.uri.path == '/drive/v3/files'),
      hasLength(1),
    );
  });

  test('rejects a repeated Drive pagination token', () async {
    final adapter = RecordingAdapter(
      (_) => const TestHttpResponse(
        200,
        '{"files":[],"nextPageToken":"repeated"}',
      ),
    );

    await expectLater(
      _backend(adapter).listSnapshotIds(),
      throwsA(isA<CloudBackendException>()),
    );
    expect(adapter.requests, hasLength(2));
  });

  test(
    'identical immutable duplicates are verified, different ones conflict',
    () async {
      final same = Uint8List.fromList([7, 8, 9]);
      final api = FakeDriveApi()
        ..addFile(
          name: 'aaalice-cloud-sync-object-item',
          type: 'object',
          bytes: same,
        )
        ..addFile(
          name: 'aaalice-cloud-sync-object-item',
          type: 'object',
          bytes: Uint8List.fromList(same),
        );
      final backend = _backend(api);

      final result = await backend.putObject(
        'item',
        same,
        sha256: sha256.convert(same).toString(),
      );
      expect(result.revision, isNotEmpty);
      expect(
        api.requests.where((request) => request.method == 'POST'),
        isEmpty,
      );

      api.addFile(
        name: 'aaalice-cloud-sync-object-item',
        type: 'object',
        bytes: Uint8List.fromList([0]),
      );
      await expectLater(
        _backend(api).readObject('item'),
        throwsA(
          isA<CloudBackendException>().having(
            (error) => error.kind,
            'kind',
            CloudBackendErrorKind.conflict,
          ),
        ),
      );
    },
  );

  test('mutable duplicate names conflict instead of pretending CAS', () async {
    final api = FakeDriveApi()
      ..addFile(
        name: 'aaalice-cloud-sync-HEAD.json',
        type: 'head',
        bytes: Uint8List.fromList([1]),
      )
      ..addFile(
        name: 'aaalice-cloud-sync-HEAD.json',
        type: 'head',
        bytes: Uint8List.fromList([1]),
      );

    await expectLater(
      _backend(api).readHead(),
      throwsA(
        isA<CloudBackendException>().having(
          (error) => error.kind,
          'kind',
          CloudBackendErrorKind.conflict,
        ),
      ),
    );
  });

  test(
    'inventory rejects duplicate names and mismatched expected size',
    () async {
      final duplicateApi = FakeDriveApi()
        ..addFile(
          name: 'aaalice-cloud-sync-object-item',
          type: 'object',
          bytes: Uint8List.fromList([1]),
        )
        ..addFile(
          name: 'aaalice-cloud-sync-object-item',
          type: 'object',
          bytes: Uint8List.fromList([1]),
        );

      await expectLater(
        _backend(duplicateApi).findExistingObjects({'item': 1}),
        throwsA(
          isA<CloudBackendException>().having(
            (error) => error.kind,
            'kind',
            CloudBackendErrorKind.conflict,
          ),
        ),
      );

      final wrongSizeApi = FakeDriveApi()
        ..addFile(
          name: 'aaalice-cloud-sync-object-item',
          type: 'object',
          bytes: Uint8List.fromList([1, 2]),
        );
      await expectLater(
        _backend(wrongSizeApi).findExistingObjects({'item': 1}),
        throwsA(
          isA<CloudBackendException>().having(
            (error) => error.kind,
            'kind',
            CloudBackendErrorKind.conflict,
          ),
        ),
      );
    },
  );

  test(
    'inventory and create responses remove re-listing and readback',
    () async {
      final api = FakeDriveApi();
      final backend = _backend(api);
      final first = Uint8List.fromList([1, 2]);
      final second = Uint8List.fromList([3, 4, 5]);

      expect(
        await backend.findExistingObjects({
          'first': first.length,
          'second': second.length,
        }),
        isEmpty,
      );
      await backend.putObject(
        'first',
        first,
        sha256: sha256.convert(first).toString(),
      );
      await backend.putObject(
        'second',
        second,
        sha256: sha256.convert(second).toString(),
      );

      expect(api.requests, hasLength(3));
      expect(api.requests.map((request) => request.method), [
        'GET',
        'POST',
        'POST',
      ]);
      expect(
        api.requests.where((request) => request.uri.path == '/drive/v3/files'),
        hasLength(1),
      );
    },
  );

  test(
    'lost create response uses a fresh inventory in the next operation',
    () async {
      final bytes = Uint8List.fromList([8, 6, 7, 5]);
      final api = FakeDriveApi()..loseNextCreateResponse = true;
      final backend = _backend(api);

      await OperationToken().runInScope(() async {
        await expectLater(
          backend.putObject(
            'ambiguous',
            bytes,
            sha256: sha256.convert(bytes).toString(),
          ),
          throwsA(isA<CloudBackendException>()),
        );
        await expectLater(
          backend.readHead(),
          throwsA(isA<CloudBackendException>()),
        );
      });
      expect(api.files, hasLength(1));
      expect(
        api.requests.where(
          (request) =>
              request.method == 'GET' && request.uri.path == '/drive/v3/files',
        ),
        hasLength(1),
      );

      final retried = await OperationToken().runInScope(
        () => backend.putObject(
          'ambiguous',
          bytes,
          sha256: sha256.convert(bytes).toString(),
        ),
      );

      expect(retried.revision, isNotEmpty);
      expect(api.files, hasLength(1));
      expect(
        api.requests.where((request) => request.method == 'POST'),
        hasLength(1),
      );
      expect(
        api.requests.where(
          (request) =>
              request.method == 'GET' && request.uri.path == '/drive/v3/files',
        ),
        hasLength(2),
      );
    },
  );

  test('lost mutable create response retries as a CAS conflict', () async {
    final api = FakeDriveApi()..loseNextCreateResponse = true;
    final backend = _backend(api);

    await expectLater(
      OperationToken().runInScope(
        () =>
            backend.commitHead(Uint8List.fromList([1]), expectedRevision: null),
      ),
      throwsA(isA<CloudBackendException>()),
    );
    await expectLater(
      OperationToken().runInScope(
        () =>
            backend.commitHead(Uint8List.fromList([1]), expectedRevision: null),
      ),
      throwsA(
        isA<CloudBackendException>().having(
          (error) => error.kind,
          'kind',
          CloudBackendErrorKind.conflict,
        ),
      ),
    );

    expect(api.files, hasLength(1));
    expect(
      api.requests.where((request) => request.method == 'POST'),
      hasLength(1),
    );
  });

  test('429 list response is retried before upload', () async {
    final api = FakeDriveApi()
      ..remainingRateLimits = 1
      ..rateLimitPath = '/drive/v3/files';
    final bytes = Uint8List.fromList([4, 2]);

    await _backend(
      api,
    ).putObject('retry', bytes, sha256: sha256.convert(bytes).toString());

    expect(api.rateLimitResponses, 1);
    expect(
      api.requests.where((request) => request.method == 'POST'),
      hasLength(1),
    );
  });

  test('403 user rate limit is retried for idempotent reads', () async {
    var attempts = 0;
    final adapter = RecordingAdapter((_) {
      attempts++;
      if (attempts == 1) {
        return const TestHttpResponse(
          403,
          '{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}',
          {
            'retry-after': ['0'],
          },
        );
      }
      return const TestHttpResponse(200, '{"files":[]}');
    });

    expect(await _backend(adapter).listSnapshotIds(), isEmpty);
    expect(attempts, 2);
  });

  test('create and update writes are never retried', () async {
    final createApi = FakeDriveApi()
      ..remainingRateLimits = 2
      ..rateLimitPath = '/upload/drive/v3/files';
    final bytes = Uint8List.fromList([4, 2]);
    await expectLater(
      _backend(
        createApi,
      ).putObject('no-retry', bytes, sha256: sha256.convert(bytes).toString()),
      throwsA(isA<CloudBackendException>()),
    );
    expect(
      createApi.requests.where((request) => request.method == 'POST'),
      hasLength(1),
    );

    final updateApi = FakeDriveApi()
      ..addFile(
        name: 'aaalice-cloud-sync-HEAD.json',
        type: 'head',
        bytes: Uint8List.fromList([1]),
      );
    final backend = _backend(updateApi);
    final head = await backend.readHead();
    updateApi
      ..remainingRateLimits = 2
      ..rateLimitPath = '/upload/drive/v3/files/file-1';
    await expectLater(
      backend.commitHead(
        Uint8List.fromList([2]),
        expectedRevision: head!.revision,
      ),
      throwsA(isA<CloudBackendException>()),
    );
    expect(
      updateApi.requests.where((request) => request.method == 'PATCH'),
      hasLength(1),
    );
  });

  test(
    'HEAD revision only rejects an already-stale read before best-effort write',
    () async {
      final api = FakeDriveApi();
      final backend = _backend(api);
      final first = await backend.commitHead(
        Uint8List.fromList([1]),
        expectedRevision: null,
      );
      await backend.commitHead(
        Uint8List.fromList([2]),
        expectedRevision: first.revision,
      );

      await expectLater(
        backend.commitHead(
          Uint8List.fromList([3]),
          expectedRevision: first.revision,
        ),
        throwsA(
          isA<CloudBackendException>().having(
            (error) => error.kind,
            'kind',
            CloudBackendErrorKind.conflict,
          ),
        ),
      );
      expect((await backend.testCapability()).supportsBidirectional, isFalse);
    },
  );
}

GoogleDriveCloudSyncBackend _backend(HttpClientAdapter adapter) =>
    GoogleDriveCloudSyncBackend(
      accessTokenProvider: () async => 'access-token-secret',
      namespace: 'cloud',
      apiBaseUri: Uri.parse('https://google.test/'),
      dio: Dio()..httpClientAdapter = adapter,
    );
