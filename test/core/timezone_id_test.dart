import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/time/timezone_id.dart';

void main() {
  group('ianaZoneForAbbreviation', () {
    test('maps unambiguous legacy abbreviations to IANA zones', () {
      expect(ianaZoneForAbbreviation('PST'), 'America/Los_Angeles');
      expect(ianaZoneForAbbreviation('PDT'), 'America/Los_Angeles');
      expect(ianaZoneForAbbreviation('JST'), 'Asia/Tokyo');
      expect(ianaZoneForAbbreviation('BST'), 'Europe/London');
    });

    test('documents the choice for ambiguous abbreviations', () {
      // Spec 08: CST = US Central, IST = India.
      expect(ianaZoneForAbbreviation('CST'), 'America/Chicago');
      expect(ianaZoneForAbbreviation('IST'), 'Asia/Kolkata');
    });

    test('leaves IANA ids, fixed offsets and unknown ids untouched', () {
      expect(ianaZoneForAbbreviation('America/Los_Angeles'), isNull);
      expect(ianaZoneForAbbreviation('GMT+05:30'), isNull);
      expect(ianaZoneForAbbreviation('Not/AZone'), isNull);
      expect(ianaZoneForAbbreviation(''), isNull);
    });
  });

  group('zone-aware wall clock helpers', () {
    // 2026-07-01 12:00 UTC.
    final noonUtc = DateTime.utc(2026, 7, 1, 12).millisecondsSinceEpoch;

    test('wallClockAt returns the local fields of the stored zone', () {
      final la = wallClockAt('America/Los_Angeles', noonUtc);
      expect(la.hour, 5); // PDT = UTC-7
      expect(la.day, 1);

      final tokyo = wallClockAt('Asia/Tokyo', noonUtc);
      expect(tokyo.hour, 21); // JST = UTC+9
    });

    test('zoneAbbreviationAt follows daylight saving', () {
      expect(zoneAbbreviationAt('America/Los_Angeles', noonUtc), 'PDT');
      expect(
        zoneAbbreviationAt(
          'America/Los_Angeles',
          DateTime.utc(2026, 1, 1, 12).millisecondsSinceEpoch,
        ),
        'PST',
      );
    });

    test('unknown zones fall back to a deterministic UTC reading', () {
      final wall = wallClockAt('Not/AZone', noonUtc);
      expect(wall.hour, 12);
      expect(wall.isUtc, isTrue);
    });

    test('epochMsFromWallClock undoes wallClockAt', () {
      final wall = wallClockAt('America/Los_Angeles', noonUtc);
      expect(
        epochMsFromWallClock(
          wall,
          'America/Los_Angeles',
          referenceEpochMs: noonUtc,
        ),
        noonUtc,
      );
    });

    test('an edit across a DST change lands on the right side', () {
      // 2026-03-08 02:00 PST springs forward to 03:00 PDT (10:00 UTC).
      final beforeJump = DateTime.utc(2026, 3, 8, 9); // 01:00 PST
      final wallAfterJump = DateTime.utc(2026, 3, 8, 5); // 05:00 PDT

      expect(
        epochMsFromWallClock(
          wallAfterJump,
          'America/Los_Angeles',
          referenceEpochMs: beforeJump.millisecondsSinceEpoch,
        ),
        DateTime.utc(2026, 3, 8, 12).millisecondsSinceEpoch,
      );
    });
  });
}
