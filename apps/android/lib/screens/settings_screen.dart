import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/storage_access.dart';
import '../sync/sync_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ambient_backdrop.dart';
import '../widgets/kept_icons.dart';
import '../widgets/screen_title.dart';

const _kYellow = Color(0xFFFFDB4D);
const _kContentMax = 920.0;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  bool _busyBackup = false;
  String? _backupMessage;
  String? _driveMessage;
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _pickMusicFolder(LibraryService library) async {
    final access = await StorageAccess.ensureMusicAccess();
    if (!access && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Нужен доступ ко всем файлам. Разрешите в настройках Android и повторите.',
            style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.inkLift,
        ),
      );
    }
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Папка музыки',
    );
    if (dir == null || dir.isEmpty) return;
    await library.setMusicFolder(dir);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Папка музыки: $dir',
          style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.inkLift,
      ),
    );
  }

  Future<void> _syncDrive(LibraryService library, SyncService sync) async {
    setState(() => _driveMessage = null);
    try {
      await sync.syncNow();
      if (sync.libraryNeedsReload) {
        sync.clearLibraryNeedsReload();
        await library.reload();
      }
      library.bumpPlayStats();
      if (!mounted) return;
      setState(() => _driveMessage = sync.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _driveMessage = sync.message ?? 'Ошибка синхронизации');
    }
  }

  Future<void> _signInDrive(SyncService sync) async {
    setState(() => _driveMessage = null);
    try {
      await sync.signIn(promptYandexCode: _promptYandexCode);
      if (!mounted) return;
      setState(() => _driveMessage = sync.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _driveMessage = sync.message ?? 'Ошибка входа');
    }
  }

  Future<String?> _promptYandexCode() async {
    if (!mounted) return null;
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.inkLift,
          title: Text(
            'Код Яндекс',
            style: GoogleFonts.syne(
              color: AppTheme.paper,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'В браузере откроется страница Яндекса. Скопируйте код подтверждения и вставьте сюда.',
                style: GoogleFonts.figtree(
                  color: AppTheme.paperMuted,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                style: GoogleFonts.figtree(color: AppTheme.paper),
                decoration: InputDecoration(
                  hintText: 'Код подтверждения',
                  hintStyle: GoogleFonts.figtree(color: AppTheme.paperMuted),
                  filled: true,
                  fillColor: AppTheme.ink.withValues(alpha: 0.35),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                'Отмена',
                style: GoogleFonts.figtree(color: AppTheme.paperMuted),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              style: TextButton.styleFrom(foregroundColor: _kYellow),
              child: Text(
                'Войти',
                style: GoogleFonts.figtree(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
      });
    }
  }

  Future<void> _signOutDrive(SyncService sync) async {
    await sync.signOut();
    if (!mounted) return;
    setState(() => _driveMessage = sync.message);
  }

  Future<void> _clearPlayCounts(LibraryService library) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.inkLift,
        title: Text(
          'Обнулить прослушивания?',
          style: GoogleFonts.syne(
            color: AppTheme.paper,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'Счётчики и история прослушиваний будут удалены. '
          'Чарт начнётся с нуля. Плейлисты и метаданные треков не изменятся.',
          style: GoogleFonts.figtree(color: AppTheme.paperMuted, height: 1.45),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              enabledMouseCursor: SystemMouseCursors.click,
            ),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Отмена',
              style: GoogleFonts.figtree(color: AppTheme.paperMuted),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              enabledMouseCursor: SystemMouseCursors.click,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Обнулить',
              style: GoogleFonts.figtree(
                color: Colors.redAccent.shade100,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busyBackup = true;
      _backupMessage = null;
    });
    try {
      await library.clearPlayCounts();
      if (!mounted) return;
      setState(() => _backupMessage = 'Счётчики прослушиваний обнулены.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _backupMessage = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busyBackup = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild only on library / the few settings shown here — not on every
    // playback-session persist from the player.
    final library = context.read<LibraryService>();
    final settings = context.read<SettingsService>();
    final sync = context.watch<SyncService>();
    final scanOnStartup = context.select<SettingsService, bool>(
      (s) => s.scanOnStartup,
    );
    final playOnStartup = context.select<SettingsService, bool>(
      (s) => s.playOnStartup,
    );
    final crossfade = context.select<SettingsService, int>(
      (s) => s.crossfadeSeconds,
    );

    return ListenableBuilder(
      listenable: Listenable.merge([library, library.jobUi, _tabs, sync]),
      builder: (context, _) {
        final progress = library.scanProgress;
        final scanning = library.scanning;
        final busy = scanning || _busyBackup || sync.busy;
        final libraryBusy = scanning || progress != null;

        return Stack(
          children: [
            const Positioned.fill(
              child: AmbientBackdrop(
                accent: AppTheme.moss,
                secondary: Color(0xFF24382F),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ScreenTitle(title: 'Настройки'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Center(
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxWidth: _kContentMax),
                      child: _SettingsTabBar(
                        controller: _tabs,
                        items: [
                          const _SettingsTabItem(
                            label: 'Плеер',
                            icon: Icons.graphic_eq_rounded,
                          ),
                          _SettingsTabItem(
                            label: 'Библиотека',
                            icon: Icons.library_music_rounded,
                            badge: libraryBusy,
                          ),
                          const _SettingsTabItem(
                            label: 'Данные',
                            icon: Icons.inventory_2_rounded,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _SettingsTabScroll(
                        child: _SectionCard(
                          title: 'Воспроизведение',
                          subtitle: 'Поведение при запуске и переход между треками',
                          child: _Group(
                            children: [
                              _SettingSwitch(
                                title: 'Сканировать при запуске',
                                subtitle: 'Иначе скан только по кнопке.',
                                value: scanOnStartup,
                                onChanged:
                                    busy ? null : settings.setScanOnStartup,
                              ),
                              _SettingSwitch(
                                title: 'Музыка при запуске',
                                subtitle:
                                    'Последний трек. Если его не было — случайный поток.',
                                value: playOnStartup,
                                onChanged: settings.setPlayOnStartup,
                              ),
                              _CrossfadeSlider(
                                value: crossfade,
                                onChanged: settings.setCrossfadeSeconds,
                              ),
                            ],
                          ),
                        ),
                      ),
                      _SettingsTabScroll(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _SectionCard(
                              title: 'Папки',
                              child: _Group(
                                children: [
                                  _PathRow(
                                    label: 'music',
                                    value: library.paths.hasMusicDir
                                        ? library.paths.musicDir
                                        : 'не выбрана',
                                  ),
                                  _SettingAction(
                                    icon: const FolderOpenGlyph(),
                                    title: 'Выбрать папку музыки',
                                    description:
                                        'Каталог на устройстве для скана и загрузок.',
                                    onPressed: busy
                                        ? null
                                        : () => _pickMusicFolder(library),
                                  ),
                                  _PathRow(
                                    label: 'База',
                                    value: library.paths.databasePath,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            _SectionCard(
                              title: 'Сканирование',
                              child: _Group(
                                children: [
                                  _SettingAction(
                                    icon: const FolderOpenGlyph(),
                                    title: 'Сканировать папку music',
                                    description:
                                        'Сканирует выбранную папку полностью.',
                                    onPressed: busy
                                        ? null
                                        : () =>
                                            library.scanLibrary(force: true),
                                  ),
                                  _SettingAction(
                                    icon: const FiberNewGlyph(),
                                    title: 'Поиск новых',
                                    description:
                                        'Сканирует только новые файлы и не трогает то, что уже было добавлено.',
                                    onPressed: busy
                                        ? null
                                        : () => library.scanLibrary(
                                              newOnly: true,
                                            ),
                                  ),
                                ],
                              ),
                            ),
                            if (scanning ||
                                progress != null ||
                                library.jobLog.isNotEmpty ||
                                library.lastScanMessage != null) ...[
                              const SizedBox(height: 12),
                              _SectionCard(
                                title: 'Ход работы',
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (scanning || progress != null)
                                      _JobProgress(
                                        label: progress == null
                                            ? 'Подготовка…'
                                            : '${progress.processed} / ${progress.total}'
                                                  '${progress.currentFile != null ? ' — ${progress.currentFile}' : ''}',
                                        value: progress?.ratio,
                                        onStop: scanning
                                            ? library.cancelScan
                                            : null,
                                      ),
                                    if (library.jobLog.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      _JobLog(lines: library.jobLog),
                                    ],
                                    if (library.lastScanMessage != null) ...[
                                      const SizedBox(height: 10),
                                      _StatusNote(
                                        text: library.lastScanMessage!,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      _SettingsTabScroll(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _SectionCard(
                              title: 'Яндекс.Диск',
                              subtitle:
                                  'Что уходит на Диск. Тумблеры только на этом устройстве.',
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  _Group(
                                    children: [
                                      _PathRow(
                                        label: 'Аккаунт',
                                        value: sync.isSignedIn
                                            ? (sync.email ?? 'вход выполнен')
                                            : 'не выполнен вход',
                                      ),
                                      if (!sync.isSignedIn)
                                        _SettingAction(
                                          icon: const UploadGlyph(),
                                          title: 'Войти через Яндекс',
                                          description:
                                              'Откроется браузер — вставьте код подтверждения в приложение.',
                                          onPressed: busy
                                              ? null
                                              : () => _signInDrive(sync),
                                        )
                                      else ...[
                                        _SettingAction(
                                          icon: const RestartGlyph(),
                                          title: 'Синхронизировать',
                                          description: sync.lastSyncAt == null
                                              ? 'Загрузить и скачать изменения.'
                                              : 'Последний синк: ${DateFormat('dd.MM.yyyy HH:mm').format(sync.lastSyncAt!.toLocal())}',
                                          onPressed: busy
                                              ? null
                                              : () =>
                                                  _syncDrive(library, sync),
                                        ),
                                        _SettingAction(
                                          icon: const DownloadGlyph(),
                                          title: 'Выйти',
                                          description:
                                              'Локальные данные останутся. Outbox не очищается.',
                                          onPressed: busy
                                              ? null
                                              : () => _signOutDrive(sync),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  _Group(
                                    children: [
                                      _SettingSwitch(
                                        title: 'Прослушивания',
                                        subtitle:
                                            'История и счётчики прослушиваний.',
                                        value: context.select<
                                            SettingsService, bool>(
                                          (s) => s.syncPlays,
                                        ),
                                        onChanged: busy
                                            ? null
                                            : settings.setSyncPlays,
                                      ),
                                      _SettingSwitch(
                                        title: 'Объединённые карточки',
                                        subtitle:
                                            'Слияния артистов и продюсеров.',
                                        value: context.select<
                                            SettingsService, bool>(
                                          (s) => s.syncAliases,
                                        ),
                                        onChanged: busy
                                            ? null
                                            : settings.setSyncAliases,
                                      ),
                                      _SettingSwitch(
                                        title: 'Плейлисты',
                                        subtitle:
                                            'Ваши плейлисты (без системных).',
                                        value: context.select<
                                            SettingsService, bool>(
                                          (s) => s.syncPlaylists,
                                        ),
                                        onChanged: busy
                                            ? null
                                            : settings.setSyncPlaylists,
                                      ),
                                      _SettingSwitch(
                                        title: 'Плейлист «Облако»',
                                        subtitle:
                                            'До 100 треков на Диске. Выкл. — скрыть из списка.',
                                        value: context.select<
                                            SettingsService, bool>(
                                          (s) => s.syncCloudPlaylist,
                                        ),
                                        onChanged: busy
                                            ? null
                                            : (v) async {
                                                await settings
                                                    .setSyncCloudPlaylist(v);
                                                await library.reload();
                                              },
                                      ),
                                      _SettingSwitch(
                                        title: 'Фотографии артистов',
                                        subtitle:
                                            'Портреты на карточках артистов.',
                                        value: context.select<
                                            SettingsService, bool>(
                                          (s) => s.syncArtistPhotos,
                                        ),
                                        onChanged: busy
                                            ? null
                                            : settings.setSyncArtistPhotos,
                                      ),
                                    ],
                                  ),
                                  if (sync.busy) ...[
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: _kYellow,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          sync.message ?? 'Синхронизация…',
                                          style: GoogleFonts.figtree(
                                            color: AppTheme.paperMuted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ] else if (_driveMessage != null) ...[
                                    const SizedBox(height: 10),
                                    _StatusNote(text: _driveMessage!),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            _SectionCard(
                              title: 'Данные',
                              subtitle: 'Локальные счётчики прослушиваний.',
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  _Group(
                                    children: [
                                      _SettingAction(
                                        icon: const RestartGlyph(),
                                        title: 'Сбросить',
                                        description:
                                            'Обнулить прослушивания. Плейлисты останутся.',
                                        danger: true,
                                        onPressed: busy
                                            ? null
                                            : () =>
                                                _clearPlayCounts(library),
                                      ),
                                    ],
                                  ),
                                  if (_busyBackup) ...[
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: _kYellow,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Обработка…',
                                          style: GoogleFonts.figtree(
                                            color: AppTheme.paperMuted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                  if (_backupMessage != null) ...[
                                    const SizedBox(height: 10),
                                    _StatusNote(text: _backupMessage!),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              'Локальный плеер. Метаданные файла — источник правды о треке.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.figtree(
                                color: AppTheme.paperMuted
                                    .withValues(alpha: 0.8),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _SettingsTabItem {
  const _SettingsTabItem({
    required this.label,
    required this.icon,
    this.badge = false,
  });

  final String label;
  final IconData icon;
  final bool badge;
}

class _SettingsTabBar extends StatelessWidget {
  const _SettingsTabBar({
    required this.controller,
    required this.items,
  });

  final TabController controller;
  final List<_SettingsTabItem> items;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.inkLift.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.paper.withValues(alpha: 0.06)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: _SettingsTabChip(
                  item: items[i],
                  selected: controller.index == i,
                  onTap: () => controller.animateTo(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SettingsTabChip extends StatelessWidget {
  const _SettingsTabChip({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _SettingsTabItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppTheme.ink : AppTheme.paperMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            decoration: BoxDecoration(
              color: selected ? _kYellow : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: _kYellow.withValues(alpha: 0.28),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(item.icon, size: 20, color: fg),
                    if (item.badge)
                      Positioned(
                        right: -5,
                        top: -4,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: selected
                                ? AppTheme.moss
                                : AppTheme.mossBright,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected ? _kYellow : AppTheme.inkLift,
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.figtree(
                    color: fg,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    fontSize: 12,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsTabScroll extends StatelessWidget {
  const _SettingsTabScroll({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kContentMax),
            child: child,
          ),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.inkLift.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.paper.withValues(alpha: 0.06)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: GoogleFonts.syne(
                color: AppTheme.paper,
                fontWeight: FontWeight.w700,
                fontSize: 16,
                letterSpacing: -0.3,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: GoogleFonts.figtree(
                  color: AppTheme.paperMuted.withValues(alpha: 0.9),
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ],
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.ink.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: AppTheme.paper.withValues(alpha: 0.06),
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: GoogleFonts.figtree(
                color: AppTheme.paperMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              maxLines: 1,
              style: GoogleFonts.figtree(
                color: AppTheme.paper,
                fontSize: 12.5,
                height: 1.2,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Копировать',
            visualDensity: VisualDensity.compact,
            mouseCursor: SystemMouseCursors.click,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Скопировано',
                    style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
                  ),
                  behavior: SnackBarBehavior.floating,
                  backgroundColor: AppTheme.inkLift,
                  duration: const Duration(seconds: 1),
                ),
              );
            },
            icon: Icon(
              Icons.copy_rounded,
              size: 18,
              color: AppTheme.paperMuted.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }
}

class _CrossfadeSlider extends StatelessWidget {
  const _CrossfadeSlider({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = value <= 0 ? 'выкл' : '$value с';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Кроссфейд',
                  style: GoogleFonts.figtree(
                    color: AppTheme.paper,
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
              ),
              Text(
                label,
                style: GoogleFonts.figtree(
                  color: _kYellow,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: _kYellow,
              inactiveTrackColor: AppTheme.paper.withValues(alpha: 0.12),
              thumbColor: _kYellow,
              overlayColor: _kYellow.withValues(alpha: 0.12),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: value.toDouble(),
              min: 0,
              max: 12,
              divisions: 12,
              label: label,
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.figtree(
                    color: AppTheme.paper,
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: GoogleFonts.figtree(
                    color: AppTheme.paperMuted,
                    fontSize: 11.5,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            mouseCursor: onChanged != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            activeThumbColor: AppTheme.ink,
            activeTrackColor: _kYellow,
            inactiveThumbColor: AppTheme.paperMuted,
            inactiveTrackColor: AppTheme.paper.withValues(alpha: 0.12),
          ),
        ],
      ),
    );
  }
}

class _SettingAction extends StatelessWidget {
  const _SettingAction({
    required this.icon,
    required this.title,
    required this.description,
    required this.onPressed,
    this.danger = false,
  });

  final Widget icon;
  final String title;
  final String description;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final accent = danger ? const Color(0xFFFF8D7A) : AppTheme.lime;
    final titleColor = enabled
        ? AppTheme.paper
        : AppTheme.paper.withValues(alpha: 0.4);
    final bodyColor = enabled
        ? AppTheme.paperMuted
        : AppTheme.paperMuted.withValues(alpha: 0.45);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        hoverColor: accent.withValues(alpha: 0.07),
        splashColor: accent.withValues(alpha: 0.12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 14, 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: enabled ? 0.14 : 0.07),
                  shape: BoxShape.circle,
                ),
                child: Opacity(
                  opacity: enabled ? 1 : 0.4,
                  child: IconTheme(
                    data: IconThemeData(color: accent, size: 18),
                    child: icon,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.figtree(
                        color: titleColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: GoogleFonts.figtree(
                        color: bodyColor,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JobLog extends StatefulWidget {
  const _JobLog({required this.lines});

  final List<JobLogEntry> lines;

  @override
  State<_JobLog> createState() => _JobLogState();
}

class _JobLogState extends State<_JobLog> {
  final _scroll = ScrollController();
  static final _clock = DateFormat('HH:mm:ss');

  @override
  void didUpdateWidget(covariant _JobLog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lines.length == oldWidget.lines.length) return;
    final stick =
        !_scroll.hasClients ||
        _scroll.position.maxScrollExtent - _scroll.offset < 64;
    if (!stick) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _errorCount(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    if (mod10 == 1 && mod100 != 11) return '$count ошибка';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return '$count ошибки';
    }
    return '$count ошибок';
  }

  @override
  Widget build(BuildContext context) {
    final written = widget.lines.where((entry) => entry.ok).length;
    final failed = widget.lines.length - written;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.ink.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.paper.withValues(alpha: 0.06)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Журнал',
                  style: GoogleFonts.figtree(
                    color: AppTheme.paper,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                Text(
                  failed == 0
                      ? 'записано $written'
                      : 'записано $written · ${_errorCount(failed)}',
                  style: GoogleFonts.figtree(
                    color: AppTheme.paperMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: ListView.separated(
                controller: _scroll,
                itemCount: widget.lines.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  return _JobLogRow(
                    entry: widget.lines[index],
                    time: _clock.format(widget.lines[index].at),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JobLogRow extends StatelessWidget {
  const _JobLogRow({required this.entry, required this.time});

  final JobLogEntry entry;
  final String time;

  @override
  Widget build(BuildContext context) {
    final accent = entry.ok ? AppTheme.lime : const Color(0xFFFF8A80);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.inkLift.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 3,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(10),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          time,
                          style: GoogleFonts.figtree(
                            color: AppTheme.paperMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            entry.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.figtree(
                              color: AppTheme.paper,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.figtree(
                        color: AppTheme.paper.withValues(alpha: 0.86),
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                    if (entry.error != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        entry.error!,
                        style: GoogleFonts.figtree(
                          color: const Color(0xFFFF8A80),
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                    if (entry.fields.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final field in entry.fields)
                            _LogChip(label: field.label, value: field.value),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogChip extends StatelessWidget {
  const _LogChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.ink.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text.rich(
          TextSpan(
            style: GoogleFonts.figtree(fontSize: 11.5, height: 1.2),
            children: [
              TextSpan(
                text: '$label  ',
                style: const TextStyle(color: AppTheme.paperMuted),
              ),
              TextSpan(
                text: value,
                style: const TextStyle(
                  color: AppTheme.paper,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JobProgress extends StatelessWidget {
  const _JobProgress({required this.label, required this.value, this.onStop});

  final String label;
  final double? value;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.ink.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.figtree(
                      color: AppTheme.paperMuted,
                      fontSize: 12.5,
                      height: 1.3,
                    ),
                  ),
                ),
                if (onStop != null)
                  TextButton(
                    onPressed: onStop,
                    style: TextButton.styleFrom(
                      enabledMouseCursor: SystemMouseCursors.click,
                      foregroundColor: AppTheme.ink,
                      backgroundColor: _kYellow,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                      textStyle: GoogleFonts.figtree(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    child: const Text('Стоп'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 6,
                backgroundColor: AppTheme.paper.withValues(alpha: 0.08),
                color: _kYellow,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusNote extends StatelessWidget {
  const _StatusNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.moss.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.mossBright.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(
          text,
          style: GoogleFonts.figtree(
            color: AppTheme.paper,
            fontSize: 13,
            height: 1.35,
          ),
        ),
      ),
    );
  }
}
