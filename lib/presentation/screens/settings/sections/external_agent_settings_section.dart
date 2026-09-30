import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/external_agent/external_agent_models.dart';
import '../../../../core/utils/localization_extension.dart';
import '../../../adaptive/adaptive_presenter.dart';
import '../../../adaptive/content_sized_adaptive_form.dart';
import '../../../external_agent/external_agent_controller.dart';
import '../../../providers/external_agent_config_provider.dart';
import '../../../widgets/common/app_toast.dart';
import '../widgets/settings_card.dart';
import '../widgets/settings_page_layout.dart';

class ExternalAgentSettingsSection extends ConsumerStatefulWidget {
  const ExternalAgentSettingsSection({super.key});
  @override
  ConsumerState<ExternalAgentSettingsSection> createState() =>
      _ExternalAgentSettingsSectionState();
}

class _ExternalAgentSettingsSectionState
    extends ConsumerState<ExternalAgentSettingsSection> {
  late final TextEditingController _port, _budget, _perCallBudget;
  bool _saving = false;
  String? _address;
  @override
  void initState() {
    super.initState();
    final config = ref.read(externalAgentConfigProvider);
    _port = TextEditingController(text: '${config.port}');
    _budget = TextEditingController(text: '${config.budget}');
    _perCallBudget = TextEditingController(text: '${config.perCallBudget}');
  }

  @override
  void dispose() {
    _port.dispose();
    _budget.dispose();
    _perCallBudget.dispose();
    super.dispose();
  }

  Future<void> _save(
    ExternalAgentConfig Function(ExternalAgentConfig) change,
  ) => _saveAction(
    () => ref.read(externalAgentConfigProvider.notifier).updateWith(change),
  );

  Future<void> _saveAction(Future<void> Function() action) async {
    setState(() => _saving = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        AppToast.error(context, context.l10n.globalSettings_saveFailed('$e'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) AppToast.success(context, context.l10n.externalAgent_copied);
  }

  Future<void> _showResult(ExternalAgentJob job) =>
      AdaptivePresenter.showForm<void>(
        context: context,
        titleBuilder: (context) => Text(context.l10n.externalAgent_result),
        builder: (context, scroll) => ContentSizedAdaptiveForm(
          scrollController: scroll,
          content: [
            for (final path in _imagePaths(job.result))
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  height: 260,
                  errorBuilder: (context, error, stack) =>
                      Text(context.l10n.externalAgent_imageUnavailable),
                ),
              ),
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(job.toJson()),
            ),
          ],
        ),
      );
  Set<String> _imagePaths(dynamic value, [Set<String>? paths]) {
    final result = paths ?? <String>{};
    if (result.length >= 8) return result;
    if (value is Map) {
      final path = value['path'];
      if (path is String &&
          RegExp(
            r'\.(png|jpe?g|webp|gif|bmp)$',
            caseSensitive: false,
          ).hasMatch(path)) {
        result.add(path);
      }
      for (final child in value.values) {
        _imagePaths(child, result);
      }
    } else if (value is List) {
      for (final child in value) {
        _imagePaths(child, result);
      }
    }
    return result;
  }

  String _toolLabel(ExternalAgentJob job) {
    final name = job.tool, l10n = context.l10n;
    final category = name.contains('queue')
        ? l10n.queue_management
        : name.contains('gallery')
        ? l10n.nav_localGallery
        : name.contains('vibe')
        ? l10n.vibeLibrary_title
        : name.contains('precise')
        ? l10n.nav_preciseRefLibrary
        : name.contains('tag')
        ? l10n.nav_dictionary
        : name.contains('prompt') || name.contains('character')
        ? l10n.promptToken_prompt
        : name.contains('backup')
        ? l10n.cloudSync_title
        : name.contains('statistics')
        ? l10n.nav_statistics
        : name.contains('navigate')
        ? l10n.externalAgent_navigation
        : name.contains('settings')
        ? l10n.settings_generation
        : name.contains('generation') ||
              name.contains('inpaint') ||
              name.contains('generate')
        ? l10n.externalAgent_generate
        : name.contains('image') || name.contains('comfyui')
        ? l10n.externalAgent_imageProcessing
        : l10n.externalAgent_application;
    final action = RegExp(r'^(get|list|read|inspect|search)').hasMatch(name)
        ? l10n.externalAgent_read
        : RegExp(r'^(delete|remove|clear)').hasMatch(name)
        ? l10n.externalAgent_delete
        : name.startsWith('prepare')
        ? l10n.externalAgent_prepare
        : RegExp(r'^(create|add|import)').hasMatch(name)
        ? l10n.externalAgent_add
        : name.startsWith('export')
        ? l10n.externalAgent_export
        : RegExp(r'^(set|update|toggle|reorder|move)').hasMatch(name)
        ? l10n.externalAgent_edit
        : RegExp(r'^(cancel|pause|resume|stop)').hasMatch(name)
        ? l10n.externalAgent_control
        : l10n.externalAgent_execute;
    return '$action · $category';
  }

  String _status(ExternalAgentJob job) => switch (job.status) {
    ExternalJobStatus.pending => context.l10n.externalAgent_pending,
    ExternalJobStatus.awaitingApproval =>
      context.l10n.externalAgent_awaitingApproval,
    ExternalJobStatus.running => context.l10n.externalAgent_running,
    ExternalJobStatus.completed => context.l10n.externalAgent_completed,
    ExternalJobStatus.failed => context.l10n.externalAgent_failed,
    ExternalJobStatus.cancelled => context.l10n.externalAgent_cancelled,
    ExternalJobStatus.interrupted => context.l10n.externalAgent_interrupted,
  };
  Widget _job(ExternalAgentJob job, ExternalAgentController controller) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_toolLabel(job), style: Theme.of(context).textTheme.titleSmall),
          Text('${_status(job)} · ${job.createdAt.toLocal()}'),
          if (job.estimatedAnlas != null)
            Text(l10n.externalAgent_estimatedAnlas(job.estimatedAnlas!)),
          if (job.status == ExternalJobStatus.awaitingApproval &&
              job.estimatedAnlas == null)
            Text(l10n.externalAgent_unknownCost),
          if (job.status == ExternalJobStatus.running) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
          ],
          if (job.error != null)
            Text(
              job.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: () => _showResult(job),
                child: Text(l10n.externalAgent_result),
              ),
              if (job.status == ExternalJobStatus.awaitingApproval) ...[
                FilledButton(
                  onPressed: () =>
                      controller.runtime!.resolveApproval(job.id, true),
                  child: Text(l10n.externalAgent_approve),
                ),
                TextButton(
                  onPressed: () =>
                      controller.runtime!.resolveApproval(job.id, false),
                  child: Text(l10n.externalAgent_reject),
                ),
              ],
              if (!job.terminal)
                TextButton(
                  onPressed: job.cancelRequested
                      ? null
                      : () => controller.runtime!.cancel(job.id),
                  child: Text(l10n.externalAgent_cancel),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _connection(
    ExternalAgentConfig config,
    ExternalAgentController controller,
  ) {
    final l10n = context.l10n;
    final addresses = [
      config.localUrl,
      if (config.allowLan)
        ...?controller.server?.lanAddresses.map(
          (a) => 'http://$a:${config.port}',
        ),
    ];
    final address = addresses.contains(_address) ? _address! : addresses.first;
    return SettingsCard(
      title: l10n.externalAgent_connection,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.externalAgent_enable),
              value: config.enabled,
              onChanged: _saving
                  ? null
                  : (v) => _save((c) => c.copyWith(enabled: v)),
            ),
            Text(
              controller.loading
                  ? l10n.externalAgent_starting
                  : controller.server?.listening == true
                  ? l10n.externalAgent_connected
                  : l10n.externalAgent_stopped,
            ),
            if (controller.error != null)
              Text(
                controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.externalAgent_allowLan),
              subtitle: Text(l10n.externalAgent_allowLanDescription),
              value: config.allowLan,
              onChanged: _saving
                  ? null
                  : (v) => _save((c) => c.copyWith(allowLan: v)),
            ),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l10n.externalAgent_port),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _saving
                    ? null
                    : () => _save((c) {
                        final port = int.tryParse(_port.text);
                        if (port == null || port < 1024 || port > 65535) {
                          throw FormatException(l10n.externalAgent_invalidPort);
                        }
                        return c.copyWith(port: port);
                      }),
                child: Text(l10n.externalAgent_save),
              ),
            ),
            const SizedBox(height: 8),
            _clientConfiguration(addresses, address),
            Text(l10n.externalAgent_queueDescription),
          ],
        ),
      ),
    );
  }

  Widget _clientConfiguration(List<String> addresses, String address) {
    final l10n = context.l10n;
    final remote = {'type': 'remote', 'url': '$address/mcp', 'oauth': false};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.externalAgent_address),
        if (addresses.length == 1)
          SelectableText(address)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in addresses)
                TextButton(
                  onPressed: () => setState(() => _address = item),
                  style: TextButton.styleFrom(
                    backgroundColor: address == item
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : null,
                  ),
                  child: Text(item),
                ),
            ],
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: () => _copy('$address/mcp'),
              child: Text(l10n.externalAgent_copyAddress),
            ),
            TextButton(
              onPressed: () =>
                  _copy('[mcp_servers.aaalice]\nurl = "$address/mcp"\n'),
              child: Text(l10n.externalAgent_copyCodex),
            ),
            TextButton(
              onPressed: () => _copy(
                const JsonEncoder.withIndent('  ').convert({
                  'mcp': {'aaalice': remote},
                }),
              ),
              child: Text(l10n.externalAgent_copyOpenCodeLegacy),
            ),
            TextButton(
              onPressed: () => _copy(
                const JsonEncoder.withIndent('  ').convert({
                  'mcp': {
                    'servers': {
                      'aaalice': {
                        'type': 'remote',
                        'url': '$address/mcp',
                        'oauth': false,
                      },
                    },
                  },
                }),
              ),
              child: Text(l10n.externalAgent_copyOpenCode),
            ),
          ],
        ),
      ],
    );
  }

  Widget _permissions(
    ExternalAgentConfig config,
    ExternalAgentController controller,
  ) {
    final l10n = context.l10n;
    final names = {
      ExternalAgentMode.ask: l10n.externalAgent_modeAsk,
      ExternalAgentMode.automatic: l10n.externalAgent_modeAutomatic,
      ExternalAgentMode.full: l10n.externalAgent_modeFull,
    };
    return SettingsCard(
      title: l10n.externalAgent_permissions,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<ExternalAgentMode>(
              initialValue: config.mode,
              isExpanded: true,
              isDense: false,
              itemHeight: null,
              decoration: InputDecoration(
                labelText: l10n.externalAgent_permissions,
              ),
              items: names.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: _saving
                  ? null
                  : (m) => _save((c) => c.copyWith(mode: m)),
            ),
            const SizedBox(height: 12),
            Text(l10n.externalAgent_permissionsDescription),
            const SizedBox(height: 12),
            _limits(config, controller),
          ],
        ),
      ),
    );
  }

  Widget _limits(
    ExternalAgentConfig config,
    ExternalAgentController controller,
  ) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _perCallBudget,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: l10n.externalAgent_perCallBudget,
            helperText: l10n.externalAgent_unlimitedHint,
            helperMaxLines: 3,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _budget,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: l10n.externalAgent_budget,
            helperText: l10n.externalAgent_unlimitedHint,
            helperMaxLines: 3,
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: _saving
                  ? null
                  : () => _save((c) {
                      final value = int.tryParse(_budget.text);
                      final perCall = int.tryParse(_perCallBudget.text);
                      if (value == null ||
                          value < 0 ||
                          perCall == null ||
                          perCall < 0) {
                        throw FormatException(l10n.externalAgent_invalidBudget);
                      }
                      return c.copyWith(budget: value, perCallBudget: perCall);
                    }),
              child: Text(l10n.externalAgent_save),
            ),
            TextButton(
              onPressed: _saving || (controller.runtime?.reserved ?? 0) > 0
                  ? null
                  : () => controller.runtime == null
                        ? _save(
                            (c) => c.copyWith(
                              spent: 0,
                              spentDay: externalAgentDay(DateTime.now()),
                            ),
                          )
                        : _saveAction(controller.runtime!.resetSpent),
              child: Text(l10n.externalAgent_resetSpent),
            ),
          ],
        ),
        Text(
          l10n.externalAgent_spent(
            config.spentOn(DateTime.now()),
            controller.runtime?.reserved ?? 0,
          ),
        ),
        Text(l10n.externalAgent_spentDescription),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(externalAgentConfigProvider),
        controller = ref.watch(externalAgentControllerProvider);
    final jobs =
        controller.runtime?.jobs.values.toList().reversed.toList() ??
        <ExternalAgentJob>[];
    final active = jobs.where((j) => !j.terminal).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return SettingsPageLayout(
      title: context.l10n.externalAgent_title,
      children: [
        _connection(config, controller),
        _permissions(config, controller),
        SettingsCard(
          title: context.l10n.externalAgent_calls,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (jobs.isEmpty) Text(context.l10n.externalAgent_noCalls),
                for (final job in active) _job(job, controller),
                for (final job in jobs.where((j) => j.terminal).take(20))
                  _job(job, controller),
              ],
            ),
          ),
        ),
        SettingsCard(
          child: SwitchListTile.adaptive(
            title: Text(context.l10n.externalAgent_builtIn),
            value: config.builtInEnabled,
            onChanged: _saving
                ? null
                : (v) => _save((c) => c.copyWith(builtInEnabled: v)),
          ),
        ),
      ],
    );
  }
}
