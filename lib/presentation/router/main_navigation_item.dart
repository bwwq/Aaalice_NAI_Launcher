import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'app_branch.dart';

/// Stable identities independent of a user's display order or route indices.
enum MainNavigationItem {
  generation(AppBranch.generation, 'nav-branch-0', Icons.brush),
  localGallery(AppBranch.localGallery, 'nav-branch-1', Icons.folder),
  onlineGallery(AppBranch.onlineGallery, 'nav-branch-2', Icons.photo_library),
  vibeLibrary(AppBranch.vibeLibrary, 'nav-branch-3', Icons.auto_awesome),
  preciseRefLibrary(
    AppBranch.preciseRefLibrary,
    'nav-branch-4',
    Icons.center_focus_strong,
  ),
  tagLibrary(AppBranch.tagLibrary, 'nav-branch-6', Icons.book),
  promptConfig(AppBranch.promptConfig, 'nav-branch-5', Icons.casino),
  statistics(AppBranch.statistics, 'nav-branch-7', Icons.bar_chart),
  agent(null, 'agent-nav-item', Icons.smart_toy_outlined),
  queue(null, 'queue-nav-item', Icons.playlist_play_rounded),
  settings(AppBranch.settings, 'nav-branch-8', Icons.settings);

  const MainNavigationItem(this.branch, this.widgetKey, this.icon);
  final AppBranch? branch;
  final String widgetKey;
  final IconData icon;

  String label(AppLocalizations l10n) => switch (this) {
    generation => l10n.nav_canvas,
    localGallery => l10n.nav_localGallery,
    onlineGallery => l10n.nav_onlineGallery,
    vibeLibrary => l10n.vibeLibrary_title,
    preciseRefLibrary => l10n.nav_preciseRefLibrary,
    tagLibrary => l10n.nav_dictionary,
    promptConfig => l10n.nav_randomConfig,
    statistics => l10n.nav_statistics,
    agent => l10n.nav_agent,
    queue => l10n.queue_management,
    settings => l10n.nav_settings,
  };
}

List<MainNavigationItem> visibleMainNavigationItems(
  List<MainNavigationItem> order, {
  required bool onlineGalleryEnabled,
  bool builtInAgentEnabled = true,
}) => order
    .where(
      (item) =>
          (onlineGalleryEnabled || item != MainNavigationItem.onlineGallery) &&
          (builtInAgentEnabled || item != MainNavigationItem.agent),
    )
    .toList(growable: false);
