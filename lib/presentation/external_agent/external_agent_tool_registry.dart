import 'dart:io';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/agent/agent_types.dart';
import '../../core/agent/permissions/agent_permission.dart';
import '../../core/agent/permissions/tool_permission_catalog.dart';
import '../../core/external_agent/external_agent_runtime.dart';
import '../../core/external_agent/external_billing_scope.dart';
import '../../core/agent/resources/agent_chat_resource_reference_codec.dart';
import '../../data/models/queue/replication_task_status.dart';
import '../agent_chat/services/application_context_toolbox.dart';
import '../agent_chat/services/defined_agent_tool.dart';
import '../agent_chat/services/fixed_tags_toolbox.dart';
import '../agent_chat/services/generation_toolbox.dart';
import '../agent_chat/services/generation_preparation_runtime.dart';
import '../agent_chat/services/generation_image_favorite_toolbox.dart';
import '../agent_chat/services/generation_resource_toolbox.dart';
import '../agent_chat/services/manual_inpaint_toolbox.dart';
import '../agent_chat/services/prompt_toolbox.dart';
import '../agent_chat/services/queue_toolbox.dart';
import '../agent_chat/services/tag_toolbox.dart';
import '../agent_chat/services/tag_library_toolbox.dart';
import '../agent_chat/services/reference_library_toolbox.dart';
import '../agent_chat/services/local_gallery_toolbox.dart';
import '../agent_chat/services/image_presentation_toolbox.dart';
import '../agent_chat/services/generation_image_resource.dart';
import '../providers/queue_execution_provider.dart';
import '../providers/image_generation_provider.dart';
import '../providers/replication_queue_provider.dart';
import 'external_agent_resources.dart';
import 'external_material_toolbox.dart';
import 'external_processing_toolbox.dart';
import 'external_library_transfer_toolbox.dart';

class ExternalAgentToolRegistry {
  ExternalAgentToolRegistry(
    this.ref,
    this.support,
    this.resources,
    this.inpaint,
  );
  final Ref ref;
  final Directory support;
  final ExternalAgentResources resources;
  final ManualInpaintToolbox inpaint;
  final generation = GenerationPreparationRuntime();
  final queue = QueueControlRuntime();
  List<ExternalAgentOperation> build() {
    final resolver = resources.resolver;
    final tools = <AgentTool>[
      ...PromptToolbox(ref).tools().where((t) => !t.name.contains('skill')),
      ...GenerationToolbox(
        ref,
        workspaceDir: support.path,
        allowOutsideWorkspace: true,
        runtime: generation,
        resourceResolver: resolver,
      ).tools().where((tool) => tool.name != 'interrogate_image'),
      ...QueueToolbox(ref, queue).tools(),
      ...inpaint.tools(),
      ...TagToolbox(ref).tools(),
      ...ApplicationContextToolbox(
        ref,
        loadDrafts: inpaint.listDraftSummaries,
      ).tools(),
      ...TagLibraryToolbox(ref, resourceResolver: resolver).tools(),
      ...FixedTagsToolbox(ref).tools(),
      ...LocalGalleryToolbox(
        ref,
      ).tools().where((t) => t.name != 'search_local_gallery'),
      ...ReferenceLibraryToolbox(ref, resolver).tools(),
      ...ImagePresentationToolbox(resolver).tools(),
      ...GenerationResourceToolbox(ref).tools(),
      ...GenerationImageFavoriteToolbox(ref).tools(),
    ];
    return [
      for (final original in tools) _operation(original),
      ...ExternalMaterialToolbox(ref, resources).operations(),
      ...ExternalProcessingToolbox(ref, resources).operations(),
      ...ExternalLibraryTransferToolbox(ref, resources).operations(),
    ];
  }

