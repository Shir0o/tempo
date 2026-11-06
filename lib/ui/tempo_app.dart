import 'package:flutter/material.dart';

import '../../core/backup/backup_service.dart';
import '../../core/export/csv_export_engine.dart';
import '../../core/speech/speech_input.dart';
import '../../core/state/day_recorder.dart';
import '../../core/state/record_commands.dart';
import '../../core/state/today_order.dart';
import '../../core/sync/google_drive_sync_service.dart';
import '../../core/sync/intent_queue.dart';
import '../../core/sync/peer_pairing.dart';
import '../../core/sync/sync_client.dart';
import '../../core/sync/sync_listener.dart';
import '../../data/database/tempo_database.dart';
import 'dashboard_view.dart';
import 'history_view.dart';
import 'settings_view.dart';
import 'stats_view.dart';
import 'theme/tempo_theme.dart';

/// Root Application Widget for Tempo across Android mobile and desktop surfaces.
class TempoApp extends StatefulWidget {
  /// The phone's always-running Lap. Null on the Mac, which reads the Lap from
  /// the replica instead and never opens one of its own.
  final DayRecorder? dayRecorder;

  final TempoDatabase database;

  /// The one seam every write path uses: [PhoneRecordCommands] on the phone,
  /// [RemoteRecordCommands] on the Mac's replica.
  final RecordCommands commands;

  /// The Mac's queue of proposed mutations, so the Day can show pending and
  /// rejected proposals in place. Derived from [commands] when omitted.
  final IntentQueue? intentQueue;

  /// The Mac's replication client and pairing, for the Sync section of
  /// Settings. Null on the phone.
  final SyncClient? syncClient;
  final PeerPairing? pairing;

  /// The phone's replication listener, which serves the Mac and creates the
  /// pairing code. Null on the Mac.
  final SyncListener? syncListener;

  final GoogleDriveSyncService? syncService;
  final BackupService? backupService;
  final CsvExportEngine? exportEngine;

  /// Android-only Activity filter capability.
  final bool showActivityFilter;

  /// Platform speech seam; null on the Mac and in tests.
  final SpeechInput? speechInput;

  const TempoApp({
    super.key,
    this.dayRecorder,
    required this.database,
    required this.commands,
    this.intentQueue,
    this.syncClient,
    this.pairing,
    this.syncListener,
    this.syncService,
    this.backupService,
    this.exportEngine,
    this.showActivityFilter = false,
    this.speechInput,
  });

  @override
  State<TempoApp> createState() => _TempoAppState();
}

class _TempoAppState extends State<TempoApp> with WidgetsBindingObserver {
  int _currentTabIndex = 0;
  late final ValueNotifier<TodayOrder> _todayOrder;
  late final ValueNotifier<int> _catalogRevision;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _todayOrder = ValueNotifier(TodayOrder.categories);
    _catalogRevision = ValueNotifier(0);
    _loadTodayOrder();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _todayOrder.dispose();
    _catalogRevision.dispose();
    super.dispose();
  }

  Future<void> _loadTodayOrder() async {
    try {
      final stored = await widget.database.getSetting(TodayOrder.storageKey);
      if (!mounted) return;
      _todayOrder.value = TodayOrder.fromStorage(stored);
    } catch (_) {
      // A missing or unreadable preference keeps the default order.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Timers do not run while the app is suspended, so catch up on every
    // midnight that passed in the background.
    if (state == AppLifecycleState.resumed) {
      widget.dayRecorder?.applyMidnightSplits();
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
    final commands = widget.commands;
    final intentQueue =
        widget.intentQueue ??
        (commands is RemoteRecordCommands ? commands.queue : null);
    final screens = [
      DashboardView(
        dayRecorder: widget.dayRecorder,
        database: widget.database,
        commands: widget.commands,
        todayOrder: _todayOrder,
        catalogRevision: _catalogRevision,
        showActivityFilter: widget.showActivityFilter,
        speechInput: widget.speechInput,
        onNavigateToStats: () => setState(() => _currentTabIndex = 2),
        onOpenHistory: () => setState(() => _currentTabIndex = 1),
      ),
      HistoryView(
        database: widget.database,
        dayRecorder: widget.dayRecorder,
        commands: widget.commands,
        intentQueue: intentQueue,
      ),
      StatsView(database: widget.database, isActive: _currentTabIndex == 2),
      SettingsView(
        database: widget.database,
        dayRecorder: widget.dayRecorder,
        syncService: widget.syncService,
        backupService: widget.backupService,
        exportEngine: widget.exportEngine,
        syncClient: widget.syncClient,
        syncListener: widget.syncListener,
        pairing: widget.pairing,
        todayOrder: _todayOrder,
        catalogRevision: _catalogRevision,
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
