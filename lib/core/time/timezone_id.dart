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
  return DateTime.now().timeZoneName;
}

/// Offsets for zone abbreviations stored by Records written before
/// `timezoneId` held IANA ids. Ambiguous ones use the most likely meaning
/// for this app's users (CST = US Central, IST = India).
const Map<String, int> _abbreviationOffsetMinutes = {
  'UTC': 0,
  'GMT': 0,
  'WET': 0,
  'BST': 60,
  'CET': 60,
  'CEST': 120,
  'EET': 120,
  'EEST': 180,
  'MSK': 180,
  'IST': 330,
  'SGT': 480,
  'HKT': 480,
  'JST': 540,
  'KST': 540,
  'AEST': 600,
  'AEDT': 660,
  'NZST': 720,
  'NZDT': 780,
  'HST': -600,
  'AKST': -540,
  'AKDT': -480,
  'PST': -480,
  'PDT': -420,
  'MST': -420,
  'MDT': -360,
  'CST': -360,
  'CDT': -300,
  'EST': -300,
  'EDT': -240,
};

final RegExp _gmtOffsetPattern = RegExp(
  r'^(?:GMT|UTC)([+-])(\d{1,2})(?::?(\d{2}))?$',
);

bool _tzDatabaseLoaded = false;

/// UTC offset of [timezoneId] at [epochMs], or null if the id is unknown.
/// Accepts IANA ids, `GMT+hh:mm` forms, and legacy abbreviations.
Duration? utcOffsetAt(String timezoneId, int epochMs) {
  if (!_tzDatabaseLoaded) {
    tz_data.initializeTimeZones();
    _tzDatabaseLoaded = true;
  }
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

  final minutes = _abbreviationOffsetMinutes[timezoneId];
  return minutes == null ? null : Duration(minutes: minutes);
}
