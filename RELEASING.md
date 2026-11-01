# Releasing Tempo

This document describes the automated release pipeline that ships Android (APK + AAB)
and macOS (DMG + ZIP) artifacts to GitHub Releases and uploads the Android AAB to
the Google Play Console **internal testing** track. Production promotion remains a manual
step in the Play Console UI.

## How a release happens

1. A conventional-commit PR (e.g. `feat:`, `fix:`) lands on `main`.
   The title carries the conventional-commit signal — Release Please
   reads **PR titles**, not individual commit messages.
2. The `.github/workflows/release-please.yml` workflow opens or updates a
   **release PR**. The PR bumps `pubspec.yaml` (bare semver, e.g. `1.0.0`)
   and appends formatted release notes to `RELEASE.md`. The build number / `versionCode`
   is derived from the git tag by the `release.yml` workflow at build time
   (`major*10000 + minor*100 + patch`, e.g. `v1.0.0` → `10000`).
3. You review the release PR (check the changelog draft in `RELEASE.md` and the
   version bump in `pubspec.yaml`), then squash and merge it.
4. The merge pushes a tag (e.g. `v1.0.0`). The `.github/workflows/release.yml` workflow fires:
   - **Android**: Assembles `android/key.properties` from GitHub secrets, derives the `versionCode` from the tag, builds signed AAB + APK with `--build-number=$vc`, attaches both to the GitHub Release, extracts release notes from `RELEASE.md`, and uploads the AAB to the Play Console internal testing track via `fastlane play_upload` as a draft.
   - **macOS**: Derives `versionCode` from the tag, builds universal macOS app with `--build-number=$vc`, packages `tempo-macos.dmg` (with an `/Applications` shortcut) and `tempo-macos.zip`, and attaches both to the GitHub Release.
5. **You** open the Play Console, verify the AAB on the internal testing track, and click **Promote release → Production** when ready.

That's the whole flow. There is no manual version bump, no manual tag, and no manual upload.

## PR title conventions (required)

The lint workflow `.github/workflows/pr-title-lint.yml` rejects PRs whose titles
don't match a conventional-commit prefix. Allowed prefixes:

| Prefix            | Effect                                |
| ----------------- | ------------------------------------- |
| `feat:`           | Minor bump; lands under "Features"    |
| `feat!:`          | Major bump; lands under "Features"    |
| `fix:`            | Patch bump; lands under "Bug Fixes"   |
| `perf:`           | Patch bump; lands under "Performance" |
| `refactor:`       | No bump; lands under "Refactoring"    |
| `docs:`, `test:`, `build:`, `ci:`, `chore:`, `revert:` | Hidden from release notes (still allowed) |

`BREAKING CHANGE:` in the PR body footer also triggers a major bump.

## Prerequisites (one-time setup)

Before the first release, configure the `production` environment
(repository **Settings** > **Environments** > **production**) to require
at least one **reviewer**. The release job waits for that approval before
it mounts the Play Console service account, so a bad tag cannot publish
unattended.

The pipeline requires six GitHub secrets under **Settings → Secrets and variables → Actions**:

| Secret                  | Purpose                                                                 |
| ----------------------- | ----------------------------------------------------------------------- |
| `RELEASE_PLEASE_TOKEN`  | Fine-grained PAT scoped to this repository with only `contents:write` and `pull-requests:write`. **Required** for `release-please.yml` only: tags created with the default `GITHUB_TOKEN` do not trigger downstream workflows. `release.yml` uses the short-lived `GITHUB_TOKEN` installation token instead. |
| `ANDROID_KEYSTORE_BASE64` | `base64` of the CI **upload** keystore (`~/.keystores/my-key.keystore` on this machine). |
| `KEY_ALIAS`             | Alias of the upload key inside the keystore (`my-key-alias`).           |
| `KEY_PASSWORD`          | Password for the upload key.                                            |
| `STORE_PASSWORD`        | Password for the keystore file itself.                                  |
| `PLAY_SUPPLY_JSON_KEY`  | Contents of the Play Console service-account JSON (`release-please-supply-key.json`). |

### Seeding Secrets via `gh secret set`

If you are using the same shared upload keystore and Google Play service account as `Shir0o/bnpb`, you can seed the secrets into `Shir0o/tempo`:

```bash
# 1. Upload Keystore
base64 -i ~/.keystores/my-key.keystore | tr -d '\n' | \
  gh secret set ANDROID_KEYSTORE_BASE64 --repo Shir0o/tempo

# 2. Keystore Credentials (replace with your actual alias/passwords if different)
gh secret set KEY_ALIAS --repo Shir0o/tempo --body "my-key-alias"
gh secret set KEY_PASSWORD --repo Shir0o/tempo --body "<your-key-password>"
gh secret set STORE_PASSWORD --repo Shir0o/tempo --body "<your-store-password>"

# 3. Google Play Supply Key
gh secret set PLAY_SUPPLY_JSON_KEY --repo Shir0o/tempo < ~/release-please-supply-key.json

# 4. Release Please Token (PAT)
gh secret set RELEASE_PLEASE_TOKEN --repo Shir0o/tempo --body "<your-release-please-pat>"
```

### Play Console Configuration

1. In **Google Play Console**, ensure the app `com.tempos.tracker` exists.
2. In **Play Console → Settings → API access**, link the service account named in `release-please-supply-key.json` and ensure it has **Release Manager** permissions (account-wide or specifically for `com.tempos.tracker`).
3. Ensure **Play App Signing** is active so Google accepts the upload key signature and re-signs for end users.

## Security hardening

- **Tags are data.** The tag reaches workflow steps through the `TAG`
  environment variable and is never interpolated into a shell body. The pure
  `deriveVersionCode` function in `lib/core/version_code.dart` rejects any
  tag that is not `v?MAJOR.MINOR.PATCH` (with an optional pre-release suffix)
  before the Android build number is derived.
- **Approval gate.** The `production` environment must require at least one
  reviewer, so a release waits for a human before the Play Console service
  account is mounted.
- **Immutable actions.** Every `uses:` in `.github/workflows` is pinned to a
  full commit SHA with a human-readable version comment. Dependabot's
  `github-actions` ecosystem keeps those pins current
  (`.github/dependabot.yml`).
- **Credential cleanup.** Every file written from a secret is removed by the
  `Remove mounted credentials` step, which runs under `if: always()` so a failed
  release cannot leave a keystore or service-account JSON in the workspace.
- **No artifact uploads.** No workflow uploads the working tree; artifact paths,
  if they are ever introduced, must be enumerated explicitly.

## Pre-release tags

A tag matching `*-rc*` or `*-beta*` (e.g. `v1.0.0-rc1`) builds APK + AAB and attaches them to a GitHub pre-release, but **skips** the Play Console upload.

## Local equivalent (manual escape hatch)

To create a release build locally:

```bash
# Android
flutter build appbundle --release
flutter build apk --release

# macOS
flutter build macos --release
```
