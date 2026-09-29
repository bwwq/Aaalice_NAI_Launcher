import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/localization_extension.dart';
import '../../../providers/online_gallery_enabled_provider.dart';
import '../../../widgets/common/app_toast.dart';
import '../widgets/settings_card.dart';
import '../widgets/settings_page_layout.dart';

class OnlineGallerySettingsSection extends ConsumerStatefulWidget {
  const OnlineGallerySettingsSection({super.key});

  @override
  ConsumerState<OnlineGallerySettingsSection> createState() =>
      _OnlineGallerySettingsSectionState();
}

class _OnlineGallerySettingsSectionState
    extends ConsumerState<OnlineGallerySettingsSection> {
  bool _saving = false;

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _saving = true);
    try {
      await ref.read(onlineGalleryEnabledProvider.notifier).setEnabled(enabled);
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
  Widget build(BuildContext context) => SettingsPageLayout(
    title: context.l10n.nav_onlineGallery,
    children: [
      SettingsCard(
        child: SwitchListTile.adaptive(
          title: Text(context.l10n.settings_enableOnlineGallery),
          subtitle: Text(context.l10n.settings_enableOnlineGallerySubtitle),
          value: ref.watch(onlineGalleryEnabledProvider),
          onChanged: _saving ? null : _setEnabled,
        ),
      ),
    ],
  );
}
