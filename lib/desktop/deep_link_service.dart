import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../core/state/record_commands.dart';
import '../data/database/tempo_database.dart';
import '../data/models/models.dart';

/// Service handling the universal `tempo://` (and `timetracker://`) Deep Link Bus.
///
/// Endpoints:
/// - `tempo://start?activity=...&comment=...&tags=...` labels the open Lap.
/// - `tempo://split` closes the open Lap as an Untracked Record without
///   labelling it.
///
/// The action goes through [RecordCommands], so the phone writes the Record and
/// the Mac queues an intent at the instant the link arrived.
///
/// Links naming an Activity that does not exist are refused without touching
/// the Lap. [lastError] carries the reason for the most recent refusal.
class DeepLinkService {
  static const String channelName = 'com.tempos.tracker/deeplink';
  static const Set<String> supportedSchemes = {'tempo', 'timetracker'};

  final RecordCommands commands;
  final TempoDatabase database;
  final MethodChannel _channel;
  final int Function() _nowUtcMs;
  final String Function() _generateId;
  final void Function(String message)? onError;

  /// Whether a link may create a Tag it does not recognise. False on a
  /// replica, where a local write would be discarded by the next replay.
  final bool createMissingTags;

  String? _lastError;

  DeepLinkService({
    required this.commands,
    required this.database,
    MethodChannel? channel,
    int Function()? nowUtcMs,
    String Function()? generateId,
    this.onError,
    this.createMissingTags = true,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       _generateId = generateId ?? (() => const Uuid().v4()) {
    _initChannelHandler();
  }

  /// Why the most recent link was refused, or null when it succeeded.
  String? get lastError => _lastError;

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
    _lastError = null;
    if (urlString.trim().isEmpty) {
      return _refuse('The link is empty.');
    }
    try {
      final uri = Uri.parse(urlString.trim());
      return await handleUri(uri);
    } catch (_) {
      return _refuse('The link could not be parsed.');
    }
  }

  /// Routes an incoming [Uri] to the corresponding Lap action.
  Future<bool> handleUri(Uri uri) async {
    _lastError = null;
    final scheme = uri.scheme.toLowerCase();
    if (!supportedSchemes.contains(scheme)) {
      return _refuse('Unsupported link scheme "$scheme".');
    }

    final action = _extractAction(uri);
    switch (action) {
      case 'start':
        return await _handleStart(uri);
      case 'split':
        return await _handleSplit();
      default:
        return _refuse('Unsupported link action "$action".');
    }
  }

  /// Records and reports a refusal without changing the Lap.
  bool _refuse(String message) {
    _lastError = message;
    debugPrint('Tempo deep link refused: $message');
    onError?.call(message);
    return false;
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
      return _refuse('A start link needs an Activity.');
    }

    final identifier = activityParam.trim();
    final activity = await _findActivity(identifier);
    if (activity == null) {
      return _refuse('Unknown Activity "$identifier".');
    }

    final comment = uri.queryParameters['comment'] ?? '';
    final tagsRaw = uri.queryParameters['tags'] ?? '';
    final tagNames = tagsRaw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final tagIds = await _resolveTagIds(tagNames);

    await commands.label(activity.id, comment: comment, tags: tagIds);
    return true;
  }

  Future<bool> _handleSplit() async {
    await commands.split();
    return true;
  }

  // ==========================================
  // Activity & Tag Resolvers
  // ==========================================

  /// Resolves an Activity by ID or case-insensitive name. Deep links never
  /// create Activities, so a typo cannot silently change what the Lap means.
  Future<Activity?> _findActivity(String identifier) async {
    final byId = await database.getActivityById(identifier);
    if (byId != null) return byId;

    final all = await database.getAllActivities(includeArchived: true);
    for (final a in all) {
      if (a.name.toLowerCase() == identifier.toLowerCase()) {
        return a;
      }
    }
    return null;
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
      } else if (!createMissingTags) {
        continue;
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
