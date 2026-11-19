import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../new_releases/models.dart';
import '../new_releases/release_fetch.dart';
import '../new_releases/source_icons.dart';
import '../new_releases/watchlist_store.dart';
import '../services/library_service.dart';
import '../theme/app_theme.dart';

/// Built-in «Новинки» page (was a sidecar mod window).
class NewReleasesScreen extends StatefulWidget {
  const NewReleasesScreen({super.key});

  @override
  State<NewReleasesScreen> createState() => _NewReleasesScreenState();
}

class _NewReleasesScreenState extends State<NewReleasesScreen> {
  final _fetch = ReleaseFetch();

  WatchlistStore? _store;
  List<WatchedArtist> _artists = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bootstrap();
    });
  }

  @override
  void dispose() {
    _fetch.close();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final paths = context.read<LibraryService>().paths;
      _store = WatchlistStore.inDataDir(paths.dataDir);
      final loaded = await _store!.load();
      if (!mounted) return;
      setState(() {
        _artists = _sorted(loaded);
        _loading = false;
      });
      if (loaded.isNotEmpty) {
        await _refreshAll(silent: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _persist() async {
    final store = _store;
    if (store == null) return;
    await store.save(_artists);
  }

  List<WatchedArtist> _sorted(List<WatchedArtist> list) {
    final copy = [...list];
    copy.sort((a, b) {
      final byDate = b.releaseDateMs.compareTo(a.releaseDateMs);
      if (byDate != 0) return byDate;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return copy;
  }

  Future<void> _openAddDialog() async {
    final draft = await showDialog<_AddDraft>(
      context: context,
      barrierDismissible: !_busy,
      builder: (context) => const _AddArtistDialog(),
    );
    if (draft == null || !mounted) return;
    await _add(draft);
  }

  Future<void> _add(_AddDraft draft) async {
    final name = draft.name.trim();
    final ym = draft.yandexUrl.trim();
    final sp = draft.spotifyUrl.trim();

    if (name.isEmpty) {
      setState(() => _error = 'Укажи имя');
      return;
    }
    if (ym.isEmpty && sp.isEmpty) {
      setState(() => _error = 'Укажи хотя бы одну ссылку');
      return;
    }
    if (_artists.any((a) => a.name.toLowerCase() == name.toLowerCase())) {
      setState(() => _error = 'Артист с таким именем уже в списке');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _status = 'Загрузка…';
    });
    try {
      final release = await _fetch.fetchNewest(
        yandexUrl: ym.isEmpty ? null : ym,
        spotifyUrl: sp.isEmpty ? null : sp,
      );
      final entry = WatchedArtist(
        id: WatchedArtist.newId(),
        name: name,
        yandexUrl: ym.isEmpty ? null : ym,
        spotifyUrl: sp.isEmpty ? null : sp,
        source: release.source,
        releaseTitle: release.title,
        releaseType: release.typeLabel,
        releaseDate: release.dateLabel,
        releaseDateMs: release.releaseDateMs,
        coverUrl: release.coverUrl,
        fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
        releaseUrl: release.releaseUrl,
      );
      setState(() {
        _artists = _sorted([entry, ..._artists]);
        _status = null;
      });
      await _persist();
    } catch (e) {
      setState(() {
        _error = '$e'.replaceFirst('Bad state: ', '');
        _status = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshAll({bool silent = false}) async {
    if (_artists.isEmpty) return;
    if (!silent) {
      setState(() {
        _busy = true;
        _error = null;
        _status = 'Обновление…';
      });
    }
    try {
      final next = <WatchedArtist>[];
      for (final artist in _artists) {
        try {
          final release = await _fetch.fetchNewest(
            yandexUrl: artist.yandexUrl,
            spotifyUrl: artist.spotifyUrl,
          );
          next.add(
            artist.copyWith(
              source: release.source,
              releaseTitle: release.title,
              releaseType: release.typeLabel,
              releaseDate: release.dateLabel,
              releaseDateMs: release.releaseDateMs,
              coverUrl: release.coverUrl,
              fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
              releaseUrl: release.releaseUrl,
            ),
          );
        } catch (_) {
          next.add(artist);
        }
      }
      if (!mounted) return;
      setState(() {
        _artists = _sorted(next);
        _status = silent ? null : 'Обновлено';
      });
      await _persist();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          if (!silent) {
            Future<void>.delayed(const Duration(seconds: 2), () {
              if (mounted) setState(() => _status = null);
            });
          }
        });
      }
    }
  }

  Future<void> _remove(WatchedArtist artist) async {
    setState(() {
      _artists = [for (final a in _artists) if (a.id != artist.id) a];
    });
    await _persist();
  }

  Future<void> _openRelease(WatchedArtist artist) async {
    final url = artist.releaseUrl?.trim();
    if (url == null || url.isEmpty) {
      setState(() => _error = 'Нет ссылки на релиз');
      return;
    }
    try {
      final uri = Uri.parse(url);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        setState(() => _error = 'Не удалось открыть браузер');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Не удалось открыть браузер: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            busy: _busy,
            onAdd: _busy ? null : _openAddDialog,
            onRefresh: _artists.isEmpty || _busy ? null : () => _refreshAll(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 13),
              ),
            ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                _status!,
                style: const TextStyle(color: AppTheme.paperMuted, fontSize: 13),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppTheme.lime),
                  )
                : _artists.isEmpty
                    ? const _Empty()
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                        child: Wrap(
                          spacing: 14,
                          runSpacing: 14,
                          alignment: WrapAlignment.start,
                          children: [
                            for (final artist in _artists)
                              SizedBox(
                                width: _ReleaseTile.cardWidth,
                                height: _ReleaseTile.cardHeight,
                                child: _ReleaseTile(
                                  artist: artist,
                                  onOpen: artist.releaseUrl == null ||
                                          artist.releaseUrl!.isEmpty
                                      ? null
                                      : () => _openRelease(artist),
                                  onDelete:
                                      _busy ? null : () => _remove(artist),
                                ),
                              ),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _AddDraft {
  const _AddDraft({
    required this.name,
    required this.yandexUrl,
    required this.spotifyUrl,
  });

  final String name;
  final String yandexUrl;
  final String spotifyUrl;
}

class _AddArtistDialog extends StatefulWidget {
  const _AddArtistDialog();

  @override
  State<_AddArtistDialog> createState() => _AddArtistDialogState();
}

class _AddArtistDialogState extends State<_AddArtistDialog> {
  final _name = TextEditingController();
  final _yandex = TextEditingController();
  final _spotify = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _yandex.dispose();
    _spotify.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final ym = _yandex.text.trim();
    final sp = _spotify.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Укажи имя');
      return;
    }
    if (ym.isEmpty && sp.isEmpty) {
      setState(() => _error = 'Укажи хотя бы одну ссылку');
      return;
    }
    if (ym.isNotEmpty && detectSource(ym) != DetectedSource.yandex) {
      setState(() => _error = 'Неверная ссылка Яндекс Музыки');
      return;
    }
    if (sp.isNotEmpty && detectSource(sp) != DetectedSource.spotify) {
      setState(() => _error = 'Неверная ссылка Spotify');
      return;
    }
    Navigator.of(context).pop(
      _AddDraft(name: name, yandexUrl: ym, spotifyUrl: sp),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.inkLift,
      title: const Text(
        'Добавить артиста',
        style: TextStyle(color: AppTheme.paper),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DialogField(
              controller: _name,
              label: 'Имя',
              hint: 'Zivert',
            ),
            const SizedBox(height: 12),
            _DialogField(
              controller: _yandex,
              label: 'Ссылка на Яндекс Музыку',
              hint: 'https://music.yandex.ru/artist/…',
            ),
            const SizedBox(height: 12),
            _DialogField(
              controller: _spotify,
              label: 'Ссылка на Spotify',
              hint: 'https://open.spotify.com/artist/…',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'Отмена',
            style: TextStyle(color: AppTheme.paperMuted),
          ),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.lime,
            foregroundColor: AppTheme.ink,
          ),
          child: const Text('Добавить'),
        ),
      ],
    );
  }
}

class _DialogField extends StatelessWidget {
  const _DialogField({
    required this.controller,
    required this.label,
    required this.hint,
  });

  final TextEditingController controller;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: AppTheme.paper, fontSize: 14),
      cursorColor: AppTheme.lime,
      inputFormatters: [
        FilteringTextInputFormatter.deny(RegExp(r'[\n\r]')),
      ],
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppTheme.paperMuted),
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF6A6A6A)),
        filled: true,
        fillColor: AppTheme.ink,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.busy,
    required this.onAdd,
    required this.onRefresh,
  });

  final bool busy;
  final VoidCallback? onAdd;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 16, 4),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Новинки',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: AppTheme.paper,
              ),
            ),
          ),
          Tooltip(
            message: 'Добавить',
            child: Material(
              color: onAdd == null ? const Color(0xFF3A3A3A) : AppTheme.lime,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onAdd,
                child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: Text(
                      '+',
                      style: TextStyle(
                        color: AppTheme.ink,
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Обновить',
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRefresh,
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppTheme.lime,
                            ),
                          )
                        : const Text(
                            '↻',
                            style: TextStyle(
                              color: AppTheme.paperMuted,
                              fontSize: 22,
                              height: 1,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Нажми + и добавь артиста — покажем самый новый релиз',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppTheme.paperMuted, fontSize: 14),
      ),
    );
  }
}

