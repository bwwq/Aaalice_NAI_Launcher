import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'external_agent_models.dart';
import 'external_agent_runtime.dart';

class ExternalAgentServer {
  ExternalAgentServer(this.runtime, {required this.readResource});
  final ExternalAgentRuntime runtime;
  final Future<File?> Function(String) readResource;
  HttpServer? _server;
  final Set<String> _hosts = {'localhost', '127.0.0.1', '::1'};
  final Set<String> _sessions = {};
  final Map<String, String> _sessionVersions = {};
  List<String> lanAddresses = [];
  bool get listening => _server != null;
  int? get port => _server?.port;
  String? get bindAddress => _server?.address.address;
  Future<void> start(ExternalAgentConfig config) async {
    await stop();
    _hosts
      ..clear()
      ..addAll({'localhost', '127.0.0.1', '::1'});
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    lanAddresses = interfaces
        .expand((i) => i.addresses)
        .where((a) => !a.isLoopback)
        .map((a) => a.address)
        .toSet()
        .toList();
    _hosts.addAll(config.allowLan ? lanAddresses : const []);
    final server = await HttpServer.bind(
      config.bindAddress,
      config.port,
      shared: false,
    );
    _server = server;
    runtime.accepting = true;
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object _) {},
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    runtime.accepting = false;
    _sessions.clear();
    _sessionVersions.clear();
    if (server != null) await server.close(force: true);
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    const maximum = 16 * 1024 * 1024;
    var size = 0;
    final bytes = <int>[];
    await for (final chunk in request) {
      size += chunk.length;
      if (size > maximum) {
        throw const ExternalAgentException(
          'request_too_large',
          'Use an image file path for large inputs.',
        );
      }
      bytes.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) throw const FormatException('Expected a JSON object.');
    return Map<String, dynamic>.from(decoded);
  }

  bool _validOrigin(HttpRequest request) {
    if (!_hosts.contains(request.requestedUri.host)) return false;
    final origin = request.headers.value('origin');
    if (origin == null) return true;
    final uri = Uri.tryParse(origin);
    return uri != null &&
        uri.scheme == 'http' &&
        _hosts.contains(uri.host) &&
        uri.port == _server?.port;
  }

  Future<void> _json(
    HttpRequest request,
    Object body, {
    int status = 200,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (!listening || !_validOrigin(request)) {
        await _json(request, {'error': 'invalid_origin_or_host'}, status: 403);
        return;
      }
      if (request.uri.path == '/mcp') {
        await _mcp(request);
        return;
      }
      await _http(request);
    } on ExternalAgentException catch (e) {
      await _json(request, {
        'error': {'code': e.code, 'message': e.message},
      }, status: e.code == 'request_id_conflict' ? 409 : 400);
    } on FormatException catch (e) {
      await _json(request, {
        'error': {'code': 'invalid_arguments', 'message': e.message},
      }, status: 400);
    } catch (e) {
      try {
        await _json(request, {
          'error': {'code': 'operation_failed', 'message': e.toString()},
        }, status: 500);
      } catch (_) {}
    }
  }

  Future<void> _http(HttpRequest request) async {
    final path = request.uri.path, method = request.method;
    if (method == 'GET' && path == '/api/v1/status') {
      await _json(request, {
        'enabled': runtime.accepting,
        'version': 1,
        'active_jobs': runtime.jobs.values.where((j) => !j.terminal).length,
      });
      return;
    }
    if (method == 'GET' && path == '/api/v1/tools') {
      await _json(request, {'tools': runtime.toolList});
      return;
    }
    if (method == 'POST' && path == '/api/v1/call') {
      final body = await _body(request);
      final result = await runtime.call(
        body['tool'] as String,
        Map<String, dynamic>.from(body['arguments'] as Map? ?? {}),
        requestId:
            body['request_id'] as String? ??
            request.headers.value('Idempotency-Key'),
      );
      final terminal = const {
        'failed',
        'cancelled',
        'interrupted',
      }.contains(result['status']);
      await _json(
        request,
        result,
        status: result['status'] == 'completed'
            ? 200
            : terminal
            ? 409
            : 202,
      );
      return;
    }
    if (method == 'GET' && path == '/api/v1/jobs') {
      await _json(request, {
        'jobs': runtime.jobs.values
            .toList()
            .reversed
            .take(100)
            .map((j) => j.toJson())
            .toList(),
      });
      return;
    }
    final segments = request.uri.pathSegments;
    if (segments.length >= 4 && segments.take(3).join('/') == 'api/v1/jobs') {
      final job = runtime.jobs[segments[3]];
      if (job == null) {
        await _json(request, {'error': 'not_found'}, status: 404);
        return;
      }
      if (method == 'POST' && segments.length == 5 && segments[4] == 'cancel') {
        await runtime.cancel(job.id);
      } else if (method != 'GET' || segments.length != 4) {
        await _json(request, {'error': 'method_not_allowed'}, status: 405);
        return;
      }
      await _json(request, job.toJson());
      return;
    }
    if (method == 'GET' &&
        segments.length == 4 &&
        segments.take(3).join('/') == 'api/v1/resources') {
      final file = await readResource(segments[3]);
      if (file == null || !await file.exists()) {
        await _json(request, {'error': 'not_found'}, status: 404);
        return;
      }
      request.response.headers.contentType = ContentType('image', 'png');
      await request.response.addStream(file.openRead());
      await request.response.close();
      return;
    }
    await _json(request, {'error': 'not_found'}, status: 404);
  }

  Future<void> _mcp(HttpRequest request) async {
    if (request.method == 'GET') {
      await _json(request, {'error': 'SSE stream not offered.'}, status: 405);
      return;
    }
    if (request.method == 'DELETE') {
      final session = request.headers.value('Mcp-Session-Id');
      _sessions.remove(session);
      _sessionVersions.remove(session);
      request.response.statusCode = 204;
      await request.response.close();
      return;
    }
    if (request.method != 'POST') {
      await _json(request, {'error': 'method_not_allowed'}, status: 405);
      return;
    }
    final body = await _body(request), id = body['id'], method = body['method'];
    final params = Map<String, dynamic>.from(body['params'] as Map? ?? {});
    if (method == 'initialize') {
      final version = params['protocolVersion'] == '2025-06-18'
          ? '2025-06-18'
          : '2025-11-25';
      final session =
          'mcp-${DateTime.now().microsecondsSinceEpoch}-${_sessions.length}';
      _sessions.add(session);
      _sessionVersions[session] = version;
      request.response.headers.set('Mcp-Session-Id', session);
      await _json(request, {
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'protocolVersion': version,
          'capabilities': {'tools': {}, 'resources': {}},
          'serverInfo': {'name': 'aaalice-launcher', 'version': '1.0.0'},
          'instructions':
              'Operate the launcher using tools. Writes require request_id for safe retries. Long calls return job_id: poll get_external_job and read result paths/resources. Approvals are handled in application settings. Account secrets, destructive backup operations and permission changes are prohibited.',
        },
      });
      return;
    }
    final session = request.headers.value('Mcp-Session-Id');
    if (!_sessions.contains(session)) {
      await _json(request, {'error': 'invalid_session'}, status: 404);
      return;
    }
    if (id == null) {
      request.response.statusCode = 202;
      await request.response.close();
      return;
    }
    try {
      final result = await _mcpMethod(method as String, params);
      await _json(request, {'jsonrpc': '2.0', 'id': id, 'result': result});
    } catch (e) {
      await _json(request, {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32602, 'message': e.toString()},
      });
    }
  }

  Map<String, dynamic> _mcpTool(Map<String, dynamic> tool) {
    final schema = Map<String, dynamic>.from(tool['inputSchema'] as Map);
    final properties = Map<String, dynamic>.from(
      schema['properties'] as Map? ?? {},
    );
    if (tool['read_only'] != true) {
      properties['request_id'] = {
        'type': 'string',
        'description':
            'Unique stable ID for this write. Reuse only when retrying the identical call.',
      };
      schema['required'] = [...schema['required'] as List? ?? [], 'request_id'];
    }
    schema['properties'] = properties;
    return {
      'name': tool['name'],
      'description': tool['description'],
      'inputSchema': schema,
      'annotations': {
        'readOnlyHint': tool['read_only'],
        'idempotentHint': true,
        'openWorldHint': false,
      },
    };
  }

  Future<Map<String, dynamic>> _mcpMethod(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (method == 'ping') return {};
    if (method == 'tools/list') {
      return {
        'tools': [
          ...runtime.toolList.map(_mcpTool),
          for (final name in ['get_external_job', 'cancel_external_job'])
            {
              'name': name,
              'description': name == 'get_external_job'
                  ? 'Read external job progress and result.'
                  : 'Cancel an external job.',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'job_id': {'type': 'string'},
                },
                'required': ['job_id'],
                'additionalProperties': false,
              },
            },
        ],
      };
    }
    if (method == 'tools/call') {
      final name = params['name'] as String,
          args = Map<String, dynamic>.from(params['arguments'] as Map? ?? {});
      Map<String, dynamic> result;
      if (name == 'get_external_job' || name == 'cancel_external_job') {
        final id = args['job_id'] as String;
        if (name == 'cancel_external_job') await runtime.cancel(id);
        final job = runtime.jobs[id];
        if (job == null) {
          throw const ExternalAgentException('not_found', 'Unknown job.');
        }
        result = job.toJson();
      } else {
        final requestId = args.remove('request_id') as String?;
        result = await runtime.call(name, args, requestId: requestId);
      }
      return {
        'content': [
          {'type': 'text', 'text': jsonEncode(result)},
        ],
        'structuredContent': result,
        'isError': const {
          'failed',
          'cancelled',
          'interrupted',
        }.contains(result['status']),
      };
    }
    if (method == 'resources/list') return {'resources': []};
    if (method == 'resources/read') {
      final uri = Uri.parse(params['uri'] as String);
      if (uri.scheme != 'aaalice' || uri.host != 'image') {
        throw const FormatException('Invalid image resource.');
      }
      final file = await readResource(uri.pathSegments.single);
      if (file == null || !await file.exists()) {
        throw const ExternalAgentException('not_found', 'Image unavailable.');
      }
      return {
        'contents': [
          {
            'uri': uri.toString(),
            'mimeType': 'image/png',
            'blob': base64Encode(await file.readAsBytes()),
          },
        ],
      };
    }
    throw const ExternalAgentException(
      'method_not_found',
      'Unsupported MCP method.',
    );
  }
}
