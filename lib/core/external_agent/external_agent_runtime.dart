import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../agent/agent_types.dart';
import '../agent/validate_tool_arguments.dart';
import 'external_agent_models.dart';
import 'external_billing_scope.dart';

class ExternalAgentOperation {
  const ExternalAgentOperation(
    this.tool, {
    required this.readOnly,
    this.longRunning = false,
    this.concurrentControl = false,
    this.estimate,
  });
  final AgentTool tool;
  final bool readOnly, longRunning;
  final bool concurrentControl;
  final Future<int?> Function(Map<String, dynamic>)? estimate;
  Map<String, dynamic> toJson() => {
    'name': tool.name,
    'description': tool.description,
    'inputSchema': tool.parameters,
    'read_only': readOnly,
    'long_running': longRunning,
    'may_charge': estimate != null,
  };
}

/// Application-level dispatch shared by HTTP and MCP; no chat session is involved.
class ExternalAgentRuntime {
  ExternalAgentRuntime({
    required this.directory,
    required this.readConfig,
    required this.saveSpent,
    required this.estimateRequest,
    required this.operations,
    required this.onChanged,
    required this.adoptResult,
  });
  final Directory directory;
  final ExternalAgentConfig Function() readConfig;
  final Future<void> Function(int) saveSpent;
  final Future<int?> Function(String, Map<String, dynamic>) estimateRequest;
  final Future<Map<String, dynamic>> Function(AgentToolResult) adoptResult;
  final List<ExternalAgentOperation> operations;
  final void Function() onChanged;
  final Map<String, ExternalAgentJob> jobs = {};
  final Map<String, AbortController> _controllers = {};
  final Map<String, Completer<bool>> _approvals = {};
  final Map<String, int> _reservations = {};
  final Set<String> _approvedUnknownFirstRequest = {};
  final Map<String, Future<void>> _running = {};
  Future<void> _persistTail = Future.value(), _budgetTail = Future.value();
  Future<void> _writeTail = Future.value();
  bool accepting = true;
  int get reserved => _reservations.values.fold(0, (a, b) => a + b);
  List<Map<String, dynamic>> get toolList =>
      operations.map((o) => o.toJson()).toList();
  Future<void> initialize() async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/calls.json');
    if (await file.exists()) {
      final data = jsonDecode(await file.readAsString()) as List;
      for (final item in data) {
        final job = ExternalAgentJob.fromJson(
          Map<String, dynamic>.from(item as Map),
        );
        jobs[job.id] = job;
      }
    }
  }

  Future<void> _persist() {
    // Snapshot before queuing; writes are serialized and replaced atomically.
    final data = jsonEncode(jobs.values.map((j) => j.toJson()).toList());
    final next = _persistTail.catchError((Object _) {}).then((_) async {
      final temporary = File('${directory.path}/calls.tmp');
      await temporary.writeAsString(data, flush: true);
      await temporary.rename('${directory.path}/calls.json');
    });
    _persistTail = next;
    return next;
  }

  Future<T> _budgetLock<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _budgetTail = _budgetTail.catchError((Object _) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<void> resetSpent() => _budgetLock(() async {
    if (reserved > 0) {
      throw StateError('Cannot reset usage while chargeable tasks are active.');
    }
    await saveSpent(0);
    onChanged();
  });

  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> arguments, {
    String? requestId,
  }) async {
    if (!accepting) {
      throw const ExternalAgentException(
        'disabled',
        'External Agent is disabled.',
      );
    }
    final operation = operations.where((o) => o.tool.name == name).firstOrNull;
    if (operation == null) {
      throw const ExternalAgentException(
        'unknown_tool',
        'This operation is unavailable or prohibited.',
      );
    }
    final args = validateToolArguments(
      operation.tool,
      ToolCallContent(id: 'validation', name: name, arguments: arguments),
    );
    if (!operation.readOnly &&
        (requestId == null || requestId.trim().isEmpty)) {
      throw const ExternalAgentException(
        'request_id_required',
        'Writes require a stable request_id.',
      );
    }
    final candidate = ExternalAgentJob(
      id: const Uuid().v4(),
      tool: name,
      arguments: args,
      requestId: requestId,
    );
    if (requestId != null) {
      final old = jobs.values
          .where((j) => j.requestId == requestId)
          .firstOrNull;
      if (old != null) {
        if (old.fingerprint != candidate.fingerprint) {
          throw const ExternalAgentException(
            'request_id_conflict',
            'request_id was used with different arguments.',
          );
        }
        return old.toJson();
      }
    }
    jobs[candidate.id] = candidate;
    final controller = AbortController();
    _controllers[candidate.id] = controller;
    try {
      await _persist();
    } catch (e) {
      jobs.remove(candidate.id);
      _controllers.remove(candidate.id);
      rethrow;
    }
    final Future<void> future;
    if (!operation.readOnly && !operation.concurrentControl) {
      future = _writeTail
          .catchError((Object _) {})
          .then((_) => _execute(candidate, operation, controller));
      _writeTail = future;
    } else {
      future = _execute(candidate, operation, controller);
    }
    _running[candidate.id] = future;
    unawaited(future.whenComplete(() => _running.remove(candidate.id)));
    if (operation.longRunning || !operation.readOnly) {
      // Immediate reads return their result; writes always have a reviewable job.
      if (!operation.longRunning) {
        await Future.any([
          future,
          Future<void>.delayed(const Duration(milliseconds: 50)),
        ]);
      }
      return candidate.toJson();
    }
    await future;
    return candidate.toJson();
  }

  Future<bool> _approve(
    ExternalAgentJob job,
    String reason, {
    int? cost,
  }) async {
    final controller = _controllers[job.id]!;
    throwIfAborted(controller.signal);
    job.status = ExternalJobStatus.awaitingApproval;
    job.approvalReason = reason;
    job.estimatedAnlas = cost;
    final pending = Completer<bool>();
    _approvals[job.id] = pending;
    try {
      await _persist();
      onChanged();
      return await pending.future;
    } finally {
      _approvals.remove(job.id);
      job.approvalReason = null;
    }
  }

  void resolveApproval(String id, bool approved) {
    final approval = _approvals[id];
    if (approval != null && !approval.isCompleted) approval.complete(approved);
  }

  Future<void> _authorize(
    ExternalAgentJob job,
    ExternalAgentOperation operation,
  ) async {
    final estimated = operation.estimate == null
        ? 0
        : await operation.estimate!(job.arguments);
    final cost = estimated != null && estimated >= 0 ? estimated : null;
    job.estimatedAnlas = cost;
    final config = readConfig();
    var allowed =
        config.mode == ExternalAgentMode.full ||
        (operation.readOnly && cost == 0);
    if (config.mode == ExternalAgentMode.automatic && cost != null) {
      allowed = await _budgetLock(() async {
        final latest = readConfig();
        if (cost > 0 && latest.spent + reserved + cost > latest.budget) {
          return false;
        }
        _reservations[job.id] = cost;
        return true;
      });
    }
    if (!allowed &&
        !await _approve(
          job,
          cost == null
              ? 'unknown_cost'
              : cost > 0
              ? 'charge'
              : 'write',
          cost: cost,
        )) {
      throw const ExternalAgentException('rejected', 'Operation was rejected.');
    }
    // Explicit approval reserves known batch cost too, preventing concurrent auto calls using it.
    if (cost != null && cost > 0 && !_reservations.containsKey(job.id)) {
      _reservations[job.id] = cost;
    }
    if (cost == null && config.mode != ExternalAgentMode.full) {
      _approvedUnknownFirstRequest.add(job.id);
    }
  }

  Future<void> _beforeRequest(
    ExternalAgentJob job,
    String kind,
    Map<String, dynamic> parameters,
  ) async {
    final signal = _controllers[job.id]!.signal;
    throwIfAborted(signal);
    final cost = await estimateRequest(kind, parameters);
    final explicitlyApproved = _approvedUnknownFirstRequest.remove(job.id);
    var approved =
        readConfig().mode == ExternalAgentMode.full || explicitlyApproved;
    if (cost != null && cost >= 0) {
      approved = await _budgetLock(() async {
        final available = _reservations[job.id] ?? 0;
        final config = readConfig();
        if (explicitlyApproved ||
            available >= cost ||
            config.mode == ExternalAgentMode.full ||
            (config.mode == ExternalAgentMode.automatic &&
                config.spent + reserved + cost <= config.budget)) {
          await saveSpent(config.spent + cost);
          _reservations[job.id] = (available - cost).clamp(0, 1 << 30);
          job.dispatchedAnlas += cost;
          await _persist();
          return true;
        }
        return false;
      });
    }
    if (!approved) {
      if (!await _approve(job, 'charge', cost: cost)) {
        throw const ExternalAgentException('rejected', 'Charge was rejected.');
      }
      throwIfAborted(signal);
      if (cost != null && cost >= 0) {
        await _budgetLock(() async {
          await saveSpent(readConfig().spent + cost);
          job.dispatchedAnlas += cost;
          await _persist();
        });
      }
    }
    throwIfAborted(signal);
    job.status = ExternalJobStatus.running;
    onChanged();
  }

  Future<void> _execute(
    ExternalAgentJob job,
    ExternalAgentOperation operation,
    AbortController controller,
  ) async {
    try {
      throwIfAborted(controller.signal);
      await _authorize(job, operation);
      throwIfAborted(controller.signal);
      job.status = ExternalJobStatus.running;
      onChanged();
      final args = Map<String, dynamic>.of(job.arguments);
      // These flags express submission intent; policy authorization happened above.
      if (operation.tool.parameters['properties'] is Map) {
        final properties = operation.tool.parameters['properties'] as Map;
        if (properties.containsKey('confirmed')) args['confirmed'] = true;
        if (properties.containsKey('confirm')) args['confirm'] = true;
      }
      final result =
          await ExternalBillingScope(
            signal: controller.signal,
            beforeRequest: (kind, p) => _beforeRequest(job, kind, p),
          ).run(
            () => operation.tool.execute(job.id, args, controller.signal, (
              update,
            ) {
              job.progress = {
                'content': [
                  for (final item in update.content)
                    if (item is ToolResultTextContent) item.text,
                ],
              };
              onChanged();
            }),
          );
      job.result = await adoptResult(result);
      throwIfAborted(controller.signal);
      final failed = result.isError || job.result?['is_error'] == true;
      job.status = failed
          ? ExternalJobStatus.failed
          : ExternalJobStatus.completed;
      if (failed) {
        final detail = jsonEncode(job.result);
        job.error = detail.length > 500
            ? '${detail.substring(0, 500)}…'
            : detail;
      }
    } catch (e) {
      job.status = controller.signal.aborted
          ? ExternalJobStatus.cancelled
          : ExternalJobStatus.failed;
      job.error = e.toString();
    } finally {
      _reservations.remove(job.id);
      _approvedUnknownFirstRequest.remove(job.id);
      _controllers.remove(job.id);
      job.finishedAt = DateTime.now();
      try {
        await _persist();
      } catch (e) {
        job.status = ExternalJobStatus.failed;
        job.error = 'Could not persist result: $e';
      }
      onChanged();
    }
  }

  Future<void> cancel(String id) async {
    final job = jobs[id];
    if (job == null) {
      throw const ExternalAgentException('not_found', 'Unknown job.');
    }
    if (job.terminal) return;
    job.cancelRequested = true;
    _controllers[id]?.abort('External operation cancelled');
    resolveApproval(id, false);
    onChanged();
    if (job.status == ExternalJobStatus.pending) {
      job.status = ExternalJobStatus.cancelled;
      job.finishedAt = DateTime.now();
      await _persist();
      onChanged();
    }
  }

  Future<void> shutdown() async {
    accepting = false;
    for (final id in _controllers.keys.toList()) {
      await cancel(id);
    }
    await Future.wait(
      _running.values.toList(),
    ).timeout(const Duration(seconds: 5), onTimeout: () => []);
    await _persistTail;
  }
}
