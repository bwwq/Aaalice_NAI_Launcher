import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_launcher/core/watermark/watermark_contrast.dart';
import 'package:nai_launcher/core/watermark/watermark_render_service.dart';
import 'package:nai_launcher/core/watermark/watermark_scene.dart';
import 'package:nai_launcher/data/models/watermark/watermark_settings.dart';
import 'package:nai_launcher/presentation/screens/watermark/watermark_editor_controls.dart';
import 'package:nai_launcher/presentation/screens/watermark/watermark_preview_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'turning off text adaptation restores its stored color; zero alpha leaves no stroke',
    () async {
      final source = _solid(300, 150, img.ColorRgba8(255, 255, 255, 255));
      const text = WatermarkTextStyle(
        text: 'ART',
        autoContrast: false,
        colorArgb: 0xFFFF0000,
        opacity: 1,
        strokeWidthRatio: 0,
        shadowBlurRatio: 0,
        shadowOffsetXRatio: 0,
        shadowOffsetYRatio: 0,
      );
      final base = _settings(WatermarkAnchor.center).copyWith(
        textStyle: text,
        logoStyle: const WatermarkLogoStyle(enabled: false),
      );
      final manual = await _render(source, _logo(), base);
      expect(
        manual.image.where((p) => p.r > 240 && p.g < 10).length,
        greaterThan(20),
      );
      final automatic = await _render(
        source,
        _logo(),
        base.copyWith(textStyle: text.copyWith(autoContrast: true)),
      );
      expect(
        automatic.image.where((p) => p.r < 10 && p.g < 10).length,
        greaterThan(20),
      );
      final hidden = await _render(
        source,
        _logo(),
        base.copyWith(textStyle: text.copyWith(autoContrast: true, opacity: 0)),
      );
      expect(
        hidden.image.every((p) => p.r == 255 && p.g == 255 && p.b == 255),
        isTrue,
      );
    },
  );

  test(
    'real preview painter keeps export colors when viewport size changes',
    () async {
      final source = _background(400, 200);
      final logoBytes = _logo();
      final background = await WatermarkContrastPixels.decode(source);
      final mask = await WatermarkContrastPixels.decode(logoBytes);
      final codec = await ui.instantiateImageCodec(logoBytes);
      final logo = (await codec.getNextFrame()).image;
      addTearDown(() {
        logo.dispose();
        codec.dispose();
      });
      final settings = _settings(WatermarkAnchor.centerRight);
      final painter = WatermarkPreviewPainter(
        settings: settings,
        logo: logo,
        background: background,
        logoMask: mask,
        sourceSize: background.sourceSize,
        selectedLayer: WatermarkEditableLayer.logo,
        selectionColor: Colors.transparent,
      );
      for (final size in [const Size(100, 50), const Size(800, 400)]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
        canvas.drawRect(
          Rect.fromLTWH(0, 0, size.width / 2, size.height),
          Paint()..color = Colors.black,
        );
        painter.paint(canvas, size);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          size.width.toInt(),
          size.height.toInt(),
        );
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final pixels = img.decodePng(bytes.buffer.asUint8List())!;
        // Source-space logo center: (350, 100), mapped to the actual viewport.
        expect(
          pixels
              .getPixel((size.width * 0.875).floor(), (size.height / 2).floor())
              .r,
          lessThan(10),
        );
        expect(
          pixels
              .getPixel((size.width * 0.55).floor(), (size.height / 2).floor())
              .r,
          greaterThan(245),
        );
        image.dispose();
        picture.dispose();
      }
    },
  );

  test(
    'analysis is bounded and uses each layer region, not whole-image color',
    () async {
      final pixels = await WatermarkContrastPixels.decode(
        _background(1200, 800),
      );
      expect(pixels.width, 512);
      expect(pixels.height, lessThanOrEqualTo(512));
      expect(pixels.sourceSize, const Size(1200, 800));
      expect(
        pixels.foreground(const Rect.fromLTWH(0, 0, 0.4, 1)),
        Colors.white,
      );
      expect(
        pixels.foreground(const Rect.fromLTWH(0.6, 0, 0.4, 1)),
        Colors.black,
      );
    },
  );

  test(
    'logo alpha masks exclude transparent padding from the decision',
    () async {
      final source = await WatermarkContrastPixels.decode(
        _background(200, 100),
      );
      final logo = img.Image(width: 64, height: 64, numChannels: 4);
      img.fillRect(
        logo,
        alphaBlend: false,
        x1: 0,
        y1: 0,
        x2: 7,
        y2: 63,
        color: img.ColorRgba8(255, 0, 0, 255),
      );
      final mask = await WatermarkContrastPixels.decode(
        Uint8List.fromList(img.encodePng(logo)),
      );
      expect(
        source.foreground(const Rect.fromLTWH(0, 0, 1, 1), mask: mask),
        Colors.white,
      );
      img.fill(logo, color: img.ColorRgba8(0, 0, 0, 0));
      img.fillRect(
        logo,
        alphaBlend: false,
        x1: 56,
        y1: 0,
        x2: 63,
        y2: 63,
        color: img.ColorRgba8(255, 0, 0, 128),
      );
      final rightMask = await WatermarkContrastPixels.decode(
        Uint8List.fromList(img.encodePng(logo)),
      );
      expect(
        source.foreground(const Rect.fromLTWH(0, 0, 1, 1), mask: rightMask),
        Colors.black,
      );
    },
  );

  test(
    'empty evidence chooses white without flattening transparent pixels',
    () async {
      final source = _solid(200, 100, img.ColorRgba8(0, 0, 0, 0));
      final pixels = await WatermarkContrastPixels.decode(source);
      expect(pixels.foreground(const Rect.fromLTWH(0, 0, 1, 1)), Colors.white);
      final logoBytes = _logo(alpha: 128);
      expect(img.decodePng(logoBytes)!.getPixel(32, 32).a, 128);
      final output = await _render(
        source,
        logoBytes,
        _settings(WatermarkAnchor.center),
      );
      expect(output.image.getPixel(0, 0).a, 0);
      expect(output.image.getPixel(100, 50).a, closeTo(128, 2));
    },
  );

  test('actual pixels switch from white to black when moving a logo', () async {
    final source = _background(400, 200);
    for (final anchor in [
      WatermarkAnchor.centerLeft,
      WatermarkAnchor.centerRight,
    ]) {
      final output = await _render(source, _logo(), _settings(anchor));
      final center = output.scene.boundsFor(WatermarkLayerKind.logo)!.center;
      final pixel = output.image.getPixel(center.dx.floor(), center.dy.floor());
      expect(
        pixel.r,
        anchor == WatermarkAnchor.centerLeft ? greaterThan(245) : lessThan(10),
      );
      expect(pixel.g, pixel.r);
      expect(pixel.b, pixel.r);
    }
  });

  test(
    'manual logo colors, opaque logo colors and opacity survive rendering',
    () async {
      final source = _solid(200, 100, img.ColorRgba8(0, 0, 0, 255));
      final base = _settings(WatermarkAnchor.center);
      final manual = await _render(
        source,
        _logo(),
        base.copyWith(logoStyle: base.logoStyle.copyWith(autoContrast: false)),
      );
      expect(manual.image.getPixel(100, 50).r, greaterThan(245));
      expect(manual.image.getPixel(100, 50).g, lessThan(10));
      final opaque = await _render(source, _logo(opaque: true), base);
      expect(opaque.image.getPixel(100, 50).r, greaterThan(245));
      expect(opaque.image.getPixel(100, 50).g, lessThan(10));
      final transparent = await _render(
        source,
        _logo(),
        base.copyWith(logoStyle: base.logoStyle.copyWith(opacity: 0)),
      );
      expect(
        transparent.image.every(
          (pixel) => pixel.r == 0 && pixel.g == 0 && pixel.b == 0,
        ),
        isTrue,
      );
      final half = await _render(
        source,
        _logo(),
        base.copyWith(logoStyle: base.logoStyle.copyWith(opacity: 0.5)),
      );
      expect(half.image.getPixel(100, 50).r, closeTo(128, 2));
    },
  );

  test(
    'text and logo independently adapt on opposite sides of one image',
    () async {
      final base = _settings(WatermarkAnchor.centerLeft);
      final settings = base.copyWith(
        textStyle: const WatermarkTextStyle(
          text: 'ART',
          fontFamily: 'Roboto',
          opacity: 1,
          shadowBlurRatio: 0,
          shadowOffsetXRatio: 0,
          shadowOffsetYRatio: 0,
        ),
      );
      final output = await _render(_background(400, 200), _logo(), settings);
      final logoCenter = output.scene
          .boundsFor(WatermarkLayerKind.logo)!
          .center;
      expect(
        output.image.getPixel(logoCenter.dx.floor(), logoCenter.dy.floor()).r,
        greaterThan(245),
      );
      final textBounds = output.scene.boundsFor(WatermarkLayerKind.text)!;
      var darkTextPixels = 0;
      for (var y = textBounds.top.ceil(); y < textBounds.bottom.floor(); y++) {
        for (
          var x = textBounds.left.ceil();
          x < textBounds.right.floor();
          x++
        ) {
          if (output.image.getPixel(x, y).r < 20) darkTextPixels++;
        }
      }
      expect(darkTextPixels, greaterThan(20));
    },
  );

  test('preview and exported PNG use the same colors and geometry', () async {
    final source = _background(400, 200);
    final logo = _logo();
    final settings = _settings(WatermarkAnchor.centerRight);
    final preview = await _render(source, logo, settings);
    final exported = await WatermarkRenderService.render(
      WatermarkRenderRequest(
        sourceBytes: source,
        logoBytes: logo,
        settings: settings,
        preserveMetadata: false,
      ),
    );
    final decoded = img.decodePng(exported.bytes)!;
    for (var y = 0; y < decoded.height; y++) {
      for (var x = 0; x < decoded.width; x++) {
        final a = preview.image.getPixel(x, y);
        final b = decoded.getPixel(x, y);
        expect((a.r - b.r).abs(), lessThanOrEqualTo(1));
        expect((a.a - b.a).abs(), lessThanOrEqualTo(1));
      }
    }
  });

  test(
    'grouped layout paints inside resolved bounds at multiple aspect ratios',
    () async {
      for (final size in [const Size(240, 400), const Size(400, 240)]) {
        for (final arrangement in [
          WatermarkLayerArrangement.horizontal,
          WatermarkLayerArrangement.vertical,
        ]) {
          final base = _settings(WatermarkAnchor.center);
          final settings = base.copyWith(
            textStyle: const WatermarkTextStyle(
              text: 'A LONG SIGNATURE',
              opacity: 1,
              shadowBlurRatio: 0,
            ),
            composition: WatermarkComposition(arrangement: arrangement),
            universalLayout: base.universalLayout.copyWith(
              textPlacement: base.universalLayout.textPlacement.copyWith(
                anchor: WatermarkAnchor.center,
                sizeRatio: 0.4,
              ),
              logoPlacement: base.universalLayout.logoPlacement.copyWith(
                sizeRatio: 0.9,
              ),
            ),
          );
          final output = await _render(
            _solid(
              size.width.toInt(),
              size.height.toInt(),
              img.ColorRgba8(0, 0, 0, 255),
            ),
            _logo(),
            settings,
          );
          for (final layer in output.scene.layers) {
            expect(layer.bounds.left, greaterThanOrEqualTo(0));
            expect(layer.bounds.right, lessThanOrEqualTo(size.width + 0.01));
            expect(layer.bounds.bottom, lessThanOrEqualTo(size.height + 0.01));
          }
          final center = output.scene
              .boundsFor(WatermarkLayerKind.logo)!
              .center;
          const original = 0;
          expect(
            (output.image.getPixel(center.dx.floor(), center.dy.floor()).r -
                    original)
                .abs(),
            greaterThan(200),
          );
        }
      }
    },
  );

  test(
    'colored and gradient backgrounds retain contrasting watermark pixels',
    () async {
      for (final color in [
        img.ColorRgba8(0, 0, 0, 255),
        img.ColorRgba8(255, 255, 255, 255),
        img.ColorRgba8(20, 40, 100, 255),
        img.ColorRgba8(255, 230, 180, 255),
      ]) {
        final output = await _render(
          _solid(200, 100, color),
          _logo(),
          _settings(WatermarkAnchor.center),
        );
        final pixel = output.image.getPixel(100, 50);
        expect((pixel.g - color.g).abs(), greaterThan(150));
      }
      final gradient = img.Image(width: 400, height: 200, numChannels: 4);
      for (final pixel in gradient) {
        final value = (pixel.x * 255 / 399).round();
        pixel.setRgba(value, value, value, 255);
      }
      final output = await _render(
        Uint8List.fromList(img.encodePng(gradient)),
        _logo(),
        _settings(WatermarkAnchor.centerLeft),
      );
      final bounds = output.scene.boundsFor(WatermarkLayerKind.logo)!;
      expect(
        output.image
            .getPixel(bounds.center.dx.floor(), bounds.center.dy.floor())
            .r,
        greaterThan(245),
      );
      // Optional local QA artifact, never a tracked fixture.
      if (Platform.environment['WATERMARK_QA'] == '1') {
        final dir = Directory('tool/.tmp/watermark-qa')
          ..createSync(recursive: true);
        File(
          '${dir.path}/gradient.png',
        ).writeAsBytesSync(img.encodePng(output.image));
        final mixed = await _render(
          _background(400, 200),
          _logo(),
          _settings(WatermarkAnchor.center),
        );
        File(
          '${dir.path}/mixed.png',
        ).writeAsBytesSync(img.encodePng(mixed.image));
      }
    },
  );
}

