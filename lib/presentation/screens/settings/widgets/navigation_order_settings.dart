import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/localization_extension.dart';
import '../../../providers/main_navigation_order_provider.dart';
import '../../../providers/online_gallery_enabled_provider.dart';
import '../../../router/main_navigation_item.dart';
import '../../../widgets/common/app_toast.dart';
import 'settings_card.dart';

class NavigationOrderSettings extends ConsumerStatefulWidget {
  const NavigationOrderSettings({super.key});

  @override
  ConsumerState<NavigationOrderSettings> createState() =>
      _NavigationOrderSettingsState();
}

class _NavigationOrderSettingsState
    extends ConsumerState<NavigationOrderSettings> {
  bool _saving = false;

  Future<void> _save(Future<void> Function() operation) async {
    setState(() => _saving = true);
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          context.l10n.globalSettings_saveFailed('$error'),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final galleryEnabled = ref.watch(onlineGalleryEnabledProvider);
    final items = visibleMainNavigationItems(
      ref.watch(mainNavigationOrderProvider),
      onlineGalleryEnabled: galleryEnabled,
    );
    return SettingsCard(
      title: context.l10n.settings_navigationOrder,
      description: context.l10n.settings_navigationOrderSubtitle,
      child: Column(
        children: [
          for (var index = 0; index < items.length; index++)
            Padding(
              key: ValueKey('navigation-order-${items[index].name}'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Icon(items[index].icon, size: 20),
                  const SizedBox(width: 12),
                  Expanded(child: Text(items[index].label(context.l10n))),
                  IconButton(
                    key: ValueKey('navigation-order-up-${items[index].name}'),
                    tooltip: context.l10n.settings_navigationMoveUp,
                    onPressed: _saving || index == 0
                        ? null
                        : () => _save(
                            () => ref
                                .read(mainNavigationOrderProvider.notifier)
                                .move(
                                  items[index],
                                  -1,
                                  onlineGalleryEnabled: galleryEnabled,
                                ),
                          ),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  IconButton(
                    key: ValueKey('navigation-order-down-${items[index].name}'),
                    tooltip: context.l10n.settings_navigationMoveDown,
                    onPressed: _saving || index == items.length - 1
                        ? null
                        : () => _save(
                            () => ref
                                .read(mainNavigationOrderProvider.notifier)
                                .move(
                                  items[index],
                                  1,
                                  onlineGalleryEnabled: galleryEnabled,
                                ),
                          ),
                    icon: const Icon(Icons.arrow_downward),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: TextButton.icon(
                key: const ValueKey('navigation-order-reset'),
                onPressed: _saving
                    ? null
                    : () => _save(
                        ref.read(mainNavigationOrderProvider.notifier).reset,
                      ),
                icon: const Icon(Icons.restore),
                label: Text(context.l10n.resetToDefault),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
