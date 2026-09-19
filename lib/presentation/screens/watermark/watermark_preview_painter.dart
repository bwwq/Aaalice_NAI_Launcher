import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/watermark/watermark_contrast.dart';
import '../../../core/watermark/watermark_scene.dart';
import '../../../data/models/watermark/watermark_settings.dart';
import 'watermark_editor_controls.dart';

class WatermarkPreviewPainter extends CustomPainter {
  const WatermarkPreviewPainter({
    required this.settings,
    required this.logo,
    required this.selectedLayer,
    required this.selectionColor,
    required this.background,
    required this.logoMask,
    required this.sourceSize,
  });

  final WatermarkSettings settings;
  final ui.Image? logo;
  final WatermarkEditableLayer selectedLayer;
  final Color selectionColor;
  final WatermarkContrastPixels background;
  final WatermarkContrastPixels? logoMask;
  final Size sourceSize;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(
      size.width / sourceSize.width,
      size.height / sourceSize.height,
    );
    final result = WatermarkScene.paint(
      canvas: canvas,
      canvasSize: sourceSize,
      settings: settings,
      logo: logo,
      background: background,
      logoMask: logoMask,
    );
    canvas.restore();
    final kind = selectedLayer == WatermarkEditableLayer.text
        ? WatermarkLayerKind.text
        : WatermarkLayerKind.logo;
    final rawBounds = result.boundsFor(kind);
    final bounds = rawBounds == null
        ? null
        : Rect.fromLTRB(
            rawBounds.left * size.width / sourceSize.width,
            rawBounds.top * size.height / sourceSize.height,
            rawBounds.right * size.width / sourceSize.width,
            rawBounds.bottom * size.height / sourceSize.height,
          );
    if (bounds != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(bounds.inflate(4), const Radius.circular(4)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = selectionColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WatermarkPreviewPainter oldDelegate) =>
      oldDelegate.settings != settings ||
      oldDelegate.background != background ||
      oldDelegate.logoMask != logoMask ||
      oldDelegate.sourceSize != sourceSize ||
      oldDelegate.logo != logo ||
      oldDelegate.selectedLayer != selectedLayer ||
      oldDelegate.selectionColor != selectionColor;
}
