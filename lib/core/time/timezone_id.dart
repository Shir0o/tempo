import 'dart:io';

import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Best-effort IANA zone id (e.g. `America/Los_Angeles`) of this machine,
/// read from the `/etc/localtime` symlink on macOS/Linux. Falls back to the
/// zone abbreviation when the link is unavailable (e.g. Android, sandboxing).
String localTimezoneId() {
  try {
    final target = Link('/etc/localtime').targetSync();
    final i = target.indexOf('zoneinfo/');
    if (i >= 0) return target.substring(i + 'zoneinfo/'.length);
  } catch (_) {}
  final fallback = DateTime.now().timeZoneName;
  // Platforms without the symlink (e.g. Android) report an abbreviation;
  // upgrade it to the IANA zone when the mapping is unambiguous.
  return ianaZoneForAbbreviation(fallback) ?? fallback;
}

/// Canonical IANA zone for each legacy abbreviation. Ambiguous abbreviations
/// resolve to the choice documented in spec 08: `CST` is US Central
/// (`America/Chicago`) and `IST` is India (`Asia/Kolkata`). The choice is made
/// once here so migrated rows stay stable.
const Map<String, String> _abbreviationToIana = {
  'UTC': 'Etc/UTC',
  'GMT': 'Etc/GMT',
  'WET': 'Europe/Lisbon',
  'BST': 'Europe/London',
  'CET': 'Europe/Paris',
  'CEST': 'Europe/Paris',
  'EET': 'Europe/Athens',
  'EEST': 'Europe/Athens',
  'MSK': 'Europe/Moscow',
  'IST': 'Asia/Kolkata',
  'SGT': 'Asia/Singapore',
  'HKT': 'Asia/Hong_Kong',
  'JST': 'Asia/Tokyo',
  'KST': 'Asia/Seoul',
  'AEST': 'Australia/Sydney',
  'AEDT': 'Australia/Sydney',
  'NZST': 'Pacific/Auckland',
  'NZDT': 'Pacific/Auckland',
  'HST': 'Pacific/Honolulu',
  'AKST': 'America/Anchorage',
  'AKDT': 'America/Anchorage',
  'PST': 'America/Los_Angeles',
  'PDT': 'America/Los_Angeles',
  'MST': 'America/Denver',
  'MDT': 'America/Denver',
  'CST': 'America/Chicago',
  'CDT': 'America/Chicago',
  'EST': 'America/New_York',
  'EDT': 'America/New_York',
};

bool _tzDatabaseLoaded = false;

final RegExp _gmtOffsetPattern = RegExp(
  r'^(?:GMT|UTC)([+-])(\d{1,2})(?::?(\d{2}))?$',
);

void _ensureTimezoneDatabase() {
  if (_tzDatabaseLoaded) return;
  tz_data.initializeTimeZones();
  _tzDatabaseLoaded = true;
}

/// The IANA zone that best represents a legacy abbreviation such as `PST`,
/// or null when [timezoneId] is not a known abbreviation (already IANA,
/// a fixed offset, or unknown).
String? ianaZoneForAbbreviation(String timezoneId) {
  final normalized = timezoneId.trim().toUpperCase();
  if (normalized.isEmpty) return null;
  _ensureTimezoneDatabase();
  try {
    tz.getLocation(timezoneId);
    return null;
  } on tz.LocationNotFoundException {
    // Not IANA; fall through to the legacy map.
  }
  return _abbreviationToIana[normalized];
}

/// UTC offset of [timezoneId] at [epochMs], or null if the id is unknown.
/// Accepts IANA ids, `GMT+hh:mm` forms, and legacy abbreviations.
Duration? utcOffsetAt(String timezoneId, int epochMs) {
  _ensureTimezoneDatabase();
  try {
    return tz.getLocation(timezoneId).timeZone(epochMs).offset;
  } on tz.LocationNotFoundException {
    // Not an IANA id; try the legacy forms below.
  }

  final match = _gmtOffsetPattern.firstMatch(timezoneId);
  if (match != null) {
    final minutes = int.parse(match[2]!) * 60 + int.parse(match[3] ?? '0');
    return Duration(minutes: match[1] == '-' ? -minutes : minutes);
  }

  final subject = _abbreviationToIana[timezoneId.toUpperCase()];
  if (subject == null) return null;
  try {
    return tz.getLocation(subject).timeZone(epochMs).offset;
  } on tz.LocationNotFoundException {
    return null;
  }
}

/// The wall-clock time in [timezoneId] at [epochMs], encoded as a UTC
/// [DateTime] whose fields are the local fields. Unknown zones fall back to a
/// deterministic UTC reading rather than the device's current zone.
DateTime wallClockAt(String timezoneId, int epochMs) {
  final offset = utcOffsetAt(timezoneId, epochMs);
  if (offset == null) {
    return DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
  }
  return DateTime.fromMillisecondsSinceEpoch(
    epochMs + offset.inMilliseconds,
    isUtc: true,
  );
}

/// The first instant strictly after [afterEpochMs] at which the local calendar
/// date in [timezoneId] changes: local midnight, or the first instant of the
/// new day where a zone skips midnight entirely. DST shifts are handled by
/// searching in absolute time, so a 23h or 25h day still has one boundary.
int nextLocalMidnightUtcMs(String timezoneId, int afterEpochMs) {
  final afterWall = wallClockAt(timezoneId, afterEpochMs);
  final targetDate = DateTime.utc(
    afterWall.year,
    afterWall.month,
    afterWall.day,
  ).add(const Duration(days: 1));

  // A local day is never longer than 25h; 30h plus rolling days covers zones
  // that skip midnight during a DST change.
  var lo = afterEpochMs;
  var hi = afterEpochMs + const Duration(hours: 30).inMilliseconds;
  while (_localDateAt(timezoneId, hi).isBefore(targetDate)) {
    hi += const Duration(hours: 24).inMilliseconds;
  }

  while (hi - lo > 1) {
    final mid = lo + (hi - lo) ~/ 2;
    if (_localDateAt(timezoneId, mid).isBefore(targetDate)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return hi;
}

DateTime _localDateAt(String timezoneId, int epochMs) {
  final wall = wallClockAt(timezoneId, epochMs);
  return DateTime.utc(wall.year, wall.month, wall.day);
}

/// The abbreviation in effect in [timezoneId] at [epochMs] (e.g. `PDT`), or
/// the id itself when the zone cannot be resolved.
String zoneAbbreviationAt(String timezoneId, int epochMs) {
  _ensureTimezoneDatabase();
  try {
    return tz.getLocation(timezoneId).timeZone(epochMs).abbreviation;
  } on tz.LocationNotFoundException {
    return timezoneId;
  }
}

/// Converts a wall-clock [time] back to a UTC epoch millisecond instant in
/// [timezoneId]. [referenceEpochMs] seeds the offset lookup; the instant is
/// then re-checked so an edit across a DST change lands on the right side.
int epochMsFromWallClock(
  DateTime time,
  String timezoneId, {
  required int referenceEpochMs,
}) {
  final wallMs = time.millisecondsSinceEpoch;
  final referenceOffset = utcOffsetAt(timezoneId, referenceEpochMs);
  if (referenceOffset == null) return wallMs;

  var candidate = wallMs - referenceOffset.inMilliseconds;
  final offsetAtCandidate = utcOffsetAt(timezoneId, candidate);
  if (offsetAtCandidate != null && offsetAtCandidate != referenceOffset) {
    candidate = wallMs - offsetAtCandidate.inMilliseconds;
  }
  return candidate;
}
