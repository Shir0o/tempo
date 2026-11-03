import 'package:flutter/material.dart';

import '../../core/export/csv_export_engine.dart';
import '../../core/state/day_recorder.dart';
import '../../core/sync/google_drive_sync_service.dart';
import '../../data/database/tempo_database.dart';
import 'dashboard_view.dart';
import 'history_view.dart';
import 'settings_view.dart';
import 'stats_view.dart';
import 'theme/tempo_theme.dart';

/// Root Application Widget for Tempo across Android mobile and desktop surfaces.
class TempoApp extends StatefulWidget {
  final DayRecorder dayRecorder;
  final TempoDatabase database;
  final GoogleDriveSyncService? syncService;
  final CsvExportEngine? exportEngine;

  const TempoApp({
    super.key,
    required this.dayRecorder,
    required this.database,
    this.syncService,
    this.exportEngine,
  });

  @override
  State<TempoApp> createState() => _TempoAppState();
}

class _TempoAppState extends State<TempoApp> with WidgetsBindingObserver {
  int _currentTabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Timers do not run while the app is suspended, so catch up on every
    // midnight that passed in the background.
    if (state == AppLifecycleState.resumed) {
      widget.dayRecorder.applyMidnightSplits();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tempo',
      debugShowCheckedModeBanner: false,
      theme: buildTempoTheme(),
      home: _buildHomeShell(),
    );
  }

  Widget _buildHomeShell() {
    final screens = [
      DashboardView(
        dayRecorder: widget.dayRecorder,
        database: widget.database,
        onNavigateToStats: () => setState(() => _currentTabIndex = 2),
        onOpenHistory: () => setState(() => _currentTabIndex = 1),
      ),
      HistoryView(database: widget.database, dayRecorder: widget.dayRecorder),
      StatsView(database: widget.database),
      SettingsView(
        database: widget.database,
        syncService: widget.syncService,
        exportEngine: widget.exportEngine,
      ),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentTabIndex, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTabIndex,
        onDestinationSelected: (index) =>
            setState(() => _currentTabIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view_rounded),
            label: 'Today',
          ),
          NavigationDestination(
            icon: Icon(Icons.view_agenda_outlined),
            selectedIcon: Icon(Icons.view_agenda_rounded),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart_rounded),
            label: 'Totals',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
