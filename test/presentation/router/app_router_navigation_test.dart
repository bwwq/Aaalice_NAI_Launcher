import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nai_launcher/core/shortcuts/shortcut_config.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/presentation/providers/online_gallery_enabled_provider.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/account_manager_provider.dart';
import 'package:nai_launcher/presentation/providers/auth_provider.dart';
import 'package:nai_launcher/presentation/providers/shortcuts_provider.dart';
import 'package:nai_launcher/presentation/router/app_router_config.dart';
import 'package:nai_launcher/presentation/router/app_routes.dart';

void main() {
  testWidgets('direct online gallery routes require explicit opt-in', (
    tester,
  ) async {
    final harness = _RouterHarness(storage: _FeatureStorage());
    addTearDown(harness.dispose);
    final router = GoRouter(
      initialLocation: AppRoutes.onlineGallery,
      redirect: harness.router.configuration.topRedirect,
      routes: [
        GoRoute(
          path: AppRoutes.onlineGallery,
          builder: (_, __) => const SizedBox(),
        ),
        GoRoute(path: AppRoutes.settings, builder: (_, __) => const SizedBox()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(harness.appFor(router));
    await tester.pumpAndSettle();
    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/settings?section=online-gallery',
    );
    await harness.container
        .read(onlineGalleryEnabledProvider.notifier)
        .setEnabled(true);
    router.go(AppRoutes.onlineGallery);
    await tester.pumpAndSettle();
    expect(
      router.routeInformationProvider.value.uri.path,
      AppRoutes.onlineGallery,
    );
    await harness.container
        .read(onlineGalleryEnabledProvider.notifier)
        .setEnabled(false);
    router.refresh();
    await tester.pumpAndSettle();
    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/settings?section=online-gallery',
    );
  });

  testWidgets('appRouter sends an unknown location to its error entry', (
    tester,
  ) async {
    final harness = _RouterHarness();
    addTearDown(harness.dispose);
    harness.router.go('/route-that-does-not-exist');

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();

    expect(find.byType(RouterErrorScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('router_error_back')), findsOneWidget);
    expect(find.byKey(const ValueKey('router_error_home')), findsOneWidget);
    expect(find.textContaining('/route-that-does-not-exist'), findsOneWidget);
  });

  for (final path in <String>[
    '${AppRoutes.localGallery}${AppRoutes.slideshow}',
    '${AppRoutes.localGallery}${AppRoutes.comparison}',
  ]) {
    testWidgets('$path without runtime images returns to the gallery', (
      tester,
    ) async {
      final harness = _RouterHarness();
      addTearDown(harness.dispose);
      final nestedRouter = GoRouter(
        initialLocation: path,
        routes: [
          GoRoute(
            path: AppRoutes.localGallery,
            builder: (context, state) => const Scaffold(
              body: SizedBox(key: ValueKey('gallery-route-host')),
            ),
            routes: harness.localGalleryNestedRoutes,
          ),
        ],
      );
      addTearDown(nestedRouter.dispose);

      await tester.pumpWidget(harness.appFor(nestedRouter));
      await tester.pumpAndSettle();

      expect(
        nestedRouter.routeInformationProvider.value.uri.path,
        AppRoutes.localGallery,
      );
      expect(find.byKey(const ValueKey('gallery-route-host')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

class _RouterHarness {
  _RouterHarness({LocalStorageService? storage})
    : container = ProviderContainer(
        overrides: [
          if (storage != null)
            localStorageServiceProvider.overrideWithValue(storage),
          accountManagerNotifierProvider.overrideWith(
            _TestAccountManagerNotifier.new,
          ),
          authNotifierProvider.overrideWith(_UnauthenticatedAuthNotifier.new),
          shortcutConfigNotifierProvider.overrideWith(
            _TestShortcutConfigNotifier.new,
          ),
        ],
      ) {
    router = container.read(appRouterProvider);
  }

  final ProviderContainer container;
  late final GoRouter router;

  List<RouteBase> get localGalleryNestedRoutes {
    final shell = router.configuration.routes
        .whereType<StatefulShellRoute>()
        .single;
    final localGallery = shell.branches[1].routes.single as GoRoute;
    return localGallery.routes;
  }

  Widget get app => appFor(router);

  Widget appFor(GoRouter targetRouter) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: targetRouter,
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
    ),
  );

  void dispose() {
    container.dispose();
  }
}

class _TestAccountManagerNotifier extends AccountManagerNotifier {
  @override
  AccountManagerState build() => const AccountManagerState();
}

class _UnauthenticatedAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthState(status: AuthStatus.unauthenticated);
}

class _TestShortcutConfigNotifier extends ShortcutConfigNotifier {
  @override
  Future<ShortcutConfig> build() async => ShortcutConfig.createDefault();
}

class _FeatureStorage extends LocalStorageService {
  final values = <String, Object?>{};
  @override
  T? getSetting<T>(String key, {T? defaultValue}) =>
      values[key] as T? ?? defaultValue;
  @override
  Future<void> setSetting<T>(String key, T value) async {
    values[key] = value;
  }
}
