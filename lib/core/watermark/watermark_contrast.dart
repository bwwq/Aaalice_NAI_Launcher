import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Immutable, bounded analysis pixels. Both preview and export decode the
/// original bytes here; screen resolution never participates in color choice.
class WatermarkContrastPixels {
  WatermarkContrastPixels._(
    this.width,
    this.height,
    this.sourceSize,
    this._rgba,
  ) : hasTransparency = _hasTransparency(_rgba);

  final int width;
  final int height;
  final ui.Size sourceSize;
  final Uint8List _rgba;
  final bool hasTransparency;

  // Trace the occupied mask boundary once. Stroking this path leaves the fill's
  // original alpha intact, including large semi-transparent interiors.
  late final ui.Path outline = _traceOutline();

  ui.Path _traceOutline() {
    final path = ui.Path();
    bool occupied(int x, int y) =>
        x >= 0 &&
        y >= 0 &&
        x < width &&
        y < height &&
        _rgba[(y * width + x) * 4 + 3] > 0;
    void edge(double x, double y, double dx, double dy) {
      path.moveTo(x, y);
      path.lineTo(x + dx, y + dy);
    }

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (!occupied(x, y)) continue;
        if (!occupied(x - 1, y)) edge(x.toDouble(), y.toDouble(), 0, 1);
        if (!occupied(x + 1, y)) edge(x + 1.0, y.toDouble(), 0, 1);
        if (!occupied(x, y - 1)) edge(x.toDouble(), y.toDouble(), 1, 0);
        if (!occupied(x, y + 1)) edge(x.toDouble(), y + 1.0, 1, 0);
      }
    }
    return path;
  }

  static Future<WatermarkContrastPixels> decode(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final scale = math.min(
        1.0,
        512 / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) {
        throw StateError('Cannot read watermark analysis pixels.');
      }
      return WatermarkContrastPixels._(
        image.width,
        image.height,
        ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble()),
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static bool _hasTransparency(Uint8List rgba) {
    for (var i = 3; i < rgba.length; i += 4) {
      if (rgba[i] < 255) return true;
    }
    return false;
  }

  static final _linear = List<double>.generate(256, (i) {
    final value = i / 255;
    return value <= 0.04045
        ? value / 12.92
        : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  });

  int _offset(double x, double y) =>
      ((y * height).floor().clamp(0, height - 1) * width +
          (x * width).floor().clamp(0, width - 1)) *
      4;

  /// [bounds] are normalized to the image, after the final layout is resolved.
  /// Transparent source pixels carry no evidence about the eventual backdrop.
  ui.Color foreground(ui.Rect bounds, {WatermarkContrastPixels? mask}) {
    var black = 0.0;
    var white = 0.0;
    // Fixed layer-space sampling makes the result independent of viewport size
    // and retains small logos that occupy less than one analysis-image pixel.
    const samples = 64;
    for (var y = 0; y < samples; y++) {
      final v = (y + 0.5) / samples;
      for (var x = 0; x < samples; x++) {
        final u = (x + 0.5) / samples;
        final px = bounds.left + bounds.width * u;
        final py = bounds.top + bounds.height * v;
        if (px < 0 || px > 1 || py < 0 || py > 1) continue;
        final offset = _offset(px, py);
        final maskAlpha = mask == null
            ? 1.0
            : mask._rgba[mask._offset(u, v) + 3] / 255;
        final weight = maskAlpha * _rgba[offset + 3] / 255;
        if (weight == 0) continue;
        final luminance =
            0.2126 * _linear[_rgba[offset]] +
            0.7152 * _linear[_rgba[offset + 1]] +
            0.0722 * _linear[_rgba[offset + 2]];
        black += weight * (luminance + 0.05) / 0.05;
        white += weight * 1.05 / (luminance + 0.05);
      }
    }
    return black > white
        ? const ui.Color(0xFF000000)
        : const ui.Color(0xFFFFFFFF);
  }
}