WatermarkSettings _settings(WatermarkAnchor anchor) => WatermarkSettings(
  textStyle: const WatermarkTextStyle(enabled: false),
  logoStyle: const WatermarkLogoStyle(enabled: true, opacity: 1),
  universalLayout: WatermarkSettings.defaultLayout.copyWith(
    logoPlacement: WatermarkSettings.defaultLogoPlacement.copyWith(
      anchor: anchor,
      sizeRatio: 0.4,
      marginRatio: 0.05,
    ),
    textPlacement: WatermarkSettings.defaultTextPlacement.copyWith(
      anchor: WatermarkAnchor.centerRight,
      sizeRatio: 0.15,
      marginRatio: 0.05,
    ),
  ),
);

Uint8List _solid(int width, int height, img.Color color) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: color);
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _background(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (final pixel in image) {
    final value = pixel.x < width / 2 ? 0 : 255;
    pixel.setRgba(value, value, value, 255);
  }
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _logo({int alpha = 255, bool opaque = false}) {
  final image = img.Image(width: 64, height: 64, numChannels: 4);
  if (opaque) {
    img.fill(image, color: img.ColorRgba8(255, 0, 0, 255));
  } else {
    img.fillRect(
      image,
      alphaBlend: false,
      x1: 8,
      y1: 8,
      x2: 55,
      y2: 55,
      color: img.ColorRgba8(255, 0, 0, alpha),
    );
  }
  return Uint8List.fromList(img.encodePng(image));
}

Future<({img.Image image, WatermarkSceneResult scene})> _render(
  Uint8List source,
  Uint8List logoBytes,
  WatermarkSettings settings,
) async {
  final background = await WatermarkContrastPixels.decode(source);
  final mask = await WatermarkContrastPixels.decode(logoBytes);
  final sourceCodec = await ui.instantiateImageCodec(source);
  final logoCodec = await ui.instantiateImageCodec(logoBytes);
  final sourceImage = (await sourceCodec.getNextFrame()).image;
  final logo = (await logoCodec.getNextFrame()).image;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawImage(sourceImage, Offset.zero, Paint());
  final scene = WatermarkScene.paint(
    canvas: canvas,
    canvasSize: background.sourceSize,
    settings: settings,
    logo: logo,
    background: background,
    logoMask: mask,
  );
  final picture = recorder.endRecording();
  final output = await picture.toImage(sourceImage.width, sourceImage.height);
  final bytes = (await output.toByteData(format: ui.ImageByteFormat.png))!;
  final image = img.decodePng(bytes.buffer.asUint8List())!;
  output.dispose();
  picture.dispose();
  logo.dispose();
  sourceImage.dispose();
  sourceCodec.dispose();
  logoCodec.dispose();
  return (image: image, scene: scene);
}
