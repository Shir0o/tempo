/// Pure derivation of the Android `versionCode` from a release tag.
///
/// Contract: `major * 10000 + minor * 100 + patch`.
/// A tag must be `v?MAJOR.MINOR.PATCH` with an optional pre-release suffix
/// (for example `v1.2.0-rc1`). The tag is attacker-influenced data, so
/// anything else is rejected rather than coerced, and the input is never
/// evaluated.
library;

/// The outcome of [deriveVersionCode].
///
/// Exactly one of [value] and [error] is non-null.
class VersionCodeResult {
  const VersionCodeResult.valid(int this.value) : error = null;

  const VersionCodeResult.invalid(String this.error) : value = null;

  /// The derived Android version code, or null when the tag was invalid.
  final int? value;

  /// A human-readable validation failure, or null when the tag was valid.
  final String? error;

  /// Whether [value] holds a version code.
  bool get isValid => error == null;
}

// v?MAJOR.MINOR.PATCH with an optional pre-release suffix. Components are
// strict semver: no leading zeros, so "v1.02.3" is rejected rather than
// silently coerced to 1.2.3.
final RegExp _releaseTagPattern = RegExp(
  r'^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
  r'(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
);

/// Returns the version code for [tag], or a validation failure.
///
/// [tag] is matched against [_releaseTagPattern] and never passed to a shell.
VersionCodeResult deriveVersionCode(String tag) {
  final match = _releaseTagPattern.firstMatch(tag);
  if (match == null) {
    return VersionCodeResult.invalid(
      "Tag '$tag' is not a valid release tag "
      '(expected vMAJOR.MINOR.PATCH with an optional pre-release suffix).',
    );
  }

  final major = int.tryParse(match.group(1) ?? '');
  final minor = int.tryParse(match.group(2) ?? '');
  final patch = int.tryParse(match.group(3) ?? '');
  if (major == null || minor == null || patch == null) {
    return VersionCodeResult.invalid(
      "Tag '$tag' has a version component too large to derive a version code.",
    );
  }

  return VersionCodeResult.valid(major * 10000 + minor * 100 + patch);
}
