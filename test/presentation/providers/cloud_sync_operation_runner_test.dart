import 'dart:async';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/cloud_sync/cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/backend/cloud_sync_backend.dart';
import 'package:nai_launcher/presentation/providers/cloud_sync/cloud_sync_operation_runner.dart';
import 'package:nai_launcher/presentation/providers/cloud_sync/cloud_sync_ui_provider.dart';

void main() {
  test('browse and full restore preparation are separate operations', () async {
    final coordinator = _PreviewCoordinator();
    var state = const CloudSyncUiState();
    final runner = CloudSyncOperationRunner(
      coordinator: () => coordinator,
      readState: () => state,
      writeState: (value) => state = value,
      recordError: (_, {bool resetActivity = false}) {},
      readPendingFfdkjIntent: () => false,
      persistSyncState: (_, __) async {},
    );
    await runner.previewRestore('old', OperationToken(), contentsOnly: true);
    expect(coordinator.browseCalls, 1);
    expect(coordinator.prepareCalls, 0);
    expect(state.pendingPreview!.isBrowse, isTrue);
    coordinator.result.complete(
      const RestorePreview(snapshotId: 'old', changes: []),
    );
    await runner.previewRestore('old', OperationToken());
    expect(coordinator.prepareCalls, 1);
    expect(state.pendingPreview!.isBrowse, isFalse);
  });

  test(
    'cancelled preview does not publish old contents or report an error',
    () async {
      final coordinator = _PreviewCoordinator();
      var state = const CloudSyncUiState();
      var errors = 0;
      final runner = CloudSyncOperationRunner(
        coordinator: () => coordinator,
        readState: () => state,
        writeState: (value) => state = value,
        recordError: (_, {bool resetActivity = false}) {
          errors++;
        },
        readPendingFfdkjIntent: () => false,
        persistSyncState: (_, __) async {},
      );
      final token = OperationToken();
      final pending = runner.previewRestore('old', token);
      final expected = expectLater(
        pending,
        throwsA(isA<OperationCancelledException>()),
      );
      token.cancel();
      coordinator.result.complete(
        const RestorePreview(snapshotId: 'old', changes: []),
      );
      await expected;
      expect(state.pendingPreview, isNull);
      expect(state.activityStatus, CloudSyncActivityStatus.idle);
      expect(errors, 0);
    },
  );
  test(
    'pending preview blocks every operation that could replace it',
    () async {
      const pending = CloudSyncPreviewView(changes: []);
      var state = const CloudSyncUiState(pendingPreview: pending);
      final runner = CloudSyncOperationRunner(
        coordinator: () => null,
        readState: () => state,
        writeState: (value) => state = value,
        recordError: (_, {bool resetActivity = false}) {},
        readPendingFfdkjIntent: () => false,
        persistSyncState: (_, __) async {},
      );

      await expectLater(runner.previewInitial(), throwsStateError);
      await expectLater(
        runner.previewRestore('older-snapshot', OperationToken()),
        throwsStateError,
      );
      expect(state.pendingPreview, same(pending));
    },
  );
}

class _Backend extends Mock implements CloudSyncBackend {}

class _Source extends Mock implements CloudSyncDataSource {}

class _Journal extends Mock implements JournalStore {}

class _PreviewCoordinator extends SyncCoordinator {
  _PreviewCoordinator()
    : super(
        backend: _Backend(),
        dataSource: _Source(),
        journalStore: _Journal(),
      );
  final result = Completer<RestorePreview>();
  int browseCalls = 0, prepareCalls = 0;
  @override
  Future<RestorePreview> browseBackup(
    String snapshotId, {
    OperationToken? token,
    SyncProgressCallback? onProgress,
  }) async {
    browseCalls++;
    return RestorePreview(snapshotId: snapshotId, changes: const []);
  }

  @override
  Future<RestorePreview> previewRestore(
    String snapshotId, {
    OperationToken? token,
    SyncProgressCallback? onProgress,
  }) {
    prepareCalls++;
    return result.future;
  }
}
