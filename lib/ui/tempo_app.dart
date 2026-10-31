import 'package:flutter/material.dart';
import '../../core/export/csv_export_engine.dart';
import '../../core/state/timer_state_machine.dart';
import '../../core/sync/google_drive_sync_service.dart';
import '../../data/database/tempo_database.dart';
import 'dashboard_view.dart';
import 'history_view.dart';
import 'settings_view.dart';
import 'stats_view.dart';

/// Root Application Widget for Tempo across Android mobile and desktop surfaces.
class TempoApp extends StatefulWidget {
  final TimerStateMachine timerStateMachine;
  final TempoDatabase database;
  final GoogleDriveSyncService? syncService;
  final CsvExportEngine? exportEngine;

  const TempoApp({
    super.key,
    required this.timerStateMachine,
    required this.database,
    this.syncService,
    this.exportEngine,
  });

  @override
  State<TempoApp> createState() => _TempoAppState();
}

class _TempoAppState extends State<TempoApp> {
  int _currentTabIndex = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tempo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121216),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4CAF50),
          secondary: Color(0xFF2196F3),
          surface: Color(0xFF1A1A22),
          error: Color(0xFFD32F2F),
        ),
        cardColor: const Color(0xFF1A1A22),
        dividerColor: Colors.white10,
        useMaterial3: true,
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF16161E),
          indicatorColor: const Color(0xFF4CAF50).withValues(alpha: 0.25),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const TextStyle(
                color: Color(0xFF4CAF50),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              );
            }
            return const TextStyle(color: Colors.white54, fontSize: 11);
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const IconThemeData(color: Color(0xFF4CAF50), size: 22);
            }
            return const IconThemeData(color: Colors.white54, size: 22);
          }),
        ),
      ),
      home: _buildHomeShell(),
    );
  }

  Widget _buildHomeShell() {
    final screens = [
      DashboardView(
        timerStateMachine: widget.timerStateMachine,
        database: widget.database,
        onNavigateToStats: () => setState(() => _currentTabIndex = 1),
      ),
      StatsView(database: widget.database),
      HistoryView(database: widget.database),
      SettingsView(
        database: widget.database,
        syncService: widget.syncService,
        exportEngine: widget.exportEngine,
      ),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentTabIndex,
        children: screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTabIndex,
        onDestinationSelected: (index) => setState(() => _currentTabIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.timer_outlined),
            selectedIcon: Icon(Icons.timer),
            label: 'Tracking',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Statistics',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
