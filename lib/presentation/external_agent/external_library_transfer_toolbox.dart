import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/model_capabilities.dart';
import '../../core/agent/resources/agent_chat_resource_reference.dart';
import '../../core/agent/resources/agent_chat_resource_reference_codec.dart';
import '../../core/external_agent/external_agent_runtime.dart';
import '../../core/external_agent/external_billing_scope.dart';
import '../../core/agent/abort_signal.dart';
import '../../data/datasources/remote/nai_image_enhancement_api_service.dart';
import '../../data/models/vibe/vibe_export_format.dart';
import '../../data/models/vibe/vibe_library_entry.dart';
import '../../data/models/vibe/vibe_reference.dart';
import '../../core/utils/display_thumbnail_utils.dart';
import '../../data/services/vibe_bulk_import_service.dart';
import '../../data/services/vibe_export_service.dart';
import '../../data/services/vibe_library_storage_service.dart';
import '../../data/services/precise_ref_library_archive_service.dart';
import '../../data/services/precise_ref_library_storage_service.dart';
import '../../data/services/tag_library_portable_thumbnail_store.dart';
import '../agent_chat/services/defined_agent_tool.dart';
import '../agent_chat/services/toolbox_json.dart';
import '../providers/vibe_library_provider.dart';
import '../providers/precise_ref_library_provider.dart';
import '../providers/tag_library_page_provider.dart';
import 'external_agent_resources.dart';

