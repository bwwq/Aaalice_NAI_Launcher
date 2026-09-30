import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import '../../core/agent/agent_types.dart';
import '../../core/agent/resources/agent_chat_resource_reference.dart';
import '../../core/agent/resources/agent_chat_resource_reference_codec.dart';
import '../../core/database/database_providers.dart';
import '../../core/external_agent/external_agent_runtime.dart';
import '../../core/external_agent/external_billing_scope.dart';
import '../../data/services/gallery/unified_gallery_service.dart';
import '../../data/services/gallery/gallery_stream_scanner.dart';
import '../../data/repositories/gallery_folder_repository.dart';
import '../agent_chat/services/defined_agent_tool.dart';
import '../agent_chat/services/toolbox_json.dart';
import '../providers/gallery_album_provider.dart';
import '../providers/gallery_category_provider.dart';
import '../providers/local_gallery_provider.dart';
import '../providers/locale_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/font_scale_provider.dart';
import '../providers/cloud_sync/cloud_sync_provider_wiring.dart';
import '../screens/statistics/statistics_state.dart';
import '../themes/app_theme.dart';
import 'external_agent_resources.dart';

class ExternalMaterialToolbox {
  ExternalMaterialToolbox(this.ref, this.resources);
  final Ref ref;
  final ExternalAgentResources resources;
  ExternalAgentOperation _tool(
    String name,
    String description,
    Map<String, dynamic> properties,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) execute, {
    List<String> required = const [],
    bool read = true,
    bool long = false,
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
  );
  List<ExternalAgentOperation> operations() => [
    _tool(
      'search_local_gallery',
      'Query a separate local gallery page; never changes the visible gallery filters or selection.',
      {
        'query': {'type': 'string'},
        'favorites_only': {'type': 'boolean'},
        'page': {'type': 'integer', 'minimum': 0},
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
      },
      (args) async {
        await ref.read(databaseManagerProvider.future);
        await ref.read(galleryServiceProvider.notifier).ensureInitialized();
        final service = ref.read(galleryServiceProvider);
        final page = await service.queryPage(
          page: args['page'] as int? ?? 0,
          pageSize: args['limit'] as int? ?? 50,
          searchQuery: args['query'] as String? ?? '',
          favoritesOnly: args['favorites_only'] == true,
        );
        return {
          'total': page.totalCount,
          'page': page.page,
          'has_more': page.hasMore,
          'items': [
            for (final record in page.records)
              {
                'path': record.path,
                'favorite': record.isFavorite,
                'tags': record.tags,
                'resource_ref': AgentChatResourceReferenceCodec.encodeJsonMap(
                  AgentChatResourceReference(
                    kind: AgentChatResourceKind.localGalleryImage,
                    source: 'local_gallery',
                    resourceId:
                        '${await service.getImageIdByPath(record.path)}',
                    display: const {},
                  ),
                ),
              },
          ],
        };
      },
    ),
    _scan(),
    _tool('list_gallery_albums', 'List all local albums and categories.', {}, (
      _,
    ) async {
      await ref.read(galleryAlbumNotifierProvider.notifier).whenLoaded();
      await ref.read(galleryCategoryNotifierProvider.notifier).whenLoaded();
      return {
        'albums': ref
            .read(galleryAlbumNotifierProvider)
            .albums
            .map((a) => a.toJson())
            .toList(),
        'categories': ref
            .read(galleryCategoryNotifierProvider)
            .categories
            .map((a) => a.toJson())
            .toList(),
      };
    }),
    _tool(
      'manage_gallery_album',
      'Create, rename, move an album, or add/remove image members. Members are references; source files stay intact.',
      {
        'action': {
          'type': 'string',
          'enum': [
            'create',
            'rename',
            'move',
            'add_images',
            'remove_images',
            'delete',
          ],
        },
        'album_id': {'type': 'string'},
        'parent_id': {'type': 'string'},
        'name': {'type': 'string'},
        'paths': {
          'type': 'array',
          'items': {'type': 'string'},
          'maxItems': 1000,
        },
      },
      (args) async {
        final notifier = ref.read(galleryAlbumNotifierProvider.notifier);
        await notifier.whenLoaded();
        final action = args['action'], id = args['album_id'] as String?;
        if (action != 'create' && id == null) {
          throw const FormatException('album_id required.');
        }
        Object result;
        switch (action) {
          case 'create':
            result = await notifier.createAlbum(
              args['name'] as String,
              parentId: args['parent_id'] as String?,
            );
          case 'rename':
            result = await notifier.renameAlbum(id!, args['name'] as String);
          case 'move':
            result = await notifier.moveAlbum(
              id!,
              args['parent_id'] as String?,
            );
          case 'delete':
            result = await notifier.deleteAlbum(id!);
          case 'add_images':
            result = await notifier.addImagesByPaths(
              id!,
              toolboxStrings(args['paths']),
            );
          default:
            result = await notifier.removeImagesByPaths(
              id!,
              toolboxStrings(args['paths']),
            );
        }
        if (result == false) throw StateError('Album operation failed.');
        return {'result': result};
      },
      read: false,
      required: ['action'],
    ),
    _tool(
      'manage_gallery_category',
      'Create/rename a category or move image files into it. Returns per-image results.',
      {
        'action': {
          'type': 'string',
          'enum': ['create', 'rename', 'move_images'],
        },
        'category_id': {'type': 'string'},
        'parent_id': {'type': 'string'},
        'name': {'type': 'string'},
        'paths': {
          'type': 'array',
          'items': {'type': 'string'},
          'maxItems': 1000,
        },
      },
      (args) async {
        final notifier = ref.read(galleryCategoryNotifierProvider.notifier);
        await notifier.whenLoaded();
        if (args['action'] == 'create') {
          final category = await notifier.createCategory(
            args['name'] as String,
            parentId: args['parent_id'] as String?,
          );
          if (category == null) throw StateError('Create category failed.');
          return category.toJson();
        }
        final id = args['category_id'] as String?;
        if (id == null) throw const FormatException('category_id required.');
        if (args['action'] == 'rename') {
          final category = await notifier.renameCategory(
            id,
            args['name'] as String,
          );
          if (category == null) throw StateError('Rename category failed.');
          return category.toJson();
        }
        if (!ref
            .read(galleryCategoryNotifierProvider)
            .categories
            .any((c) => c.id == id)) {
          throw StateError('Unknown category.');
        }
        final results = <Map<String, dynamic>>[];
        for (final path in toolboxStrings(args['paths'])) {
          throwIfAborted(ExternalBillingScope.currentSignal);
          final moved = await notifier.moveImageToCategory(path, id);
          results.add({'source': path, 'path': moved, 'ok': moved != null});
        }
        await ref
            .read(localGalleryNotifierProvider.notifier)
            .refresh(scan: false);
        return {
          'items': results,
          'failed': results.where((r) => r['ok'] != true).length,
        };
      },
      read: false,
      long: true,
      required: ['action'],
    ),
    _tool(
      'get_application_settings',
      'Read only ordinary display settings; no account keys or external-agent permissions are exposed.',
      {},
      (_) async => {
        'theme': ref.read(themeNotifierProvider).name,
        'language': ref.read(localeNotifierProvider).toLanguageTag(),
        'font_scale': ref.read(fontScaleNotifierProvider),
        'available_themes': AppStyle.values.map((s) => s.name).toList(),
      },
    ),
    _tool(
      'update_application_settings',
      'Change ordinary display settings. External Agent permissions, budget and connection cannot be changed here.',
      {
        'theme': {
          'type': 'string',
          'enum': AppStyle.values.map((s) => s.name).toList(),
        },
        'language': {
          'type': 'string',
          'enum': ['zh', 'zh-Hant', 'en', 'ja'],
        },
        'font_scale': {'type': 'number', 'minimum': 0.8, 'maximum': 1.5},
      },
      (args) async {
        if (args['theme'] != null) {
          await ref
              .read(themeNotifierProvider.notifier)
              .setTheme(
                AppStyle.values.firstWhere((s) => s.name == args['theme']),
              );
        }
        if (args['language'] != null) {
          await ref
              .read(localeNotifierProvider.notifier)
              .setLocale(args['language'] as String);
        }
        if (args['font_scale'] != null) {
          await ref
              .read(fontScaleNotifierProvider.notifier)
              .setFontScale((args['font_scale'] as num).toDouble());
        }
        return {'ok': true};
      },
      read: false,
    ),
    _tool(
      'get_application_statistics',
      'Read local generation statistics.',
      {},
      (_) async {
        await ref.read(statisticsNotifierProvider.notifier).whenLoaded();
        final state = ref.read(statisticsNotifierProvider);
        if (state.error != null) throw StateError(state.error!);
        final s = state.statistics;
        if (s == null) throw StateError('Statistics unavailable.');
        return {
          'total_images': s.totalImages,
          'total_size_bytes': s.totalSizeBytes,
          'models': s.modelDistribution
              .map((m) => {'model': m.modelName, 'count': m.count})
              .toList(),
        };
      },
    ),
    _tool(
      'list_backups',
      'Read backup history using the configured connection.',
      {},
      (_) async =>
          ref.read(cloudSyncApplicationServiceProvider).externalHistory(),
    ),
    _tool(
      'browse_backup',
      'Read backup contents without restoring or replacing the current preview.',
      {
        'snapshot_id': {'type': 'string'},
      },
      (args) => ref
          .read(cloudSyncApplicationServiceProvider)
          .externalBrowse(args['snapshot_id'] as String),
      required: ['snapshot_id'],
      long: true,
    ),
    _tool(
      'create_backup',
      'Create a backup with the existing configured content selection. Existing backups are never pruned.',
      {},
      (_) =>
          ref.read(cloudSyncApplicationServiceProvider).externalCreateBackup(),
      read: false,
      long: true,
    ),
    _tool(
      'read_image_resource',
      'Resolve a history, gallery or library image into a stable file and resource URL.',
      {
        'resource_ref': {'type': 'object', 'additionalProperties': true},
        'path': {'type': 'string'},
      },
      (args) async => resources.save(await resources.load(args)),
    ),
  ];
  ExternalAgentOperation _scan() => ExternalAgentOperation(
    DefinedAgentTool(
      name: 'scan_local_gallery',
      label: 'Scan Local Gallery',
      description:
          'Scan the configured gallery with progress and cancellation, without changing its filters.',
      parameters: toolboxObject(),
      executeWithControl: (_, args, signal, update) async {
        final root = await GalleryFolderRepository.instance.getRootPath();
        if (root == null || root.isEmpty) {
          throw StateError('Gallery folder is not configured.');
        }
        final source = (await ref.read(
          databaseManagerProvider.future,
        )).galleryDataSource;
        if (source == null) throw StateError('Gallery database unavailable.');
        StreamScanStats? latest;
        await GalleryStreamScanner.instance(dataSource: source).startScanning(
          Directory(root),
          signal: signal,
          throwOnError: true,
          onFileProcessed: (file, stats) {
            latest = stats;
            update?.call(
              agentToolJsonResult({
                'progress': stats.progress,
                'processed': stats.processed,
                'total': stats.totalDiscovered,
                'failed': stats.failed,
              }),
            );
          },
        );
        throwIfAborted(signal);
        await ref
            .read(localGalleryNotifierProvider.notifier)
            .refresh(scan: false);
        return agentToolJsonResult({
          'processed': latest?.processed ?? 0,
          'failed': latest?.failed ?? 0,
          'indexed_images': await source.countImages(),
        });
      },
    ),
    readOnly: false,
    longRunning: true,
  );
}
