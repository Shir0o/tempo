import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/version_code.dart';

void main() {
  group('deriveVersionCode', () {
    test('derives major*10000 + minor*100 + patch from a plain tag', () {
      expect(deriveVersionCode('v1.2.0').value, 10200);
      expect(deriveVersionCode('v1.2.3').value, 10203);
      expect(deriveVersionCode('v12.34.56').value, 123456);
    });

    test('treats the leading v as optional', () {
      expect(deriveVersionCode('1.2.3').value, 10203);
      expect(deriveVersionCode('0.1.0').value, 100);
      expect(deriveVersionCode('0.0.0').value, 0);
    });

    test('ignores an rc/beta pre-release suffix', () {
      expect(deriveVersionCode('v1.2.0-rc1').value, 10200);
      expect(deriveVersionCode('v1.2.0-beta.2').value, 10200);
      expect(deriveVersionCode('1.4.0-rc.1').value, 10400);
    });

    test('rejects anything that is not a plain semantic version', () {
      const tags = [
        '',
        'v',
        'v1',
        'v1.2',
        'v1.2.3.4',
        'vv1.2.3',
        '1.2.3-',
        'v1..2',
        'v1.2.x',
        'v-1.2.3',
        'v1.-2.3',
        'v1.2.-3',
        'v1.02.3',
        'v01.2.3',
        'v1.2.03',
        'v1.2.3+build.4',
        'v99999999999999999999999.0.0',
      ];
      for (final tag in tags) {
        final result = deriveVersionCode(tag);
        expect(
          result.isValid,
          isFalse,
          reason: 'expected "$tag" to be rejected',
        );
        expect(result.value, isNull, reason: '"$tag" must not produce a code');
        expect(
          result.error,
          isNotNull,
          reason: '"$tag" needs a failure reason',
        );
      }
    });

    test('rejects hostile shell metacharacters instead of evaluating them', () {
      const hostile = [
        r'v1.2.3; echo pwned',
        r'v1.2.3$(id)',
        r'v1.2.3`id`',
        r'v1.2.3 && rm -rf /',
        r'v1.2.3|cat /etc/passwd',
        'v1.2.3\nid',
        r'v1.2.3 ',
        r' v1.2.3',
        r'v1.2.3;touch /tmp/pwned',
      ];
      for (final tag in hostile) {
        final result = deriveVersionCode(tag);
        expect(
          result.isValid,
          isFalse,
          reason: 'expected "$tag" to be rejected',
        );
        expect(result.value, isNull);
      }
    });
  });
}
