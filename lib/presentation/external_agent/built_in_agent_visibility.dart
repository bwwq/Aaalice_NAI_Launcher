import 'package:flutter/widgets.dart';

class BuiltInAgentVisibility extends InheritedWidget {
  const BuiltInAgentVisibility({
    super.key,
    required this.enabled,
    required super.child,
  });
  final bool enabled;
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<BuiltInAgentVisibility>()
          ?.enabled ??
      false;
  @override
  bool updateShouldNotify(BuiltInAgentVisibility oldWidget) =>
      enabled != oldWidget.enabled;
}
