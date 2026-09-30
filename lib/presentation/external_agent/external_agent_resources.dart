import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import '../../core/agent/agent_types.dart';
import '../../core/agent/resources/agent_chat_resource_reference.dart';
import '../agent_chat/services/agent_resource_resolver.dart';

/// Copies results into stable, content-addressed files, including unsaved history.
class ExternalAgentResources {
  ExternalAgentResources(this.directory, this.resolver);
  final Directory directory;
  final AgentResourceResolver resolver;
  Future<Map<String, dynamic>> save(Uint8List bytes) async {
    final normalized = await Isolate.run(() => _normalizeImage(bytes));
    bytes = normalized.$1;
    await directory.create(recursive: true);
    final id = normalized.$2;
    final file = File('${directory.path}/$id.png');
    if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
    return {
      'image_id': id,
      'path': file.absolute.path,
      'resource_uri': 'aaalice://image/$id',
      'resource_url': '/api/v1/resources/$id',
    };
  }

  Future<File?> file(String id) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) return null;
    final file = File('${directory.path}/$id.png');
    return await file.exists() ? file : null;
  }

  Future<Uint8List> load(Map<String, dynamic> args) async {
    if (args['resource_ref'] != null) {
      final reference = resolver.decode(args['resource_ref']);
      await resolver.validateImageResource(reference);
      final result = await resolver.resolve(reference);
      if (result?.bytes != null) return _requireImage(result!.bytes!);
      throw StateError('Image resource unavailable.');
    }
    final path = args['path'] as String?;
    if (path == null) {
      throw const FormatException('Provide path or resource_ref.');
    }
    return _requireImage(await File(path).readAsBytes());
  }

  Uint8List _requireImage(Uint8List bytes) {
    if (img.findDecoderForData(bytes) == null) {
      throw const FormatException('Input is not an image.');
    }
    return bytes;
  }

  Future<dynamic> _expand(dynamic data, {bool collection = false}) async {
    if (data is List) {
      final items = <dynamic>[];
      for (final item in data) {
        items.add(await _expand(item, collection: true));
      }
      return items;
    }
    if (data is! Map) return data;
    final out = <String, dynamic>{};
    for (final entry in data.entries) {
      out[entry.key as String] = await _expand(
        entry.value,
        collection: collection,
      );
    }
    if (data['resource_ref'] is Map) {
      try {
        final reference = resolver.decode(data['resource_ref']);
        // Discovery stays lightweight; callers can explicitly read selected resources.
        if (collection &&
            reference.kind != AgentChatResourceKind.generatedImage) {
          return out;
        }
        await resolver.validateImageResource(reference);
        final resolved = await resolver.resolve(reference);
        if (resolved?.bytes != null) {
          out['image_resource'] = await save(resolved!.bytes!);
        } else if (reference.kind == AgentChatResourceKind.generatedImage) {
          throw StateError('Generated image is unavailable.');
        }
      } catch (e) {
        out['resource_error'] = e.toString();
      }
    }
    return out;
  }

  Future<Map<String, dynamic>> adopt(AgentToolResult result) async {
    final content = <Map<String, dynamic>>[];
    for (final item in result.content) {
      if (item is ToolResultTextContent) {
        dynamic decoded;
        try {
          decoded = jsonDecode(item.text);
        } catch (_) {
          decoded = item.text;
        }
        content.add({'type': 'text', 'data': await _expand(decoded)});
      } else if (item is ToolResultImageContent &&
          item.image.source.bytes != null) {
        content.add({'type': 'image', ...await save(item.image.source.bytes!)});
      }
    }
    return {
      'content': content,
      'is_error': result.isError || _hasResourceError(content),
    };
  }
}

(Uint8List, String) _normalizeImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Resource is not a readable image.');
  }
  final png =
      bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71;
  final normalized = png ? bytes : Uint8List.fromList(img.encodePng(decoded));
  return (normalized, sha256.convert(normalized).toString());
}

bool _hasResourceError(dynamic value) {
  if (value is Map) {
    return value.containsKey('resource_error') ||
        value.values.any(_hasResourceError);
  }
  return value is List && value.any(_hasResourceError);
}
