/// On Android media_kit plays files by path directly — no playcache/hardlinks.
class PlayPathResolver {
  PlayPathResolver(this.aliasDir);

  final String aliasDir;

  Future<String> resolve(String path) async => path;

  Future<void> dropAlias(String path) async {}
}
