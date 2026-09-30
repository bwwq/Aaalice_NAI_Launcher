import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nai_launcher/core/agent/agent_types.dart';
import 'package:nai_launcher/core/external_agent/external_agent_models.dart';
import 'package:nai_launcher/core/external_agent/external_agent_runtime.dart';
import 'package:nai_launcher/core/external_agent/external_agent_server.dart';
import 'package:nai_launcher/core/external_agent/external_billing_scope.dart';
import 'package:nai_launcher/presentation/agent_chat/services/defined_agent_tool.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;

// Pure Dart regression entry point: no Flutter engine, account or paid network.
final externalAgentChecks = <String, Future<void> Function()>{
  'defaults and explicit LAN binding': _defaults,
  'ask permissions and rejection': _ask,
  'automatic cumulative budget and unknown charge': _budget,
  'full control and forbidden operations': _full,
  'shared FIFO queue, immediate reads and controls': _queue,
  'queue billing survives detached callbacks and resume': _queueBilling,
  'write request deduplication and argument conflicts': _deduplication,
  'cancellation and retained partial results': _cancel,
  'restart does not replay accepted requests': _restart,
  'spending persistence failure blocks dispatch': _storageFailure,
  'unknown-cost approval is applied once to the first request':
      _unknownApproval,
  'HTTP and MCP discovery, execution, polling and image read': _protocol,
};

