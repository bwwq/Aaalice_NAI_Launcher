import 'package:flutter/services.dart';

/// Unmodified arrows adjust a selected prompt; modifiers retain native editing.
double? promptWeightArrowStep(KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isControlPressed ||
      keyboard.isMetaPressed ||
      keyboard.isAltPressed ||
      keyboard.isShiftPressed) {
    return null;
  }
  return switch (event.logicalKey) {
    LogicalKeyboardKey.arrowUp => 0.05,
    LogicalKeyboardKey.arrowDown => -0.05,
    _ => null,
  };
}
