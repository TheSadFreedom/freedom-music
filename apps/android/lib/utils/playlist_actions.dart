import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/track.dart';
import '../services/library_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_bottom_sheet.dart';
import '../widgets/lyrics_view.dart';

const _kYellow = Color(0xFFFFDB4D);

/// Open playlist picker over the current screen; stays open for multi-add.
Future<void> addTrackToPlaylist(BuildContext context, Track track) async {
  dismissLyrics(context);
  await showAppBottomSheet<void>(
    context: context,
    title: 'В плейлист',
    scrollControlled: true,
    body: (sheetCtx) => _AddToPlaylistBody(track: track),
  );
}

class _AddToPlaylistBody extends StatefulWidget {
  const _AddToPlaylistBody({required this.track});

  final Track track;

  @override
  State<_AddToPlaylistBody> createState() => _AddToPlaylistBodyState();
}

class _AddToPlaylistBodyState extends State<_AddToPlaylistBody> {
  final Set<int> _containing = {};
  final Set<int> _busy = {};
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _refreshMembership();
  }

  Future<void> _refreshMembership() async {
    final library = context.read<LibraryService>();
    final ids =
        await library.playlistIdsContainingTrack(widget.track.trackKey);
    if (!mounted) return;
    setState(() {
      _containing
        ..clear()
        ..addAll(ids);
      _loading = false;
    });
  }

  Future<void> _addTo(int playlistId) async {
    if (_busy.contains(playlistId) || _containing.contains(playlistId)) return;
    setState(() => _busy.add(playlistId));
    final library = context.read<LibraryService>();
    final name = library.playlistById(playlistId)?.name ?? 'плейлист';
    final added =
        await library.addToPlaylist(playlistId, widget.track.trackKey);
    if (!mounted) return;
    setState(() {
      _busy.remove(playlistId);
      if (added) _containing.add(playlistId);
    });
    _toast(
      added
          ? '«${widget.track.displayTitle}» добавлен в «$name»'
          : 'Уже есть в «$name»',
    );
  }

  Future<void> _createAndAdd() async {
    final name = await _askPlaylistName(context);
    if (name == null || !mounted) return;
    final library = context.read<LibraryService>();
    final playlistId = await library.createPlaylist(name);
    final added =
        await library.addToPlaylist(playlistId, widget.track.trackKey);
    if (!mounted) return;
    setState(() {
      if (added) _containing.add(playlistId);
    });
    _toast(
      added
          ? '«${widget.track.displayTitle}» добавлен в «$name»'
          : 'Уже есть в «$name»',
    );
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.inkLift,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final lists = library.playlists.where((p) => !p.isSystem).toList();

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      children: [
        SheetRow(
          title: 'Новый плейлист',
          subtitle: 'Создать и добавить трек',
          leadingIcon: Icons.add_rounded,
          leadingAccent: true,
          onTap: _createAndAdd,
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _kYellow,
                ),
              ),
            ),
          )
        else if (lists.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              'Своих плейлистов пока нет',
              style: GoogleFonts.figtree(
                color: AppTheme.paperMuted,
                fontSize: 13,
              ),
            ),
          )
        else
          for (final pl in lists)
            SheetRow(
              title: pl.name,
              subtitle: _containing.contains(pl.id)
                  ? 'Уже добавлен · ${_tracksLabel(pl.trackCount)}'
                  : _tracksLabel(pl.trackCount),
              leadingIcon: Icons.queue_music_rounded,
              selected: _containing.contains(pl.id),
              onTap: _containing.contains(pl.id) || _busy.contains(pl.id)
                  ? null
                  : () => _addTo(pl.id),
            ),
      ],
    );
  }
}

String _tracksLabel(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) return '$count трек';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return '$count трека';
  }
  return '$count треков';
}

Future<String?> _askPlaylistName(BuildContext context) async {
  final controller = TextEditingController();
  try {
    final String? name;
    if (Navigator.maybeOf(context) == null) {
      name = await _askPlaylistNameOverlay(context, controller);
    } else {
      name = await showDialog<String>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.62),
        builder: (ctx) => _PlaylistNameDialog(controller: controller),
      );
    }
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return trimmed;
  } finally {
    controller.dispose();
  }
}

Future<String?> _askPlaylistNameOverlay(
  BuildContext context,
  TextEditingController controller,
) {
  final completer = Completer<String?>();
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  void finish([String? value]) {
    if (entry.mounted) entry.remove();
    if (!completer.isCompleted) completer.complete(value);
  }

  entry = OverlayEntry(
    builder: (ctx) {
      return Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => finish(),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.62),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: _PlaylistNameDialog(
                  controller: controller,
                  onCancel: () => finish(),
                  onSubmit: (v) => finish(v),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  overlay.insert(entry);
  return completer.future;
}

class _PlaylistNameDialog extends StatelessWidget {
  const _PlaylistNameDialog({
    required this.controller,
    this.onCancel,
    this.onSubmit,
  });

  final TextEditingController controller;
  final VoidCallback? onCancel;
  final ValueChanged<String>? onSubmit;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A2220),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text(
        'Новый плейлист',
        style: GoogleFonts.syne(
          color: AppTheme.paper,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: GoogleFonts.figtree(color: AppTheme.paper),
        cursorColor: _kYellow,
        decoration: InputDecoration(
          hintText: 'Название',
          hintStyle: GoogleFonts.figtree(color: AppTheme.paperMuted),
          filled: true,
          fillColor: AppTheme.ink.withValues(alpha: 0.55),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
        onSubmitted: (v) {
          if (onSubmit != null) {
            onSubmit!(v);
          } else {
            Navigator.pop(context, v);
          }
        },
      ),
      actions: [
        TextButton(
          onPressed: onCancel ?? () => Navigator.pop(context),
          child: Text(
            'Отмена',
            style: GoogleFonts.figtree(color: AppTheme.paperMuted),
          ),
        ),
        TextButton(
          onPressed: () {
            if (onSubmit != null) {
              onSubmit!(controller.text);
            } else {
              Navigator.pop(context, controller.text);
            }
          },
          child: Text(
            'Создать',
            style: GoogleFonts.figtree(
              color: _kYellow,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}
