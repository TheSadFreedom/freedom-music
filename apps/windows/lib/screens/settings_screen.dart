import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/library_service.dart';
import '../services/mod_service.dart';
import '../services/settings_service.dart';
import '../sync/sync_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ambient_backdrop.dart';
import '../widgets/kept_icons.dart';
import '../widgets/screen_title.dart';

const _kYellow = Color(0xFFFFDB4D);
const _kContentMax = 1040.0;
const _kNavBreakpoint = 880.0;

enum _SettingsCategory {
  playback,
  library,
  cloud,
  data,
  activity,
}

extension on _SettingsCategory {
  String get label => switch (this) {
    _SettingsCategory.playback => 'Воспроизведение',
    _SettingsCategory.library => 'Библиотека',
    _SettingsCategory.cloud => 'Облако',
    _SettingsCategory.data => 'Данные',
    _SettingsCategory.activity => 'Ход работы',
  };

  String get blurb => switch (this) {
    _SettingsCategory.playback =>
      'Как плеер ведёт себя при старте и между треками.',
    _SettingsCategory.library => 'Локальные пути и обновление каталога.',
    _SettingsCategory.cloud =>
      'Что уходит на Яндекс.Диск. Тумблеры только на этом устройстве.',
    _SettingsCategory.data => 'Локальные счётчики прослушиваний.',
    _SettingsCategory.activity => 'Прогресс скана и журнал заполнения.',
  };

  IconData get icon => switch (this) {
    _SettingsCategory.playback => Icons.graphic_eq_rounded,
    _SettingsCategory.library => Icons.folder_open_rounded,
    _SettingsCategory.cloud => Icons.cloud_outlined,
    _SettingsCategory.data => Icons.inventory_2_outlined,
    _SettingsCategory.activity => Icons.timeline_rounded,
  };

  Color get accent => switch (this) {
    _SettingsCategory.playback => _kYellow,
    _SettingsCategory.library => AppTheme.mossBright,
    _SettingsCategory.cloud => const Color(0xFFFFC46B),
    _SettingsCategory.data => const Color(0xFFB8A4FF),
    _SettingsCategory.activity => AppTheme.mossBright,
  };
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busyBackup = false;
  String? _backupMessage;
  String? _driveMessage;
  _SettingsCategory _active = _SettingsCategory.playback;

  void _select(_SettingsCategory category) {
    if (_active == category) return;
    setState(() => _active = category);
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
          content: SizedBox(
            width: 360,
            child: Column(
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
    try {
      await sync.signOut();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _driveMessage = sync.message ?? 'Вы вышли из облака');
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
    final library = context.read<LibraryService>();
    final settings = context.read<SettingsService>();
    final sync = context.watch<SyncService>();
    final mods = context.watch<ModService>();
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
      listenable: Listenable.merge([library, library.jobUi, sync]),
      builder: (context, _) {
        final progress = library.scanProgress;
        final scanning = library.scanning;
        final busy = scanning || _busyBackup || sync.busy;
        final showActivity = scanning ||
            progress != null ||
            library.jobLog.isNotEmpty ||
            library.lastScanMessage != null;

        final categories = [
          _SettingsCategory.playback,
          _SettingsCategory.library,
          _SettingsCategory.cloud,
          _SettingsCategory.data,
          if (showActivity) _SettingsCategory.activity,
        ];

        final active = categories.contains(_active)
            ? _active
            : categories.first;

        if (active != _active) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _active = active);
          });
        }

