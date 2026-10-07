import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
// Diagnostics must inspect the same raw context owned by the drag dependency.
// ignore: depend_on_referenced_packages
import 'package:super_native_extensions/raw_drag_drop.dart' as raw;

import '../../../core/agent/resources/agent_chat_resource_drag_format.dart';
import '../../../core/utils/image_share_sanitizer.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/localization_extension.dart';
import '../../adaptive/interaction_policy.dart';
import '../../utils/card_drag_format.dart';
import '../gallery/gallery_drag_file.dart';
import '../gallery/gallery_drag_session.dart';
import 'card_drag_resource.dart';
import 'card_virtual_file.dart';
import 'app_toast.dart';
import 'image_hover_preview_controller.dart';

export 'card_drag_resource.dart';

bool _traceWriteFailureReported = false;
bool _nativeContextTraced = false;

// Opt-in local diagnostics for failures that do not reach native drag startup.
// Records phases only; never image data, resource identities, or credentials.
void _traceCardDrag(String phase) {
  if (kIsWeb) return;
  final logPath = Platform.environment['NAI_CARD_DRAG_TRACE'];
  if (logPath == null || logPath.isEmpty) return;
  try {
    File(logPath).writeAsStringSync(
      '${DateTime.now().toIso8601String()} $phase\n',
      mode: FileMode.append,
    );
  } catch (error) {
    if (!_traceWriteFailureReported) {
      _traceWriteFailureReported = true;
      AppLogger.w('Card drag trace could not be written: $error', 'CardDrag');
    }
  }
}

Future<void> _traceNativeDragContext() async {
  if (kIsWeb ||
      _nativeContextTraced ||
      Platform.environment['NAI_CARD_DRAG_TRACE'] == null) {
    return;
  }
  _nativeContextTraced = true;
  try {
    await raw.DragContext.instance().timeout(const Duration(seconds: 5));
    _traceCardDrag('native-context-ready');
  } catch (error) {
    _traceCardDrag('native-context-unavailable: ${error.runtimeType}');
  }
}

class CardDragScope extends InheritedWidget {
  const CardDragScope({
    super.key,
    required this.snapshot,
    required super.child,
  });

  final FutureOr<List<CardDragResource>> Function(CardDragResource source)
  snapshot;

  static CardDragScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CardDragScope>();

  @override
  bool updateShouldNotify(CardDragScope oldWidget) =>
      snapshot != oldWidget.snapshot;
}

/// Owns exactly one native gesture, including internal and external formats.
class CardDragSource extends StatefulWidget {
  const CardDragSource({
    super.key,
    required this.resource,
    required this.child,
    this.enabled = true,
    this.feedbackBuilder,
    this.snapshot,
    this.dragOpacity = .3,
  });

  final CardDragResource Function() resource;
  final Widget child;
  final bool enabled;
  final Widget Function(BuildContext, Widget)? feedbackBuilder;
  final FutureOr<List<CardDragResource>> Function(CardDragResource)? snapshot;
  final double dragOpacity;

  @override
  State<CardDragSource> createState() => _CardDragSourceState();
}

class _CardDragSourceState extends State<CardDragSource> {
  final _dragging = GalleryDragSessionState();
  List<DragItem> _items = const [];
  DragSession? _itemsSession;
  Future<bool> Function()? _prepareFiles;

