import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/player_service.dart';
import '../theme/app_theme.dart';
import '../utils/breakpoints.dart';
import '../widgets/ambient_backdrop.dart';
import '../widgets/mini_player.dart';
import '../widgets/player_expansion.dart';
import 'chart_screen.dart';
import 'home_screen.dart';
import 'playlists_screen.dart';
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

  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();

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
      icon: Icons.ssid_chart_rounded,
      selectedIcon: Icons.ssid_chart_rounded,
      label: 'Чарты',
    ),
    _NavItem(
      icon: Icons.queue_music_outlined,
      selectedIcon: Icons.queue_music,
      label: 'Плейлисты',
    ),
    _NavItem(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: 'Настройки',
    ),
  ];

  Widget _tabRoot(int index) {
    final page = switch (index) {
      0 => HomeScreen(key: _homeKey),
      1 => const ChartScreen(),
      2 => const PlaylistsScreen(),
      _ => const SettingsScreen(),
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        // SettingsScreen рисует свой AmbientBackdrop.
        if (index == 1 || index == 2)
          AmbientBackdrop(
            accent: switch (index) {
              1 => const Color(0xFF8B6B3D),
              _ => const Color(0xFF5A3A6E),
            },
            secondary: switch (index) {
              1 => const Color(0xFF5A3A2A),
              _ => const Color(0xFF3D2A5C),
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
      if (i == 0) _homeKey.currentState?.clearSearch();
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
    // Диалоги / sheet на корневом навигаторе.
    final rootNav = Navigator.of(context, rootNavigator: true);
    if (rootNav.canPop()) {
      rootNav.pop();
      return;
    }

    // Панель внутри плеера → сам плеер → дальше вкладки.
    if (context.read<PlayerExpansion>().handleBack()) return;

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
                _BottomNav(
                  selectedIndex: _index,
                  onSelect: _select,
                  items: _navItems,
                  height: _navHeight,
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

class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.selectedIndex,
    required this.onSelect,
    required this.items,
    required this.height,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final List<_NavItem> items;
  final double height;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.ink,
        border: Border(
          top: BorderSide(
            color: AppTheme.paper.withValues(alpha: 0.07),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _BottomNavItem(
                      item: items[i],
                      selected: selectedIndex == i,
                      onTap: () => onSelect(i),
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

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.lime : AppTheme.paperMuted;

    return Semantics(
      button: true,
      label: item.label,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          splashColor: AppTheme.moss.withValues(alpha: 0.2),
          highlightColor: AppTheme.moss.withValues(alpha: 0.1),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.symmetric(
                horizontal: selected ? 16 : 12,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? AppTheme.moss.withValues(alpha: 0.32)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
              ),
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

class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.selectedIndex,
    required this.onSelect,
    required this.items,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final List<_NavItem> items;

  static const double _width = 84;
  static const double _btnSize = 48;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.ink,
        border: Border(
          right: BorderSide(
            color: AppTheme.paper.withValues(alpha: 0.07),
          ),
        ),
      ),
      child: SizedBox(
        width: _width,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Tooltip(
        message: item.label,
        waitDuration: const Duration(milliseconds: 400),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            mouseCursor: SystemMouseCursors.click,
            hoverColor: AppTheme.moss.withValues(alpha: 0.18),
            splashColor: AppTheme.moss.withValues(alpha: 0.24),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: size + 8,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: selected
                    ? AppTheme.moss.withValues(alpha: 0.32)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: SizedBox(
                height: size,
                child: Center(
                  child: Icon(
                    selected ? item.selectedIcon : item.icon,
                    color: color,
                    size: 24,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
