import 'dart:io';

import 'package:tempo/core/version_code.dart';

/// Prints the Android versionCode derived from the release tag in argv[0].
///
/// The release workflow passes the tag as an environment variable, so this
/// script receives it as inert data. An invalid tag prints a GitHub Actions
/// error annotation and exits non-zero.
void main(List<String> arguments) {
  final tag = arguments.isEmpty ? '' : arguments.first;
  final result = deriveVersionCode(tag);
  if (result.isValid) {
    stdout.writeln(result.value);
  } else {
    stderr.writeln('::error::${result.error}');
    exitCode = 1;
  }
}