  @override
  void initState() {
    super.initState();
    _traceCardDrag('source-mounted');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_traceNativeDragContext());
    });
  }

  @override
  void dispose() {
    _traceCardDrag('source-disposed');
    _dragging.dispose();
    super.dispose();
  }

  Future<DragItem?> _start(DragItemRequest request) async {
    _traceCardDrag('item-requested');
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final errorLabel = context.l10n.common_error;
    try {
      return await _prepareSession(request);
    } catch (error, stack) {
      AppLogger.e('Card drag could not start', error, stack, 'CardDrag');
      AppToast.errorOnOverlay(overlay, '$errorLabel: $error');
      return null;
    }
  }

  Future<DragItem?> _prepareSession(DragItemRequest request) async {
    if (!widget.enabled) return null;
    ImageHoverPreviewController.dismissAll();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final errorLabel = context.l10n.common_error;
    final l10n = context.l10n;
    final source = widget.resource();
    final scope = CardDragScope.maybeOf(context);
    final snapshot = List<CardDragResource>.unmodifiable(
      await (scope?.snapshot(source) ??
          widget.snapshot?.call(source) ??
          [source]),
    );
    if (snapshot.isEmpty) return null;
    if (snapshot.map((resource) => resource.id).toSet().length !=
        snapshot.length) {
      throw StateError('Duplicate resource identities in drag snapshot');
    }
    ToastController? preparationToast;
    final preparation = CardDragPreparation(
      snapshot,
      onStarted: () {
        if (overlay?.mounted == true) {
          preparationToast = AppToast.showProgressOnOverlay(
            overlay,
            l10n.cardDrag_preparingCount(snapshot.length),
          );
        }
      },
      onFinished: () => preparationToast?.dismiss(),
    );
    var reportedFailure = false;
    void reportFailure(Object error, StackTrace stack) {
      if (reportedFailure) return;
      reportedFailure = true;
      AppLogger.e('Card drag export failed', error, stack, 'CardDrag');
      AppToast.errorOnOverlay(overlay, '$errorLabel: $error');
    }

    final exports = _createExports(request.session, preparation, reportFailure);
    final items = exports.items;
    _items = items;
    _itemsSession = request.session;
    _prepareFiles = () async {
      _traceCardDrag('file-preparation-started');
      var ready = false;
      try {
        for (final prepare in exports.prepareFiles) {
          if (!await prepare()) return false;
        }
        ready = mounted && request.session.dragCompleted.value == null;
        _traceCardDrag(ready ? 'files-ready' : 'preparation-cancelled');
        return ready;
      } catch (error, stack) {
        _traceCardDrag('file-preparation-failed: ${error.runtimeType}');
        reportFailure(error, stack);
        return false;
      } finally {
        if (!ready) {
          await Future.wait(
            exports.transfers.map((transfer) => transfer.release()),
          );
        }
      }
    };
    _trackSession(request.session, items);
    _traceCardDrag('items-created');
    return items.first;
  }

  ({
    List<DragItem> items,
    List<Future<bool> Function()> prepareFiles,
    List<GalleryDragFile> transfers,
  })
  _createExports(
    DragSession session,
    CardDragPreparation preparation,
    void Function(Object, StackTrace) reportFailure,
  ) {
    final snapshot = preparation.resources;
    final items = <DragItem>[];
    final prepareFiles = <Future<bool> Function()>[];
    final transfers = <GalleryDragFile>[];
    for (var index = 0; index < snapshot.length; index++) {
      final resource = snapshot[index];
      final item = DragItem(
        suggestedName: resource.fileName,
        localData: resource.payload,
      );
      void registered() => _traceCardDrag('item-registered');
      void disposed() {
        _traceCardDrag('item-disposed');
        item.onRegistered.removeListener(registered);
        item.onDisposed.removeListener(disposed);
      }

      item.onRegistered.addListener(registered);
      item.onDisposed.addListener(disposed);
      item.add(cardDragFormat(jsonEncode(resource.payload)));
      final reference = resource.reference;
      if (reference != null) addAgentResourceDragPayload(item, reference);
      final format = resource.format;
      if (format != null && resource.prepare != null) {
        // Synchronous Windows receivers (including QQ) can block in Drop
        // while FileContents waits for our main thread. Materialize the file
        // before entering OLE instead, so GetData never needs a Dart callback.
        if (item.virtualFileSupported &&
            defaultTargetPlatform != TargetPlatform.windows) {
          final resourceIndex = index;
          addCardVirtualFile(
            item,
            format: format,
            prepare: () => preparation.bytesAt(resourceIndex),
            reportFailure: reportFailure,
          );
        } else {
          final resourceIndex = index;
          prepareFiles.add(() async {
            if (session.dragCompleted.value != null) return false;
            final bytes = await preparation.bytesAt(resourceIndex);
            final transfer = GalleryDragFile(item: item, session: session);
            transfers.add(transfer);
            return transfer.addImage(
              SanitizedShareImage(
                bytes: bytes,
                fileName: resource.fileName,
                mimeType: 'application/octet-stream',
              ),
              format: format,
            );
          });
        }
      }
      items.add(item);
    }
    return (items: items, prepareFiles: prepareFiles, transfers: transfers);
  }

  void _trackSession(DragSession session, List<DragItem> items) {
    if (mounted) _dragging.track(session);
    void traceDragging() {
      _traceCardDrag('native-dragging: ${session.dragging.value}');
    }

    session.dragging.addListener(traceDragging);
    void releaseSnapshot() {
      if (session.dragCompleted.value == null) return;
      _traceCardDrag('session-completed: ${session.dragCompleted.value}');
      session.dragging.removeListener(traceDragging);
      session.dragCompleted.removeListener(releaseSnapshot);
      if (identical(_items, items)) {
        _items = const [];
        _itemsSession = null;
        _prepareFiles = null;
      }
    }

    session.dragCompleted.addListener(releaseSnapshot);
  }

  DragConfiguration? _discardConfiguration(DragConfiguration configuration) {
    for (final item in configuration.items) {
      item.image.dispose();
      item.liftImage?.dispose();
    }
    _traceCardDrag('configuration-cancelled');
    return null;
  }

  Widget _feedback(BuildContext context, Widget child) {
    final feedback = widget.feedbackBuilder?.call(context, child) ?? child;
    if (_items.length < 2) return feedback;
    return Stack(
      children: [
        feedback,
        Positioned(top: 8, right: 8, child: Badge.count(count: _items.length)),
      ],
    );
  }

  bool _canDrag() {
    if (!mounted || !widget.enabled) return false;
    final policy = context.interactionPolicy;
    return !policy.prefersTouchPresentation &&
        (policy.precisePointerAvailable ||
            WidgetsBinding.instance.mouseTracker.mouseIsConnected);
  }

  bool _isLocationDraggable(Offset location) {
    final allowed = _canDrag();
    final policy = context.interactionPolicy;
    _traceCardDrag(
      'gesture-gate: allowed=$allowed enabled=${widget.enabled} '
      'modality=${policy.modality} precise=${policy.precisePointerAvailable} '
      'mouse=${WidgetsBinding.instance.mouseTracker.mouseIsConnected}',
    );
    return allowed;
  }

  @override
  Widget build(BuildContext context) {
    return DragItemWidget(
      allowedOperations: () => _canDrag() ? [DropOperation.copy] : [],
      dragItemProvider: _start,
      dragBuilder: _feedback,
      liftBuilder: _feedback,
      child: Listener(
        onPointerDown: (event) =>
            _traceCardDrag('pointer-down: ${event.kind} allowed=${_canDrag()}'),
        onPointerUp: (_) => _traceCardDrag('pointer-up'),
        onPointerCancel: (_) => _traceCardDrag('pointer-cancel'),
        child: DraggableWidget(
          isLocationDraggable: _isLocationDraggable,
          onDragConfiguration: (configuration, session) async {
            _traceCardDrag('feedback-captured');
            if (!identical(_itemsSession, session)) {
              return _discardConfiguration(configuration);
            }
            final items = _items;
            final prepareFiles = _prepareFiles;
            // The plugin has now captured the drag image. Exporting earlier can
            // rebuild its feedback boundary before it has a painted layer.
            // Finish all files here, before the plugin checks cancellation and
            // registers the data for the native drag loop.
            if (prepareFiles == null || !await prepareFiles()) {
              return _discardConfiguration(configuration);
            }
            if (!mounted || session.dragCompleted.value != null) {
              return _discardConfiguration(configuration);
            }
            final first = configuration.items.first;
            return DragConfiguration(
              allowedOperations: configuration.allowedOperations,
              options: configuration.options,
              items: [
                first,
                for (final item in items.skip(1))
                  DragConfigurationItem(
                    item: item,
                    image: first.image.retain(),
                    liftImage: first.liftImage?.retain(),
                  ),
              ],
            );
          },
          child: ValueListenableBuilder<bool>(
            valueListenable: _dragging,
            child: widget.child,
            builder: (context, dragging, child) => Opacity(
              opacity: dragging ? widget.dragOpacity : 1,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
