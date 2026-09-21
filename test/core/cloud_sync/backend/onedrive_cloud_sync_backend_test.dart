import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/backend/cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/backend/onedrive_cloud_sync_backend.dart';
import 'package:nai_launcher/core/cloud_sync/operation.dart';

import 'cloud_sync_backend_contract.dart';
import '../packed_snapshot_contract.dart';

import 'onedrive_fake_api.dart';

void main() {
  test(
    'two clients reuse concurrently created folders and identical objects',
    () async {
      final api = FakeOneDriveApi();
      final bytes = Uint8List.fromList([4, 2]);
      final id = sha256.convert(bytes).toString();
      final results = await Future.wait([
        _backend(api).putObject(id, bytes, sha256: id),
        _backend(api).putObject(id, bytes, sha256: id),
      ]);
      expect(results, hasLength(2));
      expect((await _backend(api).readObject(id))!.bytes, bytes);
      expect(api.folders.where((path) => path == 'cloud'), hasLength(1));
      expect(
        api.folders.where((path) => path == 'cloud/objects'),
        hasLength(1),
      );
    },
  );

  test(
    'transient approot provisioning failure completes without a second login',
    () async {
      final api = FakeOneDriveApi()
        ..appRootFailureStatus = 503
        ..appRootFailuresRemaining = 1;
      final capability = await _backend(api).testCapability();
      expect(capability.supportsBidirectional, isTrue);
      expect(api.appRootRequests, 2);
      expect(api.requests.every((request) => request.method == 'GET'), isTrue);
    },
  );

  test(
    'packed configuration roundtrip preserves legacy OneDrive backups',
    () async {
      final api = FakeOneDriveApi();
      await verifyPackedSnapshotRoundTrip(_backend(api), _backend(api));
    },
  );

  runCloudSyncBackendContract(
    provider: 'OneDrive',
    createBackend: () => _backend(FakeOneDriveApi()),
    expectations: const CloudSyncBackendContractExpectations(
      mode: CloudBackendMode.bidirectional,
    ),
  );

  test('cancellation interrupts the private access-token wait', () async {
    final tokenResult = Completer<String>();
    final api = FakeOneDriveApi();
    final backend = OneDriveCloudSyncBackend(
      accessTokenProvider: () => tokenResult.future,
      namespace: 'cloud',
      graphBaseUri: Uri.parse('https://graph.microsoft.test/v1.0/'),
      dio: Dio()..httpClientAdapter = api,
    );
    final operation = OperationToken();
    final capability = operation.runInScope(backend.testCapability);

    operation.cancel();

    await expectLater(capability, throwsA(isA<OperationCancelledException>()));
    expect(api.requests, isEmpty);
    tokenResult.complete('late-token');
  });

  test('cancellation interrupts Graph download retry backoff', () async {
    final api = RateLimitedDownloadOneDriveApi();
    api.putFile('cloud/objects/snapshot.0', utf8.encode('payload'));
    final backend = OneDriveCloudSyncBackend(
      accessTokenProvider: () async => 'secret-access-token',
      namespace: 'cloud',
      graphBaseUri: Uri.parse('https://graph.microsoft.test/v1.0/'),
      dio: Dio()..httpClientAdapter = api,
    );
    final operation = OperationToken();
    final download = operation.runInScope(
      () => backend.readObject('snapshot.0'),
    );
    await api.downloadStarted.future;

    operation.cancel();

    await expectLater(download, throwsA(isA<OperationCancelledException>()));
  });

  test('uploads and downloads through approot without leaking token', () async {
    final api = FakeOneDriveApi();
    final dio = Dio()..httpClientAdapter = api;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers.putIfAbsent(
            'Authorization',
            () => 'Bearer interceptor-token',
          );
          handler.next(options);
        },
      ),
    );
    final backend = OneDriveCloudSyncBackend(
      accessTokenProvider: () async => 'secret-access-token',
      namespace: 'cloud',
      graphBaseUri: Uri.parse('https://graph.microsoft.test/v1.0/'),
      dio: dio,
    );
    final bytes = Uint8List.fromList(utf8.encode('object payload'));

    final uploaded = await backend.putObject(
      'snapshot.0',
      bytes,
      sha256: sha256.convert(bytes).toString(),
    );
    final downloaded = await backend.readObject('snapshot.0');

    expect(downloaded!.bytes, bytes);
    expect(downloaded.revision, uploaded.revision);
    final appRootGet = api.requests.indexWhere(
      (request) =>
          request.method == 'GET' &&
          request.uri.path == '/v1.0/me/drive/special/approot',
    );
    final firstFolderCreate = api.requests.indexWhere(
      (request) =>
          request.method == 'POST' &&
          request.uri.path == '/v1.0/me/drive/items/approot-id/children',
    );
    expect(appRootGet, greaterThanOrEqualTo(0));
    expect(firstFolderCreate, greaterThan(appRootGet));
    final folderCreateRequest = api.requests[firstFolderCreate];
    expect(folderCreateRequest.uri.queryParameters, isEmpty);
    final folderCreateBody =
        jsonDecode(folderCreateRequest.data as String) as Map<String, dynamic>;
    expect(folderCreateBody, {
      'name': 'cloud',
      'folder': <String, Object?>{},
      '@microsoft.graph.conflictBehavior': 'fail',
    });
    expect(
      api.requests.any(
        (request) => request.uri.path.contains(
          '/me/drive/special/approot:/cloud/objects/snapshot.0',
        ),
      ),
      isTrue,
    );
    final signedRequests = api.requests.where(
      (request) => request.uri.host == 'signed.onedrive.test',
    );
    expect(signedRequests, isNotEmpty);
    for (final request in signedRequests) {
      expect(
        request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')),
      );
    }
  });

  test(
    'inventories all object pages once and uploads missing objects without metadata',
    () async {
      final existingBytesA = Uint8List.fromList([1]);
      final existingBytesB = Uint8List.fromList([2, 3]);
      final unrelatedBytes = Uint8List.fromList([4]);
      final existingA = sha256.convert(existingBytesA).toString();
      final existingB = sha256.convert(existingBytesB).toString();
      final unrelated = sha256.convert(unrelatedBytes).toString();
      final missingBytesA = Uint8List.fromList([7, 8, 9]);
      final missingBytesB = Uint8List.fromList([10, 11, 12]);
      final missingA = sha256.convert(missingBytesA).toString();
      final missingB = sha256.convert(missingBytesB).toString();
      final api = FakeOneDriveApi()
        ..putFile('cloud/objects/$existingA', existingBytesA)
        ..putFile('cloud/objects/$existingB', existingBytesB)
        ..putFile('cloud/objects/$unrelated', unrelatedBytes);
      final backend = _backend(api);

      final existing = await backend.findExistingObjects({
        existingA: 1,
        existingB: 2,
        missingA: missingBytesA.length,
        missingB: missingBytesB.length,
      });
      await backend.putObject(missingA, missingBytesA, sha256: missingA);
      await backend.putObject(missingB, missingBytesB, sha256: missingB);

      expect(existing, {existingA, existingB});
      expect(api.appRootRequests, 1);
      expect(
        api.requests.where(
          (request) =>
              request.method == 'POST' &&
              request.uri.path.endsWith('/children'),
        ),
        isEmpty,
      );
      expect(
        api.requests.where(
          (request) =>
              request.method == 'GET' &&
              request.uri.path.endsWith(':/children'),
        ),
        hasLength(2),
      );
      for (final missing in [missingA, missingB]) {
        expect(
          api.requests.where(
            (request) =>
                request.method == 'GET' &&
                FakeOneDriveApi.graphItemPath(request.uri.path) ==
                    'cloud/objects/$missing',
          ),
          isEmpty,
        );
      }
    },
  );

  test('trusted inventory revisions avoid rebuilding content hashes', () async {
    final firstBytes = Uint8List.fromList([1, 2, 3]);
    final secondBytes = Uint8List.fromList([4, 5]);
    final firstId = sha256.convert(firstBytes).toString();
    final secondId = sha256.convert(secondBytes).toString();
    final api = FakeOneDriveApi()
      ..putFile('cloud/objects/$firstId', firstBytes)
      ..putFile('cloud/objects/$secondId', secondBytes);
    final progress = <CloudObjectInventoryProgress>[];

    final first = await _backend(api).findExistingObjects({
      firstId: firstBytes.length,
      secondId: secondBytes.length,
    });
    final downloadsAfterFirst = api.requests
        .where((request) => request.uri.host == 'signed.onedrive.test')
        .length;
    final second = await _backend(api).findExistingObjects(
      {firstId: firstBytes.length, secondId: secondBytes.length},
      trustedRevisions: first.verifiedRevisions,
      onProgress: progress.add,
    );

    expect(second, {firstId, secondId});
    expect(
      api.requests.where(
        (request) => request.uri.host == 'signed.onedrive.test',
      ),
      hasLength(downloadsAfterFirst),
    );
    expect(progress.first.objectsCompleted, 0);
    expect(progress.last.objectsCompleted, 2);
    expect(
      progress.last.bytesCompleted,
      firstBytes.length + secondBytes.length,
    );
  });

  test(
    'object inventory fails closed on size and duplicate conflicts',
    () async {
      final objectId = List.filled(64, 'd').join();
      final sizeConflictApi = FakeOneDriveApi()
        ..putFile('cloud/objects/$objectId', [1, 2]);

      await expectLater(
        _backend(sizeConflictApi).findExistingObjects({objectId: 1}),
        throwsA(
          isA<CloudBackendException>().having(
            (error) => error.kind,
            'kind',
            CloudBackendErrorKind.conflict,
          ),
        ),
      );

      final duplicateApi = FakeOneDriveApi()
        ..putFile('cloud/objects/$objectId', [1, 2])
        ..additionalChildren.add({
          'id': 'duplicate-id',
          'name': objectId,
          'eTag': '"duplicate"',
          'size': 2,
          'file': <String, Object?>{},
        });
      await expectLater(
        _backend(duplicateApi).findExistingObjects({objectId: 2}),
        throwsA(
          isA<CloudBackendException>().having(
            (error) => error.kind,
            'kind',
            CloudBackendErrorKind.conflict,
          ),
        ),
      );

      final invalidNameApi = FakeOneDriveApi()
        ..putFile('cloud/objects/not-a-sha256', [1]);
      await expectLater(
        _backend(invalidNameApi).findExistingObjects({objectId: 2}),
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

  test('follows every children page before sorting and limiting', () async {
    final api = FakeOneDriveApi()
      ..putFile('cloud/snapshots/2024.json', [1])
      ..putFile('cloud/snapshots/2026.json', [2])
      ..putFile('cloud/snapshots/2025.json', [3])
      ..putFile('cloud/snapshots/ignore.txt', [4]);

    final ids = await _backend(api).listSnapshotIds(limit: 2);

    expect(ids, ['2026', '2025']);
    expect(
      api.requests.where((request) => request.uri.path.endsWith(':/children')),
      hasLength(2),
    );
  });

  test('HEAD uses upload-session If-Match CAS', () async {
    final api = FakeOneDriveApi();
    final backend = _backend(api);
    final head1 = await backend.commitHead(
      Uint8List.fromList([1]),
      expectedRevision: null,
    );

    final head2 = await backend.commitHead(
      Uint8List.fromList([2]),
      expectedRevision: head1.revision,
    );

    expect(head2.revision, isNot(head1.revision));
    final replaceSessions = api.requests.where(
      (request) =>
          request.uri.path.endsWith(':/createUploadSession') &&
          request.headers['If-Match'] == head1.revision,
    );
    expect(replaceSessions, hasLength(1));
    await expectLater(
      backend.commitHead(
        Uint8List.fromList([3]),
        expectedRevision: head1.revision,
      ),
      throwsA(
        isA<CloudBackendException>()
            .having(
              (error) => error.kind,
              'kind',
              CloudBackendErrorKind.conflict,
            )
            .having((error) => error.statusCode, 'statusCode', 412),
      ),
    );
  });

  test(
    'expected null never falls back to overwrite and immutable is idempotent',
    () async {
      final api = FakeOneDriveApi();
      final backend = _backend(api);
      final first = Uint8List.fromList([1, 2]);
      final other = Uint8List.fromList([2, 1]);

      final initial = await backend.putObject(
        'same.0',
        first,
        sha256: sha256.convert(first).toString(),
      );
      final retry = await backend.putObject(
        'same.0',
        first,
        sha256: sha256.convert(first).toString(),
      );
      expect(retry.revision, initial.revision);

      await expectLater(
        backend.putObject(
          'same.0',
          other,
          sha256: sha256.convert(other).toString(),
        ),
        throwsA(
          isA<CloudBackendException>().having(
            (error) => error.kind,
            'kind',
            CloudBackendErrorKind.conflict,
          ),
        ),
      );
      await expectLater(
        backend.commitHead(Uint8List.fromList([9]), expectedRevision: null),
        completion(isA<CloudCommitResult>()),
      );
      await expectLater(
        backend.commitHead(Uint8List.fromList([8]), expectedRevision: null),
        throwsA(
          isA<CloudBackendException>()
              .having(
                (error) => error.kind,
                'kind',
                CloudBackendErrorKind.conflict,
              )
              .having((error) => error.statusCode, 'statusCode', 409),
        ),
      );
      expect(api.fileBytes('cloud/HEAD.json'), [9]);
      final createOnly = api.requests.where((request) {
        if (!request.uri.path.endsWith(
          '/me/drive/special/approot:/cloud/HEAD.json:/createUploadSession',
        )) {
          return false;
        }
        final body = jsonDecode(request.data as String) as Map<String, dynamic>;
        return (body['item'] as Map)['@microsoft.graph.conflictBehavior'] ==
            'fail';
      });
      expect(createOnly, hasLength(2));
    },
  );

  test(
    'deleteNamespace invalidates folder singleflight before rebuild',
    () async {
      final first = Uint8List.fromList([1, 2, 3]);
      final second = Uint8List.fromList([4, 5, 6]);
      final firstId = sha256.convert(first).toString();
      final secondId = sha256.convert(second).toString();
      final api = FakeOneDriveApi();
      final backend = _backend(api);

      await backend.putObject(firstId, first, sha256: firstId);
      await backend.deleteNamespace();
      await backend.putObject(secondId, second, sha256: secondId);

      expect(api.fileBytes('cloud/objects/$secondId'), second);
      expect(
        api.requests.where(
          (request) =>
              request.method == 'POST' &&
              request.uri.path.endsWith('/children'),
        ),
        hasLength(4),
      );
    },
  );

  test(
    'folder 404 invalidates singleflight and rebuilds exactly once',
    () async {
      final first = Uint8List.fromList([1, 2, 3]);
      final second = Uint8List.fromList([7, 8, 9]);
      final firstId = sha256.convert(first).toString();
      final secondId = sha256.convert(second).toString();
      final api = FakeOneDriveApi();
      final backend = _backend(api);

      await backend.putObject(firstId, first, sha256: firstId);
      api.removeNamespace('cloud');
      await backend.putObject(secondId, second, sha256: secondId);

      expect(api.fileBytes('cloud/objects/$secondId'), second);
      expect(
        api.requests.where(
          (request) =>
              request.method == 'POST' &&
              request.uri.path.endsWith(':/createUploadSession'),
        ),
        hasLength(3),
      );
      expect(
        api.requests.where(
          (request) =>
              request.method == 'POST' &&
              request.uri.path.endsWith('/children'),
        ),
        hasLength(4),
      );
    },
  );

  test('retries 429 using Retry-After then succeeds', () async {
    final api = FakeOneDriveApi()
      ..putFile('cloud/objects/item', [5])
      ..metadataRateLimitsRemaining = 2;

    final read = await _backend(api).readObject('item');

    expect(read!.bytes, [5]);
    expect(api.metadataRateLimitResponses, 2);
  });

  test(
    'reports persistent approot provisioning errors after bounded retries',
    () async {
      final api = FakeOneDriveApi()
        ..appRootFailureStatus = 503
        ..appRootFailureCode = 'serviceNotAvailable'
        ..appRootInnerFailureCode = 'itemDisabledDueToPendingProvisioning';

      await expectLater(
        _backend(api).testCapability(),
        throwsA(
          isA<CloudBackendException>()
              .having(
                (error) => error.kind,
                'kind',
                CloudBackendErrorKind.network,
              )
              .having((error) => error.statusCode, 'statusCode', 503)
              .having(
                (error) => error.message,
                'message',
                contains('正在为此账号开通 OneDrive 应用目录'),
              ),
        ),
      );
      expect(api.appRootRequests, 3);
    },
  );

  test('includes a bounded Microsoft error message in diagnostics', () async {
    final api = FakeOneDriveApi()
      ..appRootFailureStatus = 400
      ..appRootFailureCode = 'invalidRequest'
      ..appRootFailureMessage = 'The provided name is invalid.\nRetry later.';

    await expectLater(
      _backend(api).testCapability(),
      throwsA(
        isA<CloudBackendException>()
            .having((error) => error.statusCode, 'statusCode', 400)
            .having(
              (error) => error.message,
              'message',
              contains(
                'invalidRequest: The provided name is invalid. Retry later.',
              ),
            ),
      ),
    );
  });

  test('redacts credentials echoed by Microsoft error messages', () async {
    final api = FakeOneDriveApi()
      ..appRootFailureStatus = 400
      ..appRootFailureCode = 'invalidRequest'
      ..appRootFailureMessage =
          'Authorization: Bearer secret-token password=hunter2';

    await expectLater(
      _backend(api).testCapability(),
      throwsA(
        isA<CloudBackendException>()
            .having(
              (error) => error.message,
              'message',
              contains('Bearer [redacted]'),
            )
            .having(
              (error) => error.message,
              'message',
              contains('password=[redacted]'),
            )
            .having(
              (error) => error.message,
              'message',
              isNot(anyOf(contains('secret-token'), contains('hunter2'))),
            ),
      ),
    );
  });

  test('capability validates app root without backup writes', () async {
    final api = FakeOneDriveApi();

    final capability = await _backend(api).testCapability();

    expect(capability.mode, CloudBackendMode.bidirectional);
    expect(api.requests, hasLength(1));
    expect(api.requests.single.method, 'GET');
    expect(api.requests.single.uri.path, endsWith('/me/drive/special/approot'));
    expect(api.files, isEmpty);
  });
}

OneDriveCloudSyncBackend _backend(HttpClientAdapter adapter) =>
    OneDriveCloudSyncBackend(
      accessTokenProvider: () async => 'secret-access-token',
      namespace: 'cloud',
      graphBaseUri: Uri.parse('https://graph.microsoft.test/v1.0/'),
      dio: Dio()..httpClientAdapter = adapter,
    );
