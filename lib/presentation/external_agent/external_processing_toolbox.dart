import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import '../../core/services/anlas_calculator.dart';
import '../../core/agent/agent_types.dart';
import '../../core/external_agent/external_agent_runtime.dart';
import '../../data/datasources/remote/nai_image_enhancement_api_service.dart';
import '../../data/services/dlss/dlss_options.dart';
import '../agent_chat/services/defined_agent_tool.dart';
import '../agent_chat/services/toolbox_json.dart';
import '../providers/comfyui/comfyui_provider.dart';
import '../providers/dlss_provider.dart';
import '../providers/subscription_provider.dart';
import 'external_agent_resources.dart';

class ExternalProcessingToolbox {
  ExternalProcessingToolbox(this.ref, this.resources);
  final Ref ref;
  final ExternalAgentResources resources;
  final _imageProperties = <String, dynamic>{
    'path': {'type': 'string'},
    'resource_ref': {'type': 'object', 'additionalProperties': true},
  };
  List<ExternalAgentOperation> operations() => [
    ExternalAgentOperation(
      DefinedAgentTool(
        name: 'process_image',
        label: 'Process Image',
        description:
            'Actually execute NovelAI upscale or Director processing, or enabled Windows DLSS. Returns a saved output image.',
        parameters: toolboxObject(
          properties: {
            ..._imageProperties,
            'operation': {
              'type': 'string',
              'enum': [
                'upscale',
                'emotion',
                'bg-removal',
                'colorize',
                'declutter',
                'lineart',
                'sketch',
                'dlss',
              ],
            },
            'prompt': {'type': 'string'},
            'defry': {'type': 'integer', 'minimum': 0, 'maximum': 5},
            'dlss_options': {'type': 'object', 'additionalProperties': true},
          },
          required: ['operation'],
        ),
        executeWithControl: (id, args, signal, update) async {
          throwIfAborted(signal);
          final bytes = await resources.load(args);
          final operation = args['operation'];
          Uint8List output;
          if (operation == 'dlss') {
            if (!Platform.isWindows) {
              throw UnsupportedError('DLSS requires Windows.');
            }
            final cancelled = Completer<void>();
            void cancel(String? _) {
              if (!cancelled.isCompleted) cancelled.complete();
            }

            signal?.addListener(cancel);
            try {
              output = await ref
                  .read(dlssProvider)
                  .enhance(
                    bytes,
                    DlssOptions.fromJson(
                      Map<String, dynamic>.from(
                        args['dlss_options'] as Map? ?? {},
                      ),
                    ),
                    cancelled: cancelled.future,
                  );
            } finally {
              signal?.removeListener(cancel);
            }
          } else {
            final api = ref.read(naiImageEnhancementApiServiceProvider);
            output = operation == 'upscale'
                ? await api.upscaleImage(bytes)
                : await api.augmentImage(
                    bytes,
                    reqType: operation as String,
                    prompt: args['prompt'] as String?,
                    defry: args['defry'] as int? ?? 0,
                  );
          }
          throwIfAborted(signal);
          return agentToolJsonResult(await resources.save(output));
        },
      ),
      readOnly: false,
      longRunning: true,
      estimate: (args) async {
        if (args['operation'] == 'dlss') return 0;
        final image = img.decodeImage(await resources.load(args));
        if (image == null) {
          throw const FormatException('Image cannot be decoded.');
        }
        final opus =
            ref.read(subscriptionNotifierProvider).subscription?.isOpus == true;
        final cost = args['operation'] == 'upscale'
            ? AnlasCalculator.calculateNovelAiUpscaleCost(
                inputWidth: image.width,
                inputHeight: image.height,
                scale: 2,
                subscriptionTier: opus ? AnlasCalculator.opusTier : 0,
              )
            : AnlasCalculator.calculateAugmentCost(
                width: image.width,
                height: image.height,
                isBgRemoval: args['operation'] == 'bg-removal',
                isOpus: opus,
              );
        return cost >= 0 ? cost : null;
      },
    ),
    ExternalAgentOperation(
      DefinedAgentTool(
        name: 'list_comfyui_workflows',
        label: 'List ComfyUI Workflows',
        description:
            'List configured ComfyUI workflows and slots without enabling ComfyUI.',
        parameters: toolboxObject(),
        executeFn: (_, args) async {
          final settings = ref.read(comfyUISettingsProvider);
          if (!settings.enabled) {
            throw StateError(
              'ComfyUI is disabled. Enable and configure it in settings first.',
            );
          }
          await ref.read(comfyUIWorkflowsProvider.notifier).whenLoaded();
          final workflows = ref.read(comfyUIWorkflowsProvider);
          return agentToolJsonResult({
            'workflows': workflows.map((w) => w.toManifestJson()).toList(),
          });
        },
      ),
      readOnly: true,
    ),
    ExternalAgentOperation(
      DefinedAgentTool(
        name: 'execute_comfyui_workflow',
        label: 'Execute ComfyUI Workflow',
        description:
            'Execute an already configured and enabled ComfyUI workflow. Input images map slot IDs to local file paths.',
        parameters: toolboxObject(
          properties: {
            'template_id': {'type': 'string'},
            'input_images': {
              'type': 'object',
              'additionalProperties': {'type': 'string'},
            },
            'parameters': {'type': 'object', 'additionalProperties': true},
          },
          required: ['template_id'],
        ),
        executeWithControl: (_, args, signal, update) async {
          if (!ref.read(comfyUISettingsProvider).enabled) {
            throw StateError('ComfyUI is disabled.');
          }
          final notifier = ref.read(comfyUITaskProvider.notifier);
          await ref.read(comfyUIWorkflowsProvider.notifier).whenLoaded();
          void cancel(String? _) => notifier.cancel();
          signal?.addListener(cancel);
          try {
            final inputs = <String, Uint8List>{};
            for (final entry in (args['input_images'] as Map? ?? {}).entries) {
              throwIfAborted(signal);
              inputs[entry.key as String] = await resources.load({
                'path': entry.value as String,
              });
            }
            final images = await notifier.execute(
              templateId: args['template_id'] as String,
              inputImages: inputs,
              paramValues: Map<String, dynamic>.from(
                args['parameters'] as Map? ?? {},
              ),
            );
            throwIfAborted(signal);
            if (images == null) {
              throw StateError(
                'ComfyUI failed: ${ref.read(comfyUITaskProvider)}',
              );
            }
            return agentToolJsonResult({
              'images': await Future.wait(images.map(resources.save)),
            });
          } finally {
            signal?.removeListener(cancel);
          }
        },
      ),
      readOnly: false,
      longRunning: true,
    ),
  ];
}