  ExternalAgentOperation _operation(AgentTool original) {
    final descriptor = describeAgentToolPermission(original.name);
    final queueExecution =
        original.name == 'start_generation_queue' ||
        original.name == 'resume_generation_queue';
    final longRunning =
        descriptor.mayConsumeAnlas ||
        queueExecution ||
        original.name.contains('interrogate');
    final tool =
        queueExecution ||
            const {
              'submit_generation',
              'generate_image',
              'queue_image_task',
            }.contains(original.name)
        ? DefinedAgentTool(
            name: original.name,
            label: original.label,
            description: original.description,
            parameters: original.parameters,
            executeWithControl: (id, args, signal, update) async {
              final ownedResume =
                  original.name == 'resume_generation_queue' &&
                  ExternalBillingScope.hasQueueOwner;
              final prep = generation.get(
                args['preparation_id'] as String? ?? '',
              );
              final waitsForQueue =
                  queueExecution ||
                  (prep?.kind == GenerationPreparationKind.queue &&
                      prep?.autoStart == true);
              if (!waitsForQueue || ownedResume) {
                return original.execute(id, args, signal, update);
              }
              await ref
                  .read(imageGenerationNotifierProvider.notifier)
                  .ensureGenerationHistoryRestored();
              final previousImages = ref
                  .read(imageGenerationNotifierProvider)
                  .history
                  .map((i) => i.id)
                  .toSet();
              final result = await original.execute(id, args, signal, update);
              if (result.isError) return result;
              void cancel(String? _) {
                ref.read(imageGenerationNotifierProvider.notifier).cancel();
                ref
                    .read(queueExecutionNotifierProvider.notifier)
                    .stopExecution();
              }

              signal?.addListener(cancel);
              try {
                while (true) {
                  throwIfAborted(signal);
                  final state = ref.read(queueExecutionNotifierProvider);
                  if (!state.isRunning &&
                      !state.isReady &&
                      !state.isPaused &&
                      !ref.read(imageGenerationNotifierProvider).isBusy) {
                    break;
                  }
                  await Future<void>.delayed(const Duration(milliseconds: 250));
                }
                final tasks = ref.read(replicationQueueNotifierProvider).tasks;
                final images = ref
                    .read(imageGenerationNotifierProvider)
                    .history
                    .where(
                      (i) =>
                          !previousImages.contains(i.id) &&
                          !i.isFailedStreamSnapshot,
                    );
                result.content.add(
                  ToolResultTextContent(
                    jsonEncode({
                      'queue_status': ref
                          .read(queueExecutionNotifierProvider)
                          .status
                          .name,
                      'pending': tasks
                          .where(
                            (t) => t.status == ReplicationTaskStatus.pending,
                          )
                          .length,
                      'failed': tasks
                          .where(
                            (t) => t.status == ReplicationTaskStatus.failed,
                          )
                          .length,
                      'images': [
                        for (final image in images)
                          {
                            'resource_ref':
                                AgentChatResourceReferenceCodec.encodeJsonMap(
                                  generationImageResourceReference(image.id),
                                ),
                          },
                      ],
                    }),
                  ),
                );
                return result;
              } finally {
                signal?.removeListener(cancel);
              }
            },
          )
        : original;
    return ExternalAgentOperation(
      tool,
      readOnly: descriptor.operation == AgentPermissionOperation.read,
      concurrentControl: const {
        'pause_generation_queue',
        'resume_generation_queue',
        'stop_generation_queue',
      }.contains(original.name),
      longRunning: longRunning,
      estimate: descriptor.mayConsumeAnlas
          ? (args) async {
              final name = original.name;
              if (name == 'submit_manual_inpaint_draft') {
                return inpaint.estimateAnlasForDraft(
                  args['draft_id'] as String? ?? '',
                );
              }
              if (original.name == 'resume_generation_queue' &&
                  ExternalBillingScope.hasQueueOwner) {
                return 0;
              }
              if (queueExecution) {
                return queue
                    .get(args['queue_preparation_id'] as String? ?? '')
                    ?.estimatedAnlas;
              }
              final prep = generation.get(
                args['preparation_id'] as String? ?? '',
              );
              // Queue preparation without auto-start doesn't dispatch requests.
              if (prep?.kind == GenerationPreparationKind.queue &&
                  prep?.autoStart != true) {
                return 0;
              }
              return prep?.estimatedAnlas ??
                  (args['preparation_id'] == null ? 0 : null);
            }
          : null,
    );
  }
}