class _ReleaseTile extends StatelessWidget {
  const _ReleaseTile({
    required this.artist,
    required this.onOpen,
    required this.onDelete,
  });

  static const double cardWidth = 168;
  static const double cardHeight = 268;

  final WatchedArtist artist;
  final VoidCallback? onOpen;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (artist.releaseDate.isNotEmpty) artist.releaseDate,
      if (artist.releaseType.isNotEmpty) artist.releaseType,
    ].join(' · ');

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.inkLift.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: artist.coverUrl.isEmpty
                          ? const ColoredBox(
                              color: Color(0xFF2A2A2A),
                              child: Icon(
                                Icons.album,
                                color: AppTheme.paperMuted,
                                size: 40,
                              ),
                            )
                          : Image.network(
                              artist.coverUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const ColoredBox(
                                color: Color(0xFF2A2A2A),
                                child: Icon(
                                  Icons.album,
                                  color: AppTheme.paperMuted,
                                  size: 40,
                                ),
                              ),
                            ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    left: 4,
                    child: SourceBadge(source: artist.source),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Material(
                      color: Colors.black54,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: onDelete,
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(
                            Icons.close_rounded,
                            color: AppTheme.paper,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              artist.releaseTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.paper,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              artist.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.paperMuted,
                fontSize: 12,
                height: 1.25,
              ),
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppTheme.paperMuted, fontSize: 11),
              ),
            ],
            const SizedBox(height: 8),
            SizedBox(
              height: 34,
              child: OutlinedButton(
                onPressed: onOpen,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.paper,
                  side: const BorderSide(color: Color(0xFF3A3A3A)),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  'К релизу',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
