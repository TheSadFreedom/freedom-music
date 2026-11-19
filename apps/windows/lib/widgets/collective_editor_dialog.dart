import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../services/library_service.dart';
import '../theme/app_theme.dart';

Future<CreativeCollective?> showCollectiveEditorDialog(
  BuildContext context, {
  CreativeCollective? existing,
}) {
  return showDialog<CreativeCollective>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (_) => _CollectiveEditorDialog(existing: existing),
  );
}

class _CollectiveEditorDialog extends StatefulWidget {
  const _CollectiveEditorDialog({this.existing});

  final CreativeCollective? existing;

  @override
  State<_CollectiveEditorDialog> createState() =>
      _CollectiveEditorDialogState();
}

class _CollectiveEditorDialogState extends State<_CollectiveEditorDialog> {
  late final TextEditingController _nameController;
  late bool _hidesArtist;
  late Set<String> _members;
  String? _lockedIdentity;
  String _memberQuery = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _hidesArtist = existing?.hidesArtist ?? false;
    _lockedIdentity = _hidesArtist ? existing?.name : null;
    _members = {
      for (final m in existing?.members ?? const <String>[]) m.trim(),
    }..removeWhere((m) => m.isEmpty);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  List<String> _artistNames(LibraryService library) {
    final names = library.tracksByArtist().keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  Future<void> _pickIdentityArtist() async {
    final library = context.read<LibraryService>();
    final names = _artistNames(library);
    final selected = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      builder: (ctx) {
        var query = '';
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final filtered = [
              for (final name in names)
                if (query.trim().isEmpty ||
                    name.toLowerCase().contains(query.trim().toLowerCase()))
                  name,
            ];
            return AlertDialog(
              backgroundColor: AppTheme.inkLift,
              title: Text(
                'Выбрать артиста',
                style: GoogleFonts.syne(fontWeight: FontWeight.w700),
              ),
              content: SizedBox(
                width: 420,
                height: 420,
                child: Column(
                  children: [
                    TextField(
                      autofocus: true,
                      onChanged: (v) => setLocal(() => query = v),
                      style: GoogleFonts.figtree(color: AppTheme.paper),
                      cursorColor: AppTheme.lime,
                      decoration: InputDecoration(
                        hintText: 'Поиск',
                        hintStyle:
                            GoogleFonts.figtree(color: AppTheme.paperMuted),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final name = filtered[i];
                          return ListTile(
                            title: Text(
                              name,
                              style: GoogleFonts.figtree(
                                color: AppTheme.paper,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onTap: () => Navigator.pop(ctx, name),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    'Отмена',
                    style: GoogleFonts.figtree(color: AppTheme.paperMuted),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (selected == null || !mounted) return;
    setState(() {
      _nameController.text = selected;
      _hidesArtist = true;
      _lockedIdentity = selected;
      _members.removeWhere((m) => m.toLowerCase() == selected.toLowerCase());
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);
    final library = context.read<LibraryService>();
    try {
      final members = _members.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      final CreativeCollective result;
      final existing = widget.existing;
      if (existing == null) {
        result = await library.createCollective(
          name: name,
          members: members,
          hidesArtist: _hidesArtist,
        );
      } else {
        result = existing.copyWith(
          name: name,
          members: members,
          hidesArtist: _hidesArtist,
        );
        await library.updateCollective(result);
      }
      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.inkLift,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final identity = _nameController.text.trim().toLowerCase();
    final artists = [
      for (final name in _artistNames(library))
        if (name.toLowerCase() != identity) name,
    ];
    final q = _memberQuery.trim().toLowerCase();
    final visible = [
      for (final name in artists)
        if (q.isEmpty || name.toLowerCase().contains(q)) name,
    ];

    return AlertDialog(
      backgroundColor: AppTheme.inkLift,
      title: Text(
        widget.existing == null
            ? 'Новое объединение'
            : 'Изменить объединение',
        style: GoogleFonts.syne(fontWeight: FontWeight.w700),
      ),
      content: SizedBox(
        width: 480,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              onChanged: (value) {
                setState(() {
                  final id = value.trim().toLowerCase();
                  final locked = _lockedIdentity?.trim().toLowerCase();
                  if (locked == null || id != locked) {
                    _hidesArtist = false;
                    _lockedIdentity = null;
                  }
                  _members.removeWhere((m) => m.toLowerCase() == id);
                });
              },
              style: GoogleFonts.figtree(color: AppTheme.paper),
              cursorColor: AppTheme.lime,
              decoration: InputDecoration(
                labelText: 'Название',
                labelStyle: GoogleFonts.figtree(color: AppTheme.paperMuted),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _pickIdentityArtist,
                icon: const Icon(Icons.person_search_rounded, size: 18),
                label: Text(
                  _hidesArtist
                      ? 'Артист выбран как объединение'
                      : 'Выбрать артиста',
                  style: GoogleFonts.figtree(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            if (_hidesArtist)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Этот артист исчезнет со вкладки «Артисты».',
                  style: GoogleFonts.figtree(
                    color: AppTheme.paperMuted,
                    fontSize: 12.5,
                  ),
                ),
              ),
            Text(
              'Участники',
              style: GoogleFonts.syne(
                color: AppTheme.paper,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              onChanged: (v) => setState(() => _memberQuery = v),
              style: GoogleFonts.figtree(color: AppTheme.paper),
              cursorColor: AppTheme.lime,
              decoration: InputDecoration(
                hintText: 'Поиск артиста',
                hintStyle: GoogleFonts.figtree(color: AppTheme.paperMuted),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (_, i) {
                    final name = visible[i];
                    final selected = _members.any(
                      (m) => m.toLowerCase() == name.toLowerCase(),
                    );
                    return CheckboxListTile(
                      value: selected,
                      activeColor: AppTheme.lime,
                      checkColor: AppTheme.ink,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                        name,
                        style: GoogleFonts.figtree(
                          color: AppTheme.paper,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _members.add(name);
                          } else {
                            _members.removeWhere(
                              (m) => m.toLowerCase() == name.toLowerCase(),
                            );
                          }
                        });
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(
            'Отмена',
            style: GoogleFonts.figtree(color: AppTheme.paperMuted),
          ),
        ),
        FilledButton(
          onPressed: _saving || _nameController.text.trim().isEmpty
              ? null
              : _save,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFFFDB4D),
            foregroundColor: AppTheme.ink,
          ),
          child: Text(
            'Сохранить',
            style: GoogleFonts.figtree(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}
