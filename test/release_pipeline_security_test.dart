import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

// Security invariants for the release pipeline, asserted against the workflow
// definitions themselves so a future edit cannot silently reintroduce a tag
// interpolation or an unpinned action. The properties are behavioural: they
// describe what the pipeline must never do, not the order of its steps.
const _workflowDir = '.github/workflows';

File _workflowFile(String name) => File('$_workflowDir/$name');

List<File> _workflowFiles() {
  final files =
      Directory(_workflowDir)
          .listSync()
          .whereType<File>()
          .where(
            (file) => file.path.endsWith('.yml') || file.path.endsWith('.yaml'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

Map<String, dynamic> _loadWorkflow(File file) =>
    Map<String, dynamic>.from(loadYaml(file.readAsStringSync()) as Map);

Map<String, dynamic> _jobs(Map<String, dynamic> workflow) =>
    Map<String, dynamic>.from(workflow['jobs'] as Map);

Iterable<Map<String, dynamic>> _steps(Map<String, dynamic> job) sync* {
  final steps = job['steps'];
  if (steps is List) {
    for (final step in steps) {
      yield Map<String, dynamic>.from(step as Map);
    }
  }
}

Iterable<Map<String, dynamic>> _allSteps(Map<String, dynamic> workflow) sync* {
  for (final entry in _jobs(workflow).entries) {
    final job = Map<String, dynamic>.from(entry.value as Map);
    for (final step in _steps(job)) {
      yield step;
    }
  }
}

void main() {
  final files = _workflowFiles();

  group('release pipeline security invariants', () {
    test('finds the workflow definitions', () {
      expect(files, isNotEmpty);
      expect(
        files.map((file) => file.path),
        contains('$_workflowDir/release.yml'),
      );
    });

    test('no GitHub expression is interpolated into a shell body', () {
      for (final file in files) {
        final workflow = _loadWorkflow(file);
        for (final entry in _allSteps(workflow)) {
          final run = entry['run'];
          if (run is String) {
            expect(
              run,
              isNot(contains(r'${{')),
              reason:
                  '${file.path} step "${entry['name']}" interpolates '
                  'a GitHub expression into a run body; pass it via env',
            );
          }
        }
      }
    });

    test(
      'every third-party action is pinned to a commit SHA with a comment',
      () {
        final usesLine = RegExp(
          r'^\s*(?:-\s+)?uses:\s*(\S+)(?:\s+#\s*(\S+))?\s*$',
        );
        for (final file in files) {
          var checked = 0;
          for (final line in file.readAsLinesSync()) {
            final match = usesLine.firstMatch(line);
            if (match == null) {
              continue;
            }
            final ref = match.group(1) ?? '';
            if (ref.startsWith('./')) {
              continue; // local reusable workflow, not a third-party action
            }
            expect(
              ref,
              matches(RegExp(r'^[^@\s]+@[0-9a-f]{40}$')),
              reason:
                  '${file.path}: "$ref" must be pinned to a full commit SHA',
            );
            expect(
              match.group(2),
              isNotNull,
              reason:
                  '${file.path}: "$ref" needs a human-readable version '
                  'comment',
            );
            checked++;
          }
          expect(
            checked,
            greaterThan(0),
            reason: '${file.path} should reference at least one action',
          );
        }
      },
    );

    test('credential files written from secrets are removed on failure', () {
      final workflow = _loadWorkflow(_workflowFile('release.yml'));
      const credentialFiles = [
        'fastlane/play-supply-credentials.json',
        'android/key.properties',
      ];
      final cleanupSteps = _allSteps(workflow).where((entry) {
        final run = entry['run'];
        return run is String && run.contains('rm -f android/key.properties');
      });
      expect(
        cleanupSteps,
        isNotEmpty,
        reason: 'release.yml must clean up mounted credentials',
      );
      for (final entry in cleanupSteps) {
        final step = entry;
        expect(
          step['if'],
          'always()',
          reason: 'credential cleanup must run even when the release fails',
        );
        final run = step['run'] as String;
        for (final path in credentialFiles) {
          expect(run, contains(path));
        }
        expect(
          run,
          contains('.keystores'),
          reason: 'the upload keystore directory must be removed too',
        );
      }

      final allRuns = _allSteps(workflow)
          .map((entry) => entry['run'])
          .whereType<String>()
          .join('\n');
      for (final path in credentialFiles) {
        expect(
          allRuns,
          contains(path),
          reason: '$path is mounted from a secret and must be cleaned up',
        );
      }
    });

    test('no workflow uploads the working tree as an artifact', () {
      for (final file in files) {
        final workflow = _loadWorkflow(file);
        for (final entry in _allSteps(workflow)) {
          final uses = entry['uses'];
          if (uses is String && uses.startsWith('actions/upload-artifact')) {
            final withInputs = entry['with'];
            final path = withInputs is Map ? withInputs['path'] : null;
            expect(
              path,
              isNotNull,
              reason: '${file.path}: upload-artifact needs an explicit path',
            );
            final pathLines = path
                .toString()
                .split('\n')
                .map((line) => line.trim())
                .where((line) => line.isNotEmpty);
            final broadPaths = pathLines.where(
              (line) =>
                  line == '.' ||
                  line == './' ||
                  line == r'${{ github.workspace }}' ||
                  line == r'${{ github.workspace }}/' ||
                  line.contains('**'),
            );
            expect(
              broadPaths,
              isEmpty,
              reason:
                  '${file.path}: upload-artifact must enumerate paths, '
                  'never the whole working tree',
            );
          }
        }
      }
    });

    test('the release jobs wait behind the production environment', () {
      final workflow = _loadWorkflow(_workflowFile('release.yml'));
      final jobs = _jobs(workflow);
      final androidJob = Map<String, dynamic>.from(
        jobs['build-and-publish'] as Map,
      );
      final macosJob = Map<String, dynamic>.from(
        jobs['build-and-publish-macos'] as Map,
      );
      expect(androidJob['environment'], 'production');
      expect(macosJob['environment'], 'production');
    });

    test(
      'versionCode arithmetic is delegated, and the tag arrives as data',
      () {
        final workflow = _loadWorkflow(_workflowFile('release.yml'));
        final runs = _allSteps(workflow)
            .map((entry) => entry['run'])
            .whereType<String>()
            .toList();
        expect(
          runs.any((run) => run.contains('tool/derive_version_code.dart')),
          isTrue,
          reason: 'the workflow must call the pure versionCode module',
        );
        for (final run in runs) {
          expect(
            run,
            isNot(contains(r'$((')),
            reason: 'versionCode arithmetic must not live inline in shell',
          );
          expect(
            run,
            isNot(contains('github.ref_name')),
            reason:
                'the tag must reach steps through the TAG environment '
                'variable',
          );
        }
      },
    );

    test(
      'the release workflow consumes the short-lived token, not the PAT',
      () {
        final text = _workflowFile('release.yml').readAsStringSync();
        expect(text, isNot(contains('RELEASE_PLEASE_TOKEN')));
        expect(text, contains('secrets.GITHUB_TOKEN'));
      },
    );

    test('a single action updater keeps the pins current', () {
      final dependabot = File('.github/dependabot.yml').readAsStringSync();
      expect(dependabot, contains('package-ecosystem: github-actions'));
    });

    test('the operations docs require a reviewer on production', () {
      final docs = File('RELEASING.md').readAsStringSync().toLowerCase();
      expect(docs, contains('production'));
      expect(docs, contains('reviewer'));
    });
  });
}