        final panel = switch (active) {
          _SettingsCategory.playback => _PanelShell(
            category: active,
            child: _Group(
              children: [
                _SettingSwitch(
                  title: 'Сканировать при запуске',
                  subtitle: 'Иначе скан только по кнопке.',
                  value: scanOnStartup,
                  onChanged: busy ? null : settings.setScanOnStartup,
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
          _SettingsCategory.library => _PanelShell(
            category: active,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SubLabel('Пути'),
                const SizedBox(height: 10),
                _Group(
                  children: [
                    _PathRow(label: 'music', value: library.paths.musicDir),
                    _PathRow(label: 'База', value: library.paths.databasePath),
                    _PathRow(label: 'Моды', value: mods.discovery.modsDir),
                  ],
                ),
                const SizedBox(height: 18),
                const _SubLabel('Сканирование'),
                const SizedBox(height: 10),
                _Group(
                  children: [
                    _SettingAction(
                      icon: const FolderOpenGlyph(),
                      title: 'Сканировать папку music',
                      description: 'Сканирует папку полностью.',
                      onPressed: busy
                          ? null
                          : () => library.scanLibrary(force: true),
                    ),
                    _SettingAction(
                      icon: const FiberNewGlyph(),
                      title: 'Поиск новых',
                      description:
                          'Сканирует только новые файлы и не трогает то, что уже было добавлено.',
                      onPressed: busy
                          ? null
                          : () => library.scanLibrary(newOnly: true),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _SettingsCategory.cloud => _PanelShell(
            category: active,
            trailing: _CloudBadge(signedIn: sync.isSignedIn),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                        onPressed: busy ? null : () => _signInDrive(sync),
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
                            : () => _syncDrive(library, sync),
                      ),
                      _SettingAction(
                        icon: const DownloadGlyph(),
                        title: 'Выйти',
                        description:
                            'Локальные данные останутся. Outbox не очищается.',
                        onPressed: () => _signOutDrive(sync),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 18),
                const _SubLabel('Категории синка'),
                const SizedBox(height: 10),
                _Group(
                  children: [
                    _SettingSwitch(
                      title: 'Прослушивания',
                      subtitle: 'История и счётчики прослушиваний.',
                      value: context.select<SettingsService, bool>(
                        (s) => s.syncPlays,
                      ),
                      onChanged: busy ? null : settings.setSyncPlays,
                    ),
                    _SettingSwitch(
                      title: 'Объединённые карточки',
                      subtitle: 'Слияния артистов и продюсеров.',
                      value: context.select<SettingsService, bool>(
                        (s) => s.syncAliases,
                      ),
                      onChanged: busy ? null : settings.setSyncAliases,
                    ),
                    _SettingSwitch(
                      title: 'Плейлисты',
                      subtitle: 'Ваши плейлисты (без системных).',
                      value: context.select<SettingsService, bool>(
                        (s) => s.syncPlaylists,
                      ),
                      onChanged: busy ? null : settings.setSyncPlaylists,
                    ),
                    _SettingSwitch(
                      title: 'Плейлист «Облако»',
                      subtitle:
                          'До 100 треков на Диске. Выкл. — скрыть из списка.',
                      value: context.select<SettingsService, bool>(
                        (s) => s.syncCloudPlaylist,
                      ),
                      onChanged: busy
                          ? null
                          : (v) async {
                              await settings.setSyncCloudPlaylist(v);
                              await library.reload();
                            },
                    ),
                    _SettingSwitch(
                      title: 'Фотографии артистов',
                      subtitle: 'Портреты на карточках артистов.',
                      value: context.select<SettingsService, bool>(
                        (s) => s.syncArtistPhotos,
                      ),
                      onChanged: busy ? null : settings.setSyncArtistPhotos,
                    ),
                  ],
                ),
                if (sync.busy) ...[
                  const SizedBox(height: 14),
                  const _InlineBusy(label: 'Синхронизация…'),
                ] else if (_driveMessage != null) ...[
                  const SizedBox(height: 14),
                  _StatusNote(text: _driveMessage!),
                ],
              ],
            ),
          ),
          _SettingsCategory.data => _PanelShell(
            category: active,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Group(
                  children: [
                    _SettingAction(
                      icon: const RestartGlyph(),
                      title: 'Сбросить',
                      description:
                          'Обнулить прослушивания. Плейлисты останутся.',
                      danger: true,
                      onPressed: busy ? null : () => _clearPlayCounts(library),
                    ),
                  ],
                ),
                if (_busyBackup) ...[
                  const SizedBox(height: 14),
                  const _InlineBusy(label: 'Обработка…'),
                ],
                if (_backupMessage != null) ...[
                  const SizedBox(height: 14),
                  _StatusNote(text: _backupMessage!),
                ],
              ],
            ),
          ),
          _SettingsCategory.activity => _PanelShell(
            category: active,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (scanning || progress != null)
                  _JobProgress(
                    label: progress == null
                        ? 'Подготовка…'
                        : '${progress.processed} / ${progress.total}'
                              '${progress.currentFile != null ? ' — ${progress.currentFile}' : ''}',
                    value: progress?.ratio,
                    onStop: scanning ? library.cancelScan : null,
                  ),
                if (library.jobLog.isNotEmpty) ...[
                  if (scanning || progress != null) const SizedBox(height: 12),
                  _JobLog(lines: library.jobLog),
                ],
                if (library.lastScanMessage != null) ...[
                  const SizedBox(height: 14),
                  _StatusNote(text: library.lastScanMessage!),
                ],
              ],
            ),
          ),
        };

        return Stack(
          children: [
            const Positioned.fill(
              child: AmbientBackdrop(
                accent: AppTheme.moss,
                secondary: Color(0xFF24382F),
              ),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final sideNav = constraints.maxWidth >= _kNavBreakpoint;
                final content = CustomScrollView(
                  slivers: [
                    const SliverToBoxAdapter(
                      child: ScreenTitle(title: 'Настройки'),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        sideNav ? 8 : 20,
                        0,
                        20,
                        40,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: _kContentMax,
                            ),
                            child: sideNav
                                ? Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: 228,
                                        child: _CategoryRail(
                                          categories: categories,
                                          active: active,
                                          scanning: scanning,
                                          cloudSignedIn: sync.isSignedIn,
                                          onSelect: _select,
                                        ),
                                      ),
                                      const SizedBox(width: 28),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            AnimatedSwitcher(
                                              duration: const Duration(
                                                milliseconds: 220,
                                              ),
                                              switchInCurve:
                                                  Curves.easeOutCubic,
                                              switchOutCurve:
                                                  Curves.easeInCubic,
                                              transitionBuilder:
                                                  (child, animation) {
                                                final slide = Tween<Offset>(
                                                  begin: const Offset(
                                                    0.02,
                                                    0.01,
                                                  ),
                                                  end: Offset.zero,
                                                ).animate(animation);
                                                return FadeTransition(
                                                  opacity: animation,
                                                  child: SlideTransition(
                                                    position: slide,
                                                    child: child,
                                                  ),
                                                );
                                              },
                                              child: KeyedSubtree(
                                                key: ValueKey(active),
                                                child: panel,
                                              ),
                                            ),
                                            const SizedBox(height: 22),
                                            const _FooterNote(),
                                          ],
                                        ),
                                      ),
                                    ],
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _CategoryChips(
                                        categories: categories,
                                        active: active,
                                        scanning: scanning,
                                        onSelect: _select,
                                      ),
                                      const SizedBox(height: 18),
                                      AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 220,
                                        ),
                                        switchInCurve: Curves.easeOutCubic,
                                        switchOutCurve: Curves.easeInCubic,
                                        child: KeyedSubtree(
                                          key: ValueKey(active),
                                          child: panel,
                                        ),
                                      ),
                                      const SizedBox(height: 22),
                                      const _FooterNote(),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );

                return content;
              },
            ),
          ],
        );
      },
    );
  }
}