class ExternalLibraryTransferToolbox {
  ExternalLibraryTransferToolbox(this.ref, this.resources);
  final Ref ref;
  final ExternalAgentResources resources;
  ExternalAgentOperation _tool(
    String name,
    String description,
    Map<String, dynamic> properties,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) execute, {
    List<String> required = const [],
    bool read = false,
    bool long = true,
    Future<int?> Function(Map<String, dynamic>)? estimate,
  }) => ExternalAgentOperation(
    DefinedAgentTool(
      name: name,
      label: name,
      description: description,
      parameters: toolboxObject(properties: properties, required: required),
      executeFn: (_, args) async => agentToolJsonResult(await execute(args)),
    ),
    readOnly: read,
    longRunning: long,
    estimate: estimate,
  );
  List<ExternalAgentOperation> operations() => [
    _tool(
      'import_vibe_image',
      'Copy a local, gallery or history image into the Vibe library as a reusable raw-image entry. Encoding is a separate chargeable operation.',
      {
        'name': {'type': 'string', 'minLength': 1},
        'path': {'type': 'string'},
        'resource_ref': {'type': 'object', 'additionalProperties': true},
        'strength': {'type': 'number'},
        'info_extracted': {'type': 'number', 'minimum': 0.01, 'maximum': 1},
      },
      (args) async {
        final bytes = await resources.load(args);
        final thumbnail = await DisplayThumbnailUtils.normalize(bytes);
        if (thumbnail == null) {
          throw const FormatException('Image cannot be decoded.');
        }
        throwIfAborted(ExternalBillingScope.currentSignal);
        final notifier = ref.read(vibeLibraryNotifierProvider.notifier);
        await notifier.initialize();
        final entry = VibeLibraryEntry.fromVibeReference(
          name: args['name'] as String,
          vibeData: VibeReference(
            displayName: args['name'] as String,
            vibeEncoding: '',
            rawImageData: bytes,
            thumbnail: thumbnail,
            strength: (args['strength'] as num?)?.toDouble() ?? 0.6,
            infoExtracted: (args['info_extracted'] as num?)?.toDouble() ?? 0.7,
          ),
          thumbnail: thumbnail,
        );
        final saved = await notifier.saveEntry(entry);
        if (saved == null) throw StateError('Could not save Vibe image.');
        return {
          'entry_id': saved.id,
          'name': saved.name,
          'requires_encoding': true,
        };
      },
      required: ['name'],
    ),
    _tool(
      'import_reference_files',
      'Import Vibe files/bundles or precise-reference archives/images. Returns each input result; successful imports are retained.',
      {
        'library': {
          'type': 'string',
          'enum': ['vibe', 'precise'],
        },
        'paths': {
          'type': 'array',
          'items': {'type': 'string'},
          'minItems': 1,
          'maxItems': 100,
        },
      },
      (args) async {
        final results = <Map<String, dynamic>>[];
        for (final path in toolboxStrings(args['paths'])) {
          throwIfAborted(ExternalBillingScope.currentSignal);
          try {
            if (args['library'] == 'vibe') {
              final storage = ref.read(vibeLibraryStorageServiceProvider);
              final result = await VibeBulkImportService(
                storage,
              ).importPaths([path]);
              results.add({
                'path': path,
                'success_count': result.successCount,
                'failed_count': result.failedCount,
                'errors': result.errors
                    .map(
                      (e) => {
                        'item': e.itemName,
                        'code': e.code.name,
                        'reason': e.details,
                      },
                    )
                    .toList(),
              });
            } else if (path.toLowerCase().endsWith('.naipreciseref')) {
              final storage = ref.read(preciseRefLibraryStorageServiceProvider);
              final entries = await PreciseRefLibraryArchiveService(
                storage,
              ).importFromPath(path);
              results.add({
                'path': path,
                'success_count': entries.length,
                'failed_count': 0,
                'entry_ids': entries.map((e) => e.id).toList(),
              });
            } else {
              final entry = await ref
                  .read(preciseRefLibraryNotifierProvider.notifier)
                  .importFromBytes(
                    await File(path).readAsBytes(),
                    name: path.split(RegExp(r'[/\\]')).last,
                  );
              results.add({
                'path': path,
                'success_count': 1,
                'failed_count': 0,
                'entry_ids': [entry.id],
              });
            }
          } catch (e) {
            results.add({
              'path': path,
              'success_count': 0,
              'failed_count': 1,
              'error': e.toString(),
            });
          }
        }
        if (args['library'] == 'vibe') {
          await ref.read(vibeLibraryNotifierProvider.notifier).reload();
        } else {
          await ref.read(preciseRefLibraryNotifierProvider.notifier).reload();
        }
        return {
          'items': results,
          'failed_count': results.fold<int>(
            0,
            (sum, item) => sum + (item['failed_count'] as int),
          ),
        };
      },
      required: ['library', 'paths'],
    ),
    _tool(
      'export_reference_entries',
      'Export selected Vibe entries as a NovelAI bundle or precise references as a portable archive.',
      {
        'library': {
          'type': 'string',
          'enum': ['vibe', 'precise'],
        },
        'entry_ids': {
          'type': 'array',
          'items': {'type': 'string'},
          'minItems': 1,
          'maxItems': 100,
        },
      },
      (args) async {
        final ids = toolboxStrings(args['entry_ids']);
        if (args['library'] == 'vibe') {
          final storage = ref.read(vibeLibraryStorageServiceProvider);
          final entries = await Future.wait(ids.map(storage.getEntry));
          if (entries.any((e) => e == null)) {
            throw StateError('Some Vibe entries are unavailable.');
          }
          final path = await VibeExportService().exportAsBundle(
            entries.whereType<VibeLibraryEntry>().toList(),
            options: VibeExportOptions(
              fileName: 'agent-vibes-${DateTime.now().microsecondsSinceEpoch}',
            ),
          );
          if (path == null) throw StateError('Vibe export failed.');
          return {'path': File(path).absolute.path};
        }
        final notifier = ref.read(preciseRefLibraryNotifierProvider.notifier);
        await notifier.initialize();
        final entries = ref
            .read(preciseRefLibraryNotifierProvider)
            .entries
            .where((e) => ids.contains(e.id))
            .toList();
        if (entries.length != ids.length) {
          throw StateError('Some precise reference entries are unavailable.');
        }
        final path =
            '${resources.directory.parent.path}/precise-${DateTime.now().microsecondsSinceEpoch}.naipreciseref';
        await PreciseRefLibraryArchiveService(
          ref.read(preciseRefLibraryStorageServiceProvider),
        ).exportToPath(entries: entries, outputPath: path);
        return {'path': File(path).absolute.path};
      },
      required: ['library', 'entry_ids'],
    ),
    _tool(
      'encode_vibe_entry',
      'Encode a raw-image Vibe entry for a chosen NovelAI model, reuse its existing compatible encoding when available, and persist the result.',
      {
        'entry_id': {'type': 'string'},
        'model': {'type': 'string'},
      },
      (args) async {
        final model = args['model'] as String;
        if (!ModelCapabilityRegistry.of(model).supportsEncodedVibeTransfer) {
          throw UnsupportedError('This model does not support encoded Vibe.');
        }
        final entry = await ref
            .read(vibeLibraryStorageServiceProvider)
            .getEntry(args['entry_id'] as String);
        if (entry == null) throw StateError('Vibe entry unavailable.');
        if (entry.vibeEncoding.isNotEmpty && entry.encodingModel == model) {
          return {'entry_id': entry.id, 'reused': true};
        }
        final bytes = entry.rawImageData;
        if (bytes == null) {
          throw StateError('Vibe entry has no raw image for encoding.');
        }
        final encoding = await ref
            .read(naiImageEnhancementApiServiceProvider)
            .encodeVibe(
              bytes,
              model: model,
              informationExtracted: entry.infoExtracted,
            );
        final saved = await ref
            .read(vibeLibraryNotifierProvider.notifier)
            .saveEntryParams(
              entry.id,
              strength: entry.strength,
              infoExtracted: entry.infoExtracted,
              persistedVibeData: entry.toVibeReference().copyWith(
                vibeEncoding: encoding,
                encodingModel: model,
              ),
            );
        if (saved == null) throw StateError('Could not save encoded Vibe.');
        return {'entry_id': entry.id, 'reused': false, 'model': model};
      },
      required: ['entry_id', 'model'],
      estimate: (args) async {
        final entry = await ref
            .read(vibeLibraryStorageServiceProvider)
            .getEntry(args['entry_id'] as String);
        return entry?.vibeEncoding.isNotEmpty == true &&
                entry?.encodingModel == args['model']
            ? 0
            : 2;
      },
    ),
    _tool(
      'get_tag_library_preview',
      'Read the saved tag-library preview as a stable image file and resource.',
      {
        'entry_id': {'type': 'string'},
      },
      (args) async {
        final entry = ref
            .read(tagLibraryPageNotifierProvider)
            .entries
            .where((e) => e.id == args['entry_id'])
            .firstOrNull;
        if (entry?.thumbnail == null) throw StateError('Entry has no preview.');
        return resources.save(await File(entry!.thumbnail!).readAsBytes());
      },
      read: true,
      long: false,
      required: ['entry_id'],
    ),
    _tool(
      'set_tag_library_preview',
      'Copy a gallery, history or local image into the tag-library preview directory. Resets crop settings and keeps the old preview if persistence fails.',
      {
        'entry_id': {'type': 'string'},
        'resource_ref': {'type': 'object', 'additionalProperties': true},
        'path': {'type': 'string'},
      },
      (args) async {
        final notifier = ref.read(tagLibraryPageNotifierProvider.notifier);
        final entry = ref
            .read(tagLibraryPageNotifierProvider)
            .entries
            .where((e) => e.id == args['entry_id'])
            .firstOrNull;
        if (entry == null) throw StateError('Tag entry unavailable.');
        final image = await resources.save(await resources.load(args));
        final bytes = await File(image['path'] as String).readAsBytes();
        final mutation = await const TagLibraryPortableThumbnailStore().stage(
          entry.id,
          extension: '.png',
          bytes: Stream.value(bytes),
          existingPath: entry.thumbnail,
        );
        try {
          await notifier.updateEntry(
            entry.copyWith(
              thumbnail: mutation.path,
              thumbnailOffsetX: 0,
              thumbnailOffsetY: 0,
              thumbnailScale: 1,
              updatedAt: DateTime.now(),
            ),
            failOnPersistenceError: true,
          );
        } catch (_) {
          await mutation.rollback();
          rethrow;
        }
        String? cleanupError;
        try {
          await mutation.commit();
        } catch (e) {
          cleanupError = e.toString();
        }
        return {
          'entry_id': entry.id,
          'preview': image,
          if (cleanupError != null) 'cleanup_warning': cleanupError,
          'resource_ref': AgentChatResourceReferenceCodec.encodeJsonMap(
            AgentChatResourceReference(
              kind: AgentChatResourceKind.tagLibraryEntry,
              source: 'tag_library',
              resourceId: entry.id,
              display: const {},
            ),
          ),
        };
      },
      required: ['entry_id'],
    ),
  ];
}
