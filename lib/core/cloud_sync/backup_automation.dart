class BackupAutomationPreferences {
  const BackupAutomationPreferences({
    this.scheduled = false,
    this.minuteOfDay = 1200,
    this.onChange = false,
    this.delayMinutes = 5,
  });
  final bool scheduled;
  final int minuteOfDay;
  final bool onChange;
  final int delayMinutes;

  BackupAutomationPreferences copyWith({
    bool? scheduled,
    int? minuteOfDay,
    bool? onChange,
    int? delayMinutes,
  }) => BackupAutomationPreferences(
    scheduled: scheduled ?? this.scheduled,
    minuteOfDay: minuteOfDay ?? this.minuteOfDay,
    onChange: onChange ?? this.onChange,
    delayMinutes: delayMinutes ?? this.delayMinutes,
  );

  Map<String, Object> toJson() => {
    'scheduled': scheduled,
    'minuteOfDay': minuteOfDay,
    'onChange': onChange,
    'delayMinutes': delayMinutes,
  };
  factory BackupAutomationPreferences.fromJson(Map<String, dynamic> value) {
    final minute = value['minuteOfDay'] as int? ?? 1200;
    final delay = value['delayMinutes'] as int? ?? 5;
    if (minute < 0 || minute >= 1440 || delay < 1 || delay > 1440) {
      throw const FormatException('Invalid backup schedule.');
    }
    return BackupAutomationPreferences(
      scheduled: value['scheduled'] as bool? ?? false,
      minuteOfDay: minute,
      onChange: value['onChange'] as bool? ?? false,
      delayMinutes: delay,
    );
  }
}

/// Clock-driven policy; the host owns timers, persistence and upload execution.
class BackupAutomation {
  BackupAutomation({
    required this.now,
    required this.upload,
    required this.canRun,
    required this.changed,
  });
  final DateTime Function() now;
  final Future<void> Function() upload;
  final bool Function() canRun;
  final void Function() changed;
  BackupAutomationPreferences preferences = const BackupAutomationPreferences();
  DateTime? pendingChange;
  DateTime? nextScheduled;
  DateTime? retryAt;
  DateTime? lastSuccess;
  bool running = false;
  bool failed = false;
  bool disposed = false;
  int _generation = 0;

  DateTime _nextDaily(DateTime time) {
    final local = time.toLocal();
    var candidate = DateTime(
      local.year,
      local.month,
      local.day,
      preferences.minuteOfDay ~/ 60,
      preferences.minuteOfDay % 60,
    );
    if (!candidate.isAfter(local)) {
      candidate = DateTime(
        local.year,
        local.month,
        local.day + 1,
        preferences.minuteOfDay ~/ 60,
        preferences.minuteOfDay % 60,
      );
    }
    return candidate;
  }

  void configure(BackupAutomationPreferences value) {
    final valid = BackupAutomationPreferences.fromJson(value.toJson());
    final scheduleChanged =
        valid.scheduled != preferences.scheduled ||
        valid.minuteOfDay != preferences.minuteOfDay;
    preferences = valid;
    if (!valid.scheduled) {
      nextScheduled = null;
    } else if (scheduleChanged || nextScheduled == null) {
      nextScheduled = _nextDaily(now());
    }
    if (!valid.onChange) {
      pendingChange = null;
    } else if (pendingChange != null) {
      pendingChange = now().add(Duration(minutes: valid.delayMinutes));
    }
    retryAt = null;
    failed = false;
    changed();
  }

  void markChanged() {
    if (disposed || !preferences.onChange) return;
    _generation++;
    pendingChange = now().add(Duration(minutes: preferences.delayMinutes));
    changed();
  }

  void cancelPending() {
    _generation++;
    pendingChange = null;
    retryAt = null;
    failed = false;
    if (preferences.scheduled) nextScheduled = _nextDaily(now());
    changed();
  }

  DateTime? get nextRun {
    // Even a scheduled run must respect the user's edit grace period.
    final first = pendingChange ?? nextScheduled;
    if (first == null) return null;
    return retryAt != null && retryAt!.isAfter(first) ? retryAt : first;
  }

  Future<void> tick() async {
    final due = nextRun;
    if (disposed ||
        running ||
        due == null ||
        now().isBefore(due) ||
        !canRun()) {
      return;
    }
    running = true;
    final generation = _generation;
    final scheduledDue =
        nextScheduled != null && !now().isBefore(nextScheduled!);
    changed();
    try {
      await upload();
      if (disposed) return;
      lastSuccess = now();
      failed = false;
      retryAt = null;
      if (generation == _generation) pendingChange = null;
      if (scheduledDue && preferences.scheduled) {
        nextScheduled = _nextDaily(now());
      }
    } catch (_) {
      if (disposed) return;
      failed = true;
      retryAt = now().add(const Duration(minutes: 5));
    } finally {
      running = false;
      if (!disposed) changed();
    }
  }

  void dispose() {
    disposed = true;
  }
}