class _PanelShell extends StatelessWidget {
  const _PanelShell({
    required this.category,
    required this.child,
    this.trailing,
  });

  final _SettingsCategory category;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final accent = category.accent;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.paper.withValues(alpha: 0.06)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(AppTheme.inkLift, accent, 0.12)!
                .withValues(alpha: 0.72),
            AppTheme.inkLift.withValues(alpha: 0.48),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.06),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: accent.withValues(alpha: 0.3)),
                  ),
                  child: Icon(category.icon, color: accent, size: 23),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        category.label,
                        style: GoogleFonts.syne(
                          color: AppTheme.paper,
                          fontWeight: FontWeight.w800,
                          fontSize: 22,
                          letterSpacing: -0.5,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        category.blurb,
                        style: GoogleFonts.figtree(
                          color: AppTheme.paperMuted,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 12),
                  trailing!,
                ],
              ],
            ),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );
  }
}

class _CloudBadge extends StatelessWidget {
  const _CloudBadge({required this.signedIn});

  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    final color = signedIn ? AppTheme.mossBright : AppTheme.paperMuted;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 7),
            Text(
              signedIn ? 'онлайн' : 'офлайн',
              style: GoogleFonts.figtree(
                color: color,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryRail extends StatelessWidget {
  const _CategoryRail({
    required this.categories,
    required this.active,
    required this.scanning,
    required this.cloudSignedIn,
    required this.onSelect,
  });

  final List<_SettingsCategory> categories;
  final _SettingsCategory active;
  final bool scanning;
  final bool cloudSignedIn;
  final ValueChanged<_SettingsCategory> onSelect;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.ink.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.paper.withValues(alpha: 0.06)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 16, 10, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
              child: Text(
                'Разделы',
                style: GoogleFonts.syne(
                  color: AppTheme.paperMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
            ),
            for (final category in categories) ...[
              _RailItem(
                category: category,
                selected: category == active,
                badge: category == _SettingsCategory.activity && scanning
                    ? _RailDot(color: _kYellow)
                    : category == _SettingsCategory.cloud
                        ? _RailDot(
                            color: cloudSignedIn
                                ? AppTheme.mossBright
                                : AppTheme.paperMuted.withValues(alpha: 0.55),
                          )
                        : null,
                onTap: () => onSelect(category),
              ),
              if (category != categories.last) const SizedBox(height: 4),
            ],
          ],
        ),
      ),
    );
  }
}