Future<void> main() async {
  for (final entry in externalAgentChecks.entries) {
    await entry.value();
    stdout.writeln('PASS ${entry.key}');
  }
  stdout.writeln(
    '${externalAgentChecks.length} external Agent checks passed (mock billing).',
  );
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

AgentToolResult _result([Object value = const {'ok': true}]) => AgentToolResult(
  content: [ToolResultTextContent(jsonEncode(value))],
  details: const {},
);
ExternalAgentOperation _operation(
  String name,
  Future<AgentToolResult> Function(Map<String, dynamic>, AbortSignal?) run, {
  bool read = false,
  bool long = false,
  bool control = false,
  Future<int?> Function(Map<String, dynamic>)? estimate,
}) => ExternalAgentOperation(
  DefinedAgentTool(
    name: name,
    label: name,
    description: 'Regression operation.',
    parameters: const {
      'type': 'object',
      'properties': {
        'value': {'type': 'integer'},
      },
      'additionalProperties': false,
    },
    executeWithControl: (_, args, signal, update) => run(args, signal),
  ),
  readOnly: read,
  longRunning: long,
  concurrentControl: control,
  estimate: estimate,
);

class _Fixture {
  _Fixture(this.directory, this.operations);
  final Directory directory;
  final List<ExternalAgentOperation> operations;
  ExternalAgentConfig config = const ExternalAgentConfig(
    mode: ExternalAgentMode.full,
  );
  bool failSpent = false;
  int updates = 0;
  late ExternalAgentRuntime runtime;
  Future<void> initialize() async {
    runtime = newRuntime();
    await runtime.initialize();
  }

  ExternalAgentRuntime newRuntime() => ExternalAgentRuntime(
    directory: directory,
    readConfig: () => config,
    saveSpent: (value) async {
      if (failSpent) {
        throw const FileSystemException('Mock persistence failure');
      }
      config = config.copyWith(spent: value);
    },
    estimateRequest: (_, args) async => args['cost'] as int?,
    operations: operations,
    onChanged: () => updates++,
    adoptResult: (result) async => {
      'content': [
        for (final content in result.content)
          if (content is ToolResultTextContent) jsonDecode(content.text),
      ],
    },
  );
  Future<ExternalAgentJob> call(
    String tool, {
    String? id,
    Map<String, dynamic> args = const {},
  }) async {
    final result = await runtime.call(tool, args, requestId: id);
    return runtime.jobs[result['job_id']]!;
  }

  Future<void> close() async {
    await runtime.shutdown();
    final allowed = Directory('tool/.tmp').absolute.path;
    _check(
      p.isWithin(p.normalize(allowed), p.normalize(directory.absolute.path)),
      'Unsafe test cleanup path.',
    );
    await directory.delete(recursive: true);
  }
}

Future<_Fixture> _fixture(List<ExternalAgentOperation> operations) async {
  final directory = Directory(
    'tool/.tmp/external-agent-check-${const Uuid().v4()}',
  );
  final fixture = _Fixture(directory, operations);
  await fixture.initialize();
  return fixture;
}

Future<void> _until(
  bool Function() predicate, {
  String message = 'Timed out waiting for job.',
}) async {
  final elapsed = Stopwatch()..start();
  while (!predicate()) {
    if (elapsed.elapsed > const Duration(seconds: 10)) {
      throw StateError(message);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _defaults() async {
  const defaults = ExternalAgentConfig();
  _check(
    !defaults.enabled && !defaults.allowLan && !defaults.builtInEnabled,
    'Features must be opt-in.',
  );
  _check(
    defaults.bindAddress == '127.0.0.1' &&
        defaults.mode == ExternalAgentMode.ask &&
        defaults.budget == 0,
    'Unexpected defaults.',
  );
  final copy = ExternalAgentConfig.fromJson(
    defaults.copyWith(allowLan: true).toJson(),
  );
  _check(copy.bindAddress == '0.0.0.0', 'LAN setting did not round-trip.');
}

Future<void> _ask() async {
  var writes = 0;
  final f = await _fixture([
    _operation('read', (_, __) async => _result(), read: true),
    _operation('write', (_, __) async {
      writes++;
      return _result();
    }),
  ]);
  f.config = f.config.copyWith(mode: ExternalAgentMode.ask);
  try {
    _check(
      (await f.call('read')).status == ExternalJobStatus.completed,
      'Reads need no approval.',
    );
    final rejected = await f.call('write', id: 'reject');
    await _until(() => rejected.status == ExternalJobStatus.awaitingApproval);
    _check(writes == 0, 'Write ran before approval.');
    f.runtime.resolveApproval(rejected.id, false);
    await _until(() => rejected.terminal);
    _check(
      rejected.status == ExternalJobStatus.failed && writes == 0,
      'Rejected write executed.',
    );
    final approved = await f.call('write', id: 'approve');
    await _until(() => approved.status == ExternalJobStatus.awaitingApproval);
    f.runtime.resolveApproval(approved.id, true);
    await _until(() => approved.terminal);
    _check(writes == 1, 'Approved write did not run once.');
  } finally {
    await f.close();
  }
}

Future<void> _budget() async {
  var dispatches = 0;
  final f = await _fixture([
    _operation(
      'charged',
      (_, __) async {
        await ExternalBillingScope.check('generate', {'cost': 4});
        dispatches++;
        return _result();
      },
      long: true,
      estimate: (_) async => 4,
    ),
    _operation(
      'unknown',
      (_, __) async {
        await ExternalBillingScope.check('annotate', {});
        dispatches++;
        return _result();
      },
      long: true,
      estimate: (_) async => null,
    ),
  ]);
  f.config = f.config.copyWith(mode: ExternalAgentMode.automatic, budget: 6);
  try {
    final jobs = await Future.wait([
      f.call('charged', id: 'one'),
      f.call('charged', id: 'two'),
    ]);
    await _until(
      () =>
          jobs.first.terminal &&
          jobs.last.status == ExternalJobStatus.awaitingApproval,
    );
    _check(
      dispatches == 1 && f.config.spent == 4,
      'Concurrent requests bypassed cumulative budget.',
    );
    await f.runtime.cancel(jobs.last.id);
    await _until(() => jobs.last.terminal);
    final unknown = await f.call('unknown', id: 'unknown');
    await _until(() => unknown.status == ExternalJobStatus.awaitingApproval);
    _check(dispatches == 1, 'Unknown-cost request ran automatically.');
    await f.runtime.cancel(unknown.id);
    await _until(() => unknown.terminal);
    _check(f.runtime.reserved == 0, 'Cancelled jobs leaked reservations.');
  } finally {
    await f.close();
  }
}

Future<void> _full() async {
  var calls = 0;
  final f = await _fixture([
    _operation(
      'allowed',
      (_, __) async {
        await ExternalBillingScope.check('unknown', {});
        calls++;
        return _result();
      },
      long: true,
      estimate: (_) async => null,
    ),
  ]);
  try {
    final job = await f.call('allowed', id: 'full');
    await _until(() => job.terminal);
    _check(
      job.status == ExternalJobStatus.completed && calls == 1,
      'Full control did not execute allowed operation.',
    );
    for (final forbidden in [
      'delete_backup',
      'restore_backup',
      'read_account_key',
      'set_external_agent_permissions',
      'clear_data',
    ]) {
      try {
        await f.call(forbidden, id: forbidden);
        throw StateError('Prohibited operation registered.');
      } on ExternalAgentException catch (e) {
        _check(e.code == 'unknown_tool', 'Wrong prohibited-operation error.');
      }
    }
  } finally {
    await f.close();
  }
}

Future<void> _queue() async {
  final release = Completer<void>(), events = <String>[];
  final f = await _fixture([
    _operation('slow', (_, __) async {
      events.add('start');
      await release.future;
      events.add('end');
      return _result();
    }, long: true),
    _operation('later', (_, __) async {
      events.add('later');
      return _result();
    }),
    _operation('read', (_, __) async => _result(), read: true),
    _operation('control', (_, __) async {
      events.add('control');
      return _result();
    }, control: true),
  ]);
  try {
    final first = await f.call('slow', id: 'first');
    await _until(() => first.status == ExternalJobStatus.running);
    final previousUpdates = f.updates;
    final second = await f.call('later', id: 'second');
    _check(
      f.updates > previousUpdates,
      'Queued job did not notify the settings listener.',
    );
    _check(
      second.status == ExternalJobStatus.pending,
      'Concurrent writer did not queue.',
    );
    _check(
      (await f.call('read')).terminal,
      'Read was blocked by a long write.',
    );
    final control = await f.call('control', id: 'control');
    await _until(() => control.terminal);
    _check(
      events.join(',') == 'start,control',
      'Control was blocked by long write.',
    );
    release.complete();
    await _until(() => second.terminal);
    _check(
      events.join(',') == 'start,control,end,later',
      'Writers did not run FIFO.',
    );
  } finally {
    if (!release.isCompleted) release.complete();
    await f.close();
  }
}

Future<void> _queueBilling() async {
  var dispatches = 0;
  final f = await _fixture([
    _operation(
      'queued',
      (_, __) async {
        ExternalBillingScope.bindQueueTasks(['queued-task']);
        await Zone.root.run(
          () => ExternalBillingScope.runQueueTask('queued-task', () async {
            await ExternalBillingScope.check('generate', {'cost': 3});
            dispatches++;
          }),
        );
        return _result();
      },
      long: true,
      estimate: (_) async => 3,
    ),
  ]);
  f.config = f.config.copyWith(mode: ExternalAgentMode.automatic, budget: 3);
  try {
    final job = await f.call('queued', id: 'queued');
    await _until(() => job.terminal);
    _check(
      job.status == ExternalJobStatus.completed &&
          dispatches == 1 &&
          f.config.spent == 3,
      'Queue lost its billing scope when resumed outside its original Zone.',
    );
    _check(
      !ExternalBillingScope.hasQueueOwner,
      'Completed queue retained a stale billing owner.',
    );
  } finally {
    await f.close();
  }
}

Future<void> _deduplication() async {
  var calls = 0;
  final f = await _fixture([
    _operation('write', (_, __) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return _result();
    }, long: true),
  ]);
  try {
    final jobs = await Future.wait([
      f.call('write', id: 'same', args: {'value': 1}),
      f.call('write', id: 'same', args: {'value': 1}),
    ]);
    _check(
      identical(jobs[0], jobs[1]),
      'Same request ID created multiple jobs.',
    );
    await _until(() => jobs.first.terminal);
    _check(calls == 1, 'Retry repeated the operation.');
    try {
      await f.call('write', id: 'same', args: {'value': 2});
      throw StateError('Conflicting retry accepted.');
    } on ExternalAgentException catch (e) {
      _check(e.code == 'request_id_conflict', 'Wrong conflict error.');
    }
  } finally {
    await f.close();
  }
}

Future<void> _cancel() async {
  final release = Completer<void>();
  var laterCalls = 0;
  final f = await _fixture([
    _operation('slow', (_, __) async {
      await release.future;
      return _result({'saved': 'partial'});
    }, long: true),
    _operation('later', (_, __) async {
      laterCalls++;
      return _result();
    }),
  ]);
  try {
    final first = await f.call('slow', id: 'first');
    await _until(() => first.status == ExternalJobStatus.running);
    final later = await f.call('later', id: 'later');
    await f.runtime.cancel(later.id);
    _check(
      later.status == ExternalJobStatus.cancelled,
      'Queued cancellation did not become terminal.',
    );
    await f.runtime.cancel(first.id);
    release.complete();
    await _until(() => first.terminal);
    _check(
      first.status == ExternalJobStatus.cancelled && first.result != null,
      'Cancellation reported success or lost completed partial result.',
    );
    await _until(() => f.runtime.jobs.values.every((j) => j.terminal));
    _check(laterCalls == 0, 'Cancelled queued write executed.');
  } finally {
    if (!release.isCompleted) release.complete();
    await f.close();
  }
}

Future<void> _restart() async {
  final release = Completer<void>();
  var calls = 0;
  final f = await _fixture([
    _operation('write', (_, __) async {
      calls++;
      await release.future;
      return _result();
    }, long: true),
  ]);
  try {
    final first = await f.call('write', id: 'persisted');
    await _until(() => first.status == ExternalJobStatus.running);
    final restarted = f.newRuntime();
    await restarted.initialize();
    final response = await restarted.call('write', {}, requestId: 'persisted');
    _check(
      response['status'] == 'interrupted' && calls == 1,
      'Restart replayed an accepted request.',
    );
    release.complete();
    await _until(() => first.terminal);
    await restarted.shutdown();
  } finally {
    if (!release.isCompleted) release.complete();
    await f.close();
  }
}

Future<void> _storageFailure() async {
  var dispatches = 0;
  final f = await _fixture([
    _operation(
      'charged',
      (_, __) async {
        await ExternalBillingScope.check('generate', {'cost': 2});
        dispatches++;
        return _result();
      },
      long: true,
      estimate: (_) async => 2,
    ),
  ]);
  f.config = f.config.copyWith(mode: ExternalAgentMode.automatic, budget: 10);
  f.failSpent = true;
  try {
    final job = await f.call('charged', id: 'fail');
    await _until(() => job.terminal);
    _check(
      job.status == ExternalJobStatus.failed && dispatches == 0,
      'Dispatch proceeded after spending persistence failed.',
    );
  } finally {
    await f.close();
  }
}

Future<void> _unknownApproval() async {
  var calls = 0;
  final f = await _fixture([
    _operation(
      'unknown',
      (_, __) async {
        await ExternalBillingScope.check('generate', {'cost': 2});
        calls++;
        return _result();
      },
      long: true,
      estimate: (_) async => -3,
    ),
  ]);
  f.config = f.config.copyWith(mode: ExternalAgentMode.automatic, budget: 0);
  try {
    final job = await f.call('unknown', id: 'unknown');
    await _until(() => job.status == ExternalJobStatus.awaitingApproval);
    _check(
      calls == 0 && f.runtime.reserved >= 0,
      'Invalid estimates became negative quota reservations.',
    );
    f.runtime.resolveApproval(job.id, true);
    await _until(() => job.terminal);
    _check(
      calls == 1 && f.config.spent == 2,
      'Approved unknown request asked twice or escaped accounting.',
    );
  } finally {
    await f.close();
  }
}

Future<void> _protocol() async {
  final f = await _fixture([
    _operation(
      'generate',
      (_, __) async => _result({'path': 'mock-image.png'}),
      long: true,
    ),
  ]);
  final image = File('${f.directory.path}/mock.png');
  await image.writeAsBytes([137, 80, 78, 71]);
  final server = ExternalAgentServer(
    f.runtime,
    readResource: (id) async => id == 'mock' ? image : null,
  );
  final client = HttpClient();
  try {
    await server.start(const ExternalAgentConfig(enabled: true, port: 0));
    _check(server.bindAddress == '127.0.0.1', 'Default server exposed LAN.');
    final base = 'http://127.0.0.1:${server.port}';
    Future<({int status, Map<String, dynamic> body, String? session})> request(
      String path, {
      Map<String, dynamic>? body,
      String? session,
      String? origin,
    }) async {
      final req = await client.openUrl(
        body == null ? 'GET' : 'POST',
        Uri.parse('$base$path'),
      );
      if (session != null) req.headers.set('Mcp-Session-Id', session);
      if (origin != null) req.headers.set('Origin', origin);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final response = await req.close();
      final text = await utf8.decoder.bind(response).join();
      return (
        status: response.statusCode,
        body: text.isEmpty
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(jsonDecode(text) as Map),
        session: response.headers.value('Mcp-Session-Id'),
      );
    }

    _check(
      (await request('/api/v1/tools')).body['tools'] is List,
      'Tool discovery failed without a token.',
    );
    _check(
      (await request(
            '/api/v1/status',
            origin: 'http://untrusted.example',
          )).status ==
          403,
      'Invalid browser origin accepted.',
    );
    final initialized = await request(
      '/mcp',
      body: {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-11-25'},
      },
    );
    _check(initialized.session != null, 'MCP session missing.');
    final tools = await request(
      '/mcp',
      session: initialized.session,
      body: {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
    );
    _check(
      (tools.body['result']['tools'] as List).any(
        (t) => t['name'] == 'generate',
      ),
      'MCP tools unavailable.',
    );
    final called = await request(
      '/mcp',
      session: initialized.session,
      body: {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {
          'name': 'generate',
          'arguments': {'request_id': 'generation'},
        },
      },
    );
    final id = called.body['result']['structuredContent']['job_id'] as String;
    await _until(() => f.runtime.jobs[id]!.terminal);
    final polled = await request('/api/v1/jobs/$id');
    _check(polled.body['result'] != null, 'Task result unavailable.');
    final imageResponse = await client
        .getUrl(Uri.parse('$base/api/v1/resources/mock'))
        .then((r) => r.close());
    final bytes = await imageResponse.fold<List<int>>(
      [],
      (all, chunk) => all..addAll(chunk),
    );
    _check(bytes.length == 4, 'Image resource read failed.');
    await server.stop();
    _check(!f.runtime.accepting, 'Stopped server still accepted calls.');
    await server.start(
      const ExternalAgentConfig(enabled: true, allowLan: true, port: 0),
    );
    _check(server.bindAddress == '0.0.0.0', 'Explicit LAN option was ignored.');
  } finally {
    client.close(force: true);
    await server.stop();
    await f.close();
  }
}
