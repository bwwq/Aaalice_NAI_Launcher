import 'dart:convert';

enum ExternalAgentMode { ask, automatic, full }

class ExternalAgentConfig {
  const ExternalAgentConfig({
    this.enabled = false,
    this.allowLan = false,
    this.port = 39123,
    this.mode = ExternalAgentMode.ask,
    this.budget = 0,
    this.spent = 0,
    this.builtInEnabled = false,
  });
  final bool enabled, allowLan, builtInEnabled;
  final int port, budget, spent;
  final ExternalAgentMode mode;
  String get bindAddress => allowLan ? '0.0.0.0' : '127.0.0.1';
  String get localUrl => 'http://127.0.0.1:$port';
  ExternalAgentConfig copyWith({
    bool? enabled,
    bool? allowLan,
    int? port,
    ExternalAgentMode? mode,
    int? budget,
    int? spent,
    bool? builtInEnabled,
  }) => ExternalAgentConfig(
    enabled: enabled ?? this.enabled,
    allowLan: allowLan ?? this.allowLan,
    port: port ?? this.port,
    mode: mode ?? this.mode,
    budget: budget ?? this.budget,
    spent: spent ?? this.spent,
    builtInEnabled: builtInEnabled ?? this.builtInEnabled,
  );
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'allowLan': allowLan,
    'port': port,
    'mode': mode.name,
    'budget': budget,
    'spent': spent,
    'builtInEnabled': builtInEnabled,
  };
  factory ExternalAgentConfig.fromJson(Map<String, dynamic> json) =>
      ExternalAgentConfig(
        enabled: json['enabled'] == true,
        allowLan: json['allowLan'] == true,
        port: (json['port'] as int? ?? 39123).clamp(1024, 65535),
        mode: ExternalAgentMode.values.firstWhere(
          (m) => m.name == json['mode'],
          orElse: () => ExternalAgentMode.ask,
        ),
        budget: (json['budget'] as int? ?? 0).clamp(0, 1 << 30),
        spent: (json['spent'] as int? ?? 0).clamp(0, 1 << 30),
        builtInEnabled: json['builtInEnabled'] == true,
      );
}

enum ExternalJobStatus {
  pending,
  awaitingApproval,
  running,
  completed,
  failed,
  cancelled,
  interrupted,
}

class ExternalAgentJob {
  ExternalAgentJob({
    required this.id,
    required this.tool,
    required this.arguments,
    this.requestId,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
  final String id, tool;
  final String? requestId;
  final Map<String, dynamic> arguments;
  final DateTime createdAt;
  ExternalJobStatus status = ExternalJobStatus.pending;
  DateTime? finishedAt;
  Map<String, dynamic>? result;
  Map<String, dynamic>? progress;
  bool cancelRequested = false;
  String? error, approvalReason;
  int? estimatedAnlas;
  int dispatchedAnlas = 0;
  bool get terminal => const {
    ExternalJobStatus.completed,
    ExternalJobStatus.failed,
    ExternalJobStatus.cancelled,
    ExternalJobStatus.interrupted,
  }.contains(status);
  Map<String, dynamic> toJson() => {
    'job_id': id,
    'tool': tool,
    'arguments': arguments,
    if (requestId != null) 'request_id': requestId,
    'status': status.name,
    'created_at': createdAt.toIso8601String(),
    if (finishedAt != null) 'finished_at': finishedAt!.toIso8601String(),
    'estimated_anlas': estimatedAnlas,
    'dispatched_anlas': dispatchedAnlas,
    'cancel_requested': cancelRequested,
    if (progress != null) 'progress': progress,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
    if (approvalReason != null) 'approval_reason': approvalReason,
  };
  factory ExternalAgentJob.fromJson(Map<String, dynamic> json) {
    final job = ExternalAgentJob(
      id: json['job_id'] as String,
      tool: json['tool'] as String,
      arguments: Map<String, dynamic>.from(json['arguments'] as Map),
      requestId: json['request_id'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
    job.status = ExternalJobStatus.values.firstWhere(
      (s) => s.name == json['status'],
    );
    job.finishedAt = DateTime.tryParse(json['finished_at'] as String? ?? '');
    job.result = json['result'] == null
        ? null
        : Map<String, dynamic>.from(json['result'] as Map);
    job.error = json['error'] as String?;
    job.dispatchedAnlas = json['dispatched_anlas'] as int? ?? 0;
    if (!job.terminal) {
      job.status = ExternalJobStatus.interrupted;
      job.error = 'Application restarted; request was not replayed.';
    }
    return job;
  }
  String get fingerprint =>
      jsonEncode(_canonical({'tool': tool, 'arguments': arguments}));
}

dynamic _canonical(dynamic value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

class ExternalAgentException implements Exception {
  const ExternalAgentException(this.code, this.message);
  final String code, message;
  @override
  String toString() => '$code: $message';
}
