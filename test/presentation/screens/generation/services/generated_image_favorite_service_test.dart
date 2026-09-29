import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/services/gallery/local_gallery_service.dart';
import 'package:nai_launcher/presentation/providers/image_generation_provider.dart';
import 'package:nai_launcher/presentation/providers/local_gallery_provider.dart';
import 'package:nai_launcher/presentation/providers/local_image_favorite_provider.dart';
import 'package:nai_launcher/presentation/screens/generation/services/generated_image_favorite_service.dart';

void main() {
  test(
    'concurrent preview/history clicks save and toggle once; later clicks reuse the file',
    () async {
      final temp = await Directory.systemTemp.createTemp('generated_favorite_');
      addTearDown(() => temp.delete(recursive: true));
      var image = _image();
      final gate = Completer<void>();
      var saves = 0;
      var toggles = 0;
      var favorite = false;
      final service = GeneratedImageFavoriteService(
        resolveImage: (_) => image,
        saveImage: (value) async {
          saves++;
          await gate.future;
          final file = File('${temp.path}/image.png');
          await file.writeAsBytes(value.bytes);
          return file.path;
        },
        registerImage: (value, path) async {
          image = value.copyWithFilePath(path);
        },
        toggleFavorite: (path) async {
          expect(await File(path).readAsBytes(), image.bytes);
          toggles++;
          return favorite = !favorite;
        },
      );
      final first = service.toggle(image);
      final second = service.toggle(image);
      expect(identical(first, second), isTrue);
      gate.complete();
      expect(await first, isTrue);
      expect(saves, 1);
      expect(toggles, 1);
      expect(await service.toggle(image), isFalse);
      expect(saves, 1);
      expect(toggles, 2);
    },
  );

  test('failed persistence does not toggle and permits retry', () async {
    var attempts = 0;
    final service = GeneratedImageFavoriteService(
      resolveImage: (_) => null,
      saveImage: (_) async {
        attempts++;
        throw const FileSystemException('disk full');
      },
      registerImage: (_, _) async => fail('must not register'),
      toggleFavorite: (_) async => throw StateError('must not toggle'),
    );
    await expectLater(
      service.toggle(_image()),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      service.toggle(_image()),
      throwsA(isA<FileSystemException>()),
    );
    expect(attempts, 2);
    await expectLater(
      service.toggle(_image(kind: GeneratedImageKind.failedStreamSnapshot)),
      throwsStateError,
    );
  });

  test(
    'gallery mutation updates every favorite reader, errors never mean unfavorite',
    () async {
      final service = _GalleryService();
      final container = ProviderContainer(
        overrides: [
          localGalleryNotifierProvider.overrideWith(
            () => _GalleryNotifier(service),
          ),
          imageGenerationNotifierProvider.overrideWith(
            () =>
                _GenerationNotifier(_image().copyWithFilePath('/favorite.png')),
          ),
        ],
      );
      addTearDown(container.dispose);
      final local = container.listen(
        localImageFavoriteProvider('/favorite.png'),
        (_, _) {},
      );
      final generated = container.listen(
        generatedImageFavoriteProvider('result'),
        (_, _) {},
      );
      addTearDown(local.close);
      addTearDown(generated.close);
      expect(
        await container.read(generatedImageFavoriteProvider('result').future),
        isFalse,
      );
      final gallery = container.read(localGalleryNotifierProvider.notifier);
      expect(
        await gallery.toggleFavorite('/favorite.png', rethrowError: true),
        isTrue,
      );
      expect(
        await container.read(
          localImageFavoriteProvider('/favorite.png').future,
        ),
        isTrue,
      );
      expect(
        await container.read(generatedImageFavoriteProvider('result').future),
        isTrue,
      );
      service.failWrites = true;
      await expectLater(
        gallery.toggleFavorite('/favorite.png', rethrowError: true),
        throwsStateError,
      );
      expect(
        await container.read(generatedImageFavoriteProvider('result').future),
        isTrue,
      );
    },
  );
}

GeneratedImage _image({
  GeneratedImageKind kind = GeneratedImageKind.completed,
}) => GeneratedImage(
  id: 'result',
  bytes: Uint8List.fromList([1, 2, 3]),
  width: 1,
  height: 1,
  kind: kind,
);

class _GalleryService extends Fake implements LocalGalleryService {
  bool favorite = false;
  bool failWrites = false;
  @override
  Future<bool> isFavorite(String filePath) async => favorite;
  @override
  Future<bool> toggleFavorite(String filePath) async {
    if (failWrites) throw StateError('write failed');
    return favorite = !favorite;
  }
}

class _GalleryNotifier extends LocalGalleryNotifier {
  _GalleryNotifier(this.service);
  final LocalGalleryService service;
  @override
  LocalGalleryState build() => const LocalGalleryState();
  @override
  Future<LocalGalleryService> getService() async => service;
}

class _GenerationNotifier extends ImageGenerationNotifier {
  _GenerationNotifier(this.image);
  final GeneratedImage image;
  @override
  ImageGenerationState build() => ImageGenerationState(history: [image]);
}
