import 'dart:async';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../core/state/day_recorder.dart';
import '../data/database/tempo_database.dart';
import '../data/models/models.dart';

/// Service handling the universal `tempo://` (and `timetracker://`) Deep Link Bus.
///
/// Endpoints:
/// - `tempo://start?activity=...&comment=...&tags=...` labels the open Lap.
/// - `tempo://stop` and `tempo://split` close the open Lap as an Untracked
///   Record without labelling it.
/// - `tempo://toggle?activity=...` labels the open Lap.
///
/// Pause and resume no longer exist.
class DeepLinkService {
  static const String channelName = 'com.tempos.tracker/deeplink';
  static const Set<String> supportedSchemes = {'tempo', 'timetracker'};

  final DayRecorder dayRecorder;
  final TempoDatabase database;
  final MethodChannel _channel;
  final int Function() _nowUtcMs;
  final String Function() _generateId;

  DeepLinkService({
    required this.dayRecorder,
    required this.database,
    MethodChannel? channel,
    int Function()? nowUtcMs,
    String Function()? generateId,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       _generateId = generateId ?? (() => const Uuid().v4()) {
    _initChannelHandler();
  }

  void _initChannelHandler() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDeepLinkReceived':
          final args = call.arguments;
          final url = (args is Map) ? args['url'] as String? : null;
          if (url != null && url.isNotEmpty) {
            await handleUrl(url);
          }
          break;
      }
    });

    // Check for initial deep link if app was launched via URL
    _checkInitialDeepLink();
  }

  Future<void> _checkInitialDeepLink() async {
    try {
      final initialUrl = await _channel.invokeMethod<String>(
        'getInitialDeepLink',
      );
      if (initialUrl != null && initialUrl.isNotEmpty) {
        await handleUrl(initialUrl);
      }
    } catch (_) {}
  }

  /// Parses a string URL and routes to the appropriate deep link handler.
  /// Returns `true` if recognized and executed successfully; otherwise `false`.
  Future<bool> handleUrl(String urlString) async {
    if (urlString.trim().isEmpty) return false;
    try {
      final uri = Uri.parse(urlString.trim());
      return await handleUri(uri);
    } catch (_) {
      return false;
    }
  }

  /// Routes an incoming [Uri] to the corresponding timer action.
  Future<bool> handleUri(Uri uri) async {
    final scheme = uri.scheme.toLowerCase();
    if (!supportedSchemes.contains(scheme)) {
      return false;
    }

    final action = _extractAction(uri);
    switch (action) {
      case 'start':
        return await _handleStart(uri);
      case 'stop':
        return await _handleSplit();
      case 'split':
        return await _handleSplit();
      case 'toggle':
        return await _handleToggle(uri);
      default:
        return false;
    }
  }

  String _extractAction(Uri uri) {
    if (uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.first.toLowerCase();
    }
    if (uri.host.isNotEmpty) {
      return uri.host.toLowerCase();
    }
    return '';
  }

  Future<bool> _handleStart(Uri uri) async {
    final activityParam = uri.queryParameters['activity'];
    if (activityParam == null || activityParam.trim().isEmpty) {
      return false;
    }

    final activity = await _findOrCreateActivity(activityParam.trim());
    final comment = uri.queryParameters['comment'] ?? '';
    final tagsRaw = uri.queryParameters['tags'] ?? '';
    final tagNames = tagsRaw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final tagIds = await _resolveTagIds(tagNames);

    await dayRecorder.label(activity.id, comment: comment, tags: tagIds);
    return true;
  }

  Future<bool> _handleSplit() async {
    await dayRecorder.split();
    return true;
  }

  Future<bool> _handleToggle(Uri uri) async {
    final activityParam = uri.queryParameters['activity'];

    if (activityParam != null && activityParam.trim().isNotEmpty) {
      final activity = await _findOrCreateActivity(activityParam.trim());
      await dayRecorder.label(activity.id);
    } else {
      await dayRecorder.sameAsLast();
    }
    return true;
  }

  // ==========================================
  // Activity & Tag Resolvers
  // ==========================================

  Future<Activity> _findOrCreateActivity(String identifier) async {
    // 1. Try exact ID lookup
    final byId = await database.getActivityById(identifier);
    if (byId != null) return byId;

    // 2. Try case-insensitive name match
    final all = await database.getAllActivities(includeArchived: true);
    for (final a in all) {
      if (a.name.toLowerCase() == identifier.toLowerCase()) {
        return a;
      }
    }

    // 3. Create new Activity if not found
    final now = _nowUtcMs();
    final newActivity = Activity(
      id: _generateId(),
      name: identifier,
      colorHex: '#4CAF50',
      iconName: 'schedule',
      isPinned: false,
      sortOrder: all.length,
      isArchived: false,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
    );
    await database.insertActivity(newActivity);
    return newActivity;
  }

  Future<List<String>> _resolveTagIds(List<String> tagNames) async {
    if (tagNames.isEmpty) return const [];
    final tagIds = <String>[];
    final allTags = await database.getAllTags();

    for (final name in tagNames) {
      Tag? existing;
      for (final t in allTags) {
        if (t.name.toLowerCase() == name.toLowerCase()) {
          existing = t;
          break;
        }
      }

      if (existing != null) {
        tagIds.add(existing.id);
      } else {
        final now = _nowUtcMs();
        final newTag = Tag(
          id: _generateId(),
          name: name,
          colorHex: '#9E9E9E',
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        );
        await database.insertTag(newTag);
        allTags.add(newTag);
        tagIds.add(newTag.id);
      }
    }
    return tagIds;
  }
}
