import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/external_agent/external_agent_runtime.dart';
import '../../core/external_agent/external_agent_server.dart';
import '../../core/services/anlas_calculator.dart';
import '../../core/services/desktop_app_shutdown_service.dart';
import '../agent_chat/services/agent_resource_resolver.dart';
import '../agent_chat/services/manual_inpaint_toolbox.dart';
import '../providers/external_agent_config_provider.dart';
import '../providers/subscription_provider.dart';
import '../providers/cost_estimate_provider.dart';
import 'external_agent_resources.dart';
import 'external_agent_tool_registry.dart';

final externalAgentControllerProvider =
    ChangeNotifierProvider<ExternalAgentController>((ref) {
      final controller = ExternalAgentController(ref);
      ref.listen(externalAgentConfigProvider, (previous, next) {
        if (previous?.enabled != next.enabled ||
            previous?.allowLan != next.allowLan ||
            previous?.port != next.port) {
          unawaited(controller.configure());
        }
      });
      unawaited(controller.initialize());
      ref.onDispose(() => unawaited(controller.shutdown()));
      return controller;
    });

class ExternalAgentController extends ChangeNotifier {
  ExternalAgentController(this.ref);
  final Ref ref;
  ExternalAgentRuntime? runtime;
  ExternalAgentServer? server;
  String? error;
  bool loading = true;
  bool _disposed = false;
  Future<void>? _initializing;
  Future<void> _configuration = Future.value();
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      final support = await getApplicationSupportDirectory();
      final directory = Directory('${support.path}/external_agent');
      final inpaint = ManualInpaintToolbox(
        ref,
        supportDirectory: directory,
        workspaceDir: support.path,
        allowOutsideWorkspace: true,
        activeSessionId: () => 'external-agent',
      );
      final resolver = AgentResourceResolver(
        ref,
        loadInpaintDraftImage: inpaint.loadDraftImage,
      );
      inpaint.configureResourceResolver(resolver);
      final resources = ExternalAgentResources(
        Directory('${directory.path}/images'),
        resolver,
      );
      final registry = ExternalAgentToolRegistry(
        ref,
        support,
        resources,
        inpaint,
      );
      runtime = ExternalAgentRuntime(
        directory: directory,
        readConfig: () => ref.read(externalAgentConfigProvider),
        saveSpent: (value, day) => ref
            .read(externalAgentConfigProvider.notifier)
            .recordSpent(value, day),
        estimateRequest: _estimateRequest,
        operations: registry.build(),
        onChanged: _changed,
        adoptResult: resources.adopt,
      );
      await runtime!.initialize();
      server = ExternalAgentServer(runtime!, readResource: resources.file);
      DesktopAppShutdownService.externalAgentShutdownHandler = shutdown;
      await _applyConfig();
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      _changed();
    }
  }

  Future<void> configure() {
    _configuration = _configuration.catchError((Object _) {}).then((_) async {
      await initialize();
      await _applyConfig();
    });
    return _configuration;
  }

  Future<void> _applyConfig() async {
    if (_disposed) return;
    final current = server;
    if (current == null) return;
    try {
      final config = ref.read(externalAgentConfigProvider);
      if (config.enabled) {
        await current.start(config);
      } else {
        await current.stop();
      }
      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      _changed();
    }
  }

  Future<int?> _estimateRequest(String kind, Map<String, dynamic> data) async {
    final subscription = ref.read(subscriptionNotifierProvider).subscription;
    final isOpus = subscription?.isOpus == true;
    if (kind == 'encode_vibe') return 2;
    if (kind == 'upscale') {
      final value = AnlasCalculator.calculateNovelAiUpscaleCost(
        inputWidth: data['width'] as int,
        inputHeight: data['height'] as int,
        scale: data['scale'] as int? ?? 2,
        subscriptionTier: isOpus ? AnlasCalculator.opusTier : 0,
      );
      return value >= 0 ? value : null;
    }
    if (kind == 'augment') {
      return AnlasCalculator.calculateAugmentCost(
        width: data['width'] as int,
        height: data['height'] as int,
        isBgRemoval: data['req_type'] == 'bg-removal',
        isOpus: isOpus,
      );
    }
    if (kind != 'generate') return null;
    final p = Map<String, dynamic>.from(data['parameters'] as Map);
    final dimensions = resolveGenerationBillingSize(
      width: p['width'] as int,
      height: p['height'] as int,
      maxEnhance: p['upscaled_enhance'] == true,
    );
    final samples = p['n_samples'] as int? ?? 1;
    final precise = (p['director_reference_images'] as List? ?? []).length;
    final vibes = (p['reference_image_multiple'] as List? ?? []).length;
    final value = AnlasCalculator.calculateRequestCost(
      width: dimensions.width,
      height: dimensions.height,
      steps: p['steps'] as int? ?? 28,
      batchCount: samples,
      batchSize: samples,
      model: data['model'] as String,
      subscriptionTier: isOpus ? AnlasCalculator.opusTier : 0,
      opusQuotaExhausted: subscription?.usage?.isNegative ?? false,
      strength: (p['strength'] as num?)?.toDouble() ?? 1,
      smea: p['sm'] == true,
      smeaDyn: p['sm_dyn'] == true,
      extraPerSampleCost: precise * 5,
      extraPerRequestCost: (vibes - 4).clamp(0, 10000) * 2,
    );
    return value >= 0 ? value : null;
  }

  Future<void> shutdown() async {
    await server?.stop();
    await runtime?.shutdown();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
