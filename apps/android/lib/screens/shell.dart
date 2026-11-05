import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/player_service.dart';
import '../theme/app_theme.dart';
import '../utils/breakpoints.dart';
import '../widgets/ambient_backdrop.dart';
import '../widgets/mini_player.dart';
import '../widgets/player_expansion.dart';
import 'browser_screen.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  /// Tabs stay alive after the first visit, but a hidden one is not laid out.
  final Set<int> _openedTabs = {0};

  /// Переключения вкладок для системной «назад».
  final List<int> _tabHistory = [];

  /// Per-tab navigators so detail pages don't cover the mini player.
  final List<GlobalKey<NavigatorState>> _navKeys = List.generate(
    4,
    (_) => GlobalKey<NavigatorState>(),
  );

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    super.dispose();
  }

  static const _navItems = <_NavItem>[
    _NavItem(
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
      label: 'Главная',
    ),
    _NavItem(
      icon: Icons.library_music_outlined,
      selectedIcon: Icons.library_music,
      label: 'Библиотека',
    ),
    _NavItem(
      icon: Icons.travel_explore_outlined,
      selectedIcon: Icons.travel_explore,
      label: 'Браузер',
    ),
    _NavItem(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: 'Настройки',
    ),
  ];

  Widget _tabRoot(int index) {
    final page = switch (index) {
      0 => const HomeScreen(),
      1 => const LibraryScreen(),
      2 => const BrowserScreen(),
      _ => const SettingsScreen(),
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        if (index != 0)
          AmbientBackdrop(
            accent: switch (index) {
              1 => const Color(0xFF3D6B8B),
              2 => const Color(0xFF3D5A8B),
              _ => AppTheme.moss,
            },
            secondary: switch (index) {
              1 => const Color(0xFF2A4A5C),
              2 => const Color(0xFF2A3A5C),
              _ => const Color(0xFF2A4A5C),
            },
          ),
        page,
      ],
    );
  }

  void _select(int i) {
    final firstVisit = _openedTabs.add(i);
    if (i == _index) {
      _navKeys[i].currentState?.popUntil((r) => r.isFirst);
      if (firstVisit) setState(() {});
      return;
    }
    _tabHistory.add(_index);
    if (_tabHistory.length > 32) {
      _tabHistory.removeAt(0);
    }
    setState(() => _index = i);
  }

  void _handleSystemBack() {
    // Полный плеер перехватывает «назад» сам; не трогаем вкладки под ним.
    if (context.read<PlayerExpansion>().isOpen) return;

    final nav = _navKeys[_index].currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return;
    }
    if (_tabHistory.isNotEmpty) {
      final prev = _tabHistory.removeLast();
      setState(() {
        _openedTabs.add(prev);
        _index = prev;
      });
      return;
    }
    if (_index != 0) {
      setState(() {
        _openedTabs.add(0);
        _index = 0;
      });
      return;
    }
    SystemNavigator.pop();
  }

  bool get _textInputFocused {
    final primary = FocusManager.instance.primaryFocus;
    final ctx = primary?.context;
    if (ctx == null) return false;
    return ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (_textInputFocused) return false;
    if (!mounted) return false;

    final player = context.read<PlayerService>();
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) {
        player.togglePlayPause();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      player.seekBy(const Duration(seconds: 10));
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      player.seekBy(const Duration(seconds: -10));
      return true;
    }
    return false;
  }

  static const _navHeight = 56.0;
  static const _miniReserve = 72.0;

  @override
  Widget build(BuildContext context) {
    final wide = isWideLayout(context);
    final hasTrack =
        context.select<PlayerService, bool>((p) => p.current != null);
    final miniPad = !wide && hasTrack ? _miniReserve : 0.0;

    final tabs = Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < _navItems.length; i++)
          if (_openedTabs.contains(i))
            Offstage(
              offstage: i != _index,
              child: TickerMode(
                enabled: i == _index,
                child: Navigator(
                  key: _navKeys[i],
                  onGenerateRoute: (settings) {
                    return MaterialPageRoute<void>(
                      settings: settings,
                      builder: (_) => _tabRoot(i),
                    );
                  },
                ),
              ),
            ),
      ],
    );

    final body = Row(
      children: [
        if (wide)
          _SideRail(
            selectedIndex: _index,
            onSelect: _select,
            items: _navItems,
          ),
        if (wide) const VerticalDivider(width: 1),
        Expanded(child: tabs),
      ],
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleSystemBack();
      },
      child: Material(
        color: AppTheme.ink,
        child: SafeArea(
          top: true,
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: Builder(
                  builder: (context) {
                    final mq = MediaQuery.of(context);
                    return MediaQuery(
                      data: mq.copyWith(
                        padding: mq.padding.copyWith(
                          bottom: mq.padding.bottom + miniPad,
                        ),
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          body,
                          if (!wide && hasTrack)
                            const Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: MiniPlayer(),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              if (!wide)
                ColoredBox(
                  color: AppTheme.ink,
                  child: SafeArea(
                    top: false,
                    child: NavigationBar(
                      selectedIndex: _index,
                      onDestinationSelected: _select,
                      height: _navHeight,
                      labelBehavior:
                          NavigationDestinationLabelBehavior.alwaysHide,
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.home_outlined),
                          selectedIcon: Icon(Icons.home),
                          label: 'Главная',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.library_music_outlined),
                          selectedIcon: Icon(Icons.library_music),
                          label: 'Библиотека',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.travel_explore_outlined),
                          selectedIcon: Icon(Icons.travel_explore),
                          label: 'Браузер',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.settings_outlined),
                          selectedIcon: Icon(Icons.settings),
                          label: 'Настройки',
                        ),
                      ],
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

class _NavItem {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.selectedIndex,
    required this.onSelect,
    required this.items,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final List<_NavItem> items;

  static const double _width = 72;
  static const double _btnSize = 48;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.ink,
      child: SizedBox(
        width: _width,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: [
                for (var i = 0; i < 2 && i < items.length; i++)
                  _RailButton(
                    item: items[i],
                    selected: selectedIndex == i,
                    size: _btnSize,
                    onTap: () => onSelect(i),
                  ),
                const Spacer(),
                for (var i = 2; i < items.length; i++)
                  _RailButton(
                    item: items[i],
                    selected: selectedIndex == i,
                    size: _btnSize,
                    onTap: () => onSelect(i),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.item,
    required this.selected,
    required this.size,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.lime : AppTheme.paperMuted;
    final fill = selected
        ? AppTheme.moss.withValues(alpha: 0.35)
        : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Tooltip(
        message: item.label,
        waitDuration: const Duration(milliseconds: 400),
        child: Material(
          color: fill,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            mouseCursor: SystemMouseCursors.click,
            onTap: onTap,
            hoverColor: AppTheme.moss.withValues(alpha: 0.22),
            splashColor: AppTheme.moss.withValues(alpha: 0.28),
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(
                selected ? item.selectedIcon : item.icon,
                color: color,
                size: 24,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
