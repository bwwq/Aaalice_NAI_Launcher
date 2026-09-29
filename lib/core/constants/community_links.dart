/// Public project links exposed consistently across desktop and mobile UI.
abstract final class CommunityLinks {
  static const discord = '';
  static const discordVisible = false;
  static bool get showDiscord => discordVisible && discord.isNotEmpty;
  static const githubOwner = 'bwwq';
  static const githubRepo = 'Aaalice_NAI_Launcher';
  static const github = 'https://github.com/$githubOwner/$githubRepo';
}