class _RailDot extends StatelessWidget {
  const _RailDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.category,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final _SettingsCategory category;
  final bool selected;
  final VoidCallback onTap;
  final Widget? badge;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.category.accent;
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.fromLTRB(8, 10, 10, 10),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.14)
                : _hovered
                    ? AppTheme.paper.withValues(alpha: 0.04)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 3,
                height: 28,
                decoration: BoxDecoration(
                  color: selected ? accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: selected ? 0.22 : 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  widget.category.icon,
                  size: 16,
                  color: selected ? accent : AppTheme.paperMuted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.category.label,
                  style: GoogleFonts.figtree(
                    color: selected ? AppTheme.paper : AppTheme.paperMuted,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
              ),
              if (widget.badge != null) widget.badge!,
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryChips extends StatelessWidget {
  const _CategoryChips({
    required this.categories,
    required this.active,
    required this.scanning,
    required this.onSelect,
  });

  final List<_SettingsCategory> categories;
  final _SettingsCategory active;
  final bool scanning;
  final ValueChanged<_SettingsCategory> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < categories.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _ChipItem(
              category: categories[i],
              selected: categories[i] == active,
              live: categories[i] == _SettingsCategory.activity && scanning,
              onTap: () => onSelect(categories[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChipItem extends StatelessWidget {
  const _ChipItem({
    required this.category,
    required this.selected,
    required this.live,
    required this.onTap,
  });

  final _SettingsCategory category;
  final bool selected;
  final bool live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = category.accent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        mouseCursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.16)
                : AppTheme.ink.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.38)
                  : AppTheme.paper.withValues(alpha: 0.07),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                category.icon,
                size: 15,
                color: selected ? accent : AppTheme.paperMuted,
              ),
              const SizedBox(width: 8),
              Text(
                category.label,
                style: GoogleFonts.figtree(
                  color: selected ? AppTheme.paper : AppTheme.paperMuted,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
              if (live) ...[
                const SizedBox(width: 8),
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: _kYellow,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SubLabel extends StatelessWidget {
  const _SubLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: GoogleFonts.figtree(
        color: AppTheme.paperMuted.withValues(alpha: 0.9),
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.0,
      ),
    );
  }
}

class _FooterNote extends StatelessWidget {
  const _FooterNote();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Локальный плеер. Метаданные файла — источник правды о треке.',
      textAlign: TextAlign.center,
      style: GoogleFonts.figtree(
        color: AppTheme.paperMuted.withValues(alpha: 0.75),
        fontSize: 12,
      ),
    );
  }
}

class _InlineBusy extends StatelessWidget {
  const _InlineBusy({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
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
          label,
          style: GoogleFonts.figtree(
            color: AppTheme.paperMuted,
            fontSize: 12,
          ),
        ),
      ],
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
        color: AppTheme.ink.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.paper.withValues(alpha: 0.045)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 14,
                  endIndent: 14,
                  color: AppTheme.paper.withValues(alpha: 0.055),
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
      padding: const EdgeInsets.fromLTRB(14, 11, 6, 11),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: GoogleFonts.figtree(
                color: AppTheme.paperMuted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
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
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
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
              DecoratedBox(
                decoration: BoxDecoration(
                  color: _kYellow.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  child: Text(
                    label,
                    style: GoogleFonts.figtree(
                      color: _kYellow,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
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
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
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
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: GoogleFonts.figtree(
                    color: AppTheme.paperMuted,
                    fontSize: 12,
                    height: 1.3,
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

class _SettingAction extends StatefulWidget {
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
  State<_SettingAction> createState() => _SettingActionState();
}

class _SettingActionState extends State<_SettingAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final accent = widget.danger ? const Color(0xFFFF8D7A) : AppTheme.lime;
    final titleColor = enabled
        ? AppTheme.paper
        : AppTheme.paper.withValues(alpha: 0.4);
    final bodyColor = enabled
        ? AppTheme.paperMuted
        : AppTheme.paperMuted.withValues(alpha: 0.45);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          color: _hovered && enabled
              ? accent.withValues(alpha: 0.06)
              : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: enabled ? 0.14 : 0.07),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Opacity(
                  opacity: enabled ? 1 : 0.4,
                  child: IconTheme(
                    data: IconThemeData(color: accent, size: 18),
                    child: widget.icon,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: GoogleFonts.figtree(
                        color: titleColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.description,
                      style: GoogleFonts.figtree(
                        color: bodyColor,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              if (enabled)
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 8),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: AppTheme.paperMuted.withValues(
                      alpha: _hovered ? 0.85 : 0.45,
                    ),
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
    final stick = !_scroll.hasClients ||
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
        color: AppTheme.ink.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.paper.withValues(alpha: 0.045)),
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
        color: AppTheme.ink.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.paper.withValues(alpha: 0.045)),
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
                        borderRadius: BorderRadius.circular(12),
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
              borderRadius: BorderRadius.circular(8),
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
        color: AppTheme.moss.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.mossBright.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
