# ci-templates

Reusable GitHub Actions workflows and composite actions for my apps — Flutter and native Kotlin, Android and desktop. One repo holds all the CI logic; every app repo keeps a thin ~5-line workflow that calls into it.

## Layout

```
ci-templates/
├── .github/workflows/
│   ├── app-flutter.yml          # reusable: Flutter apps (android/linux/windows/macos)
│   └── app-android.yml          # reusable: native Kotlin/Java Android apps (Gradle)
└── actions/
    ├── setup-flutter/           # Flutter toolchain with caching (+ JDK for Android)
    ├── prepare-flutter/         # pub get, .env, prebuild hook, build_runner
    ├── sign-android/            # sign built APKs/AABs with the release key (release job only)
    └── publish-release/         # create the tag's GitHub Release or add files to it
```

## Naming

- **Reusable workflows:** `<kind>-<project-type>.yml`
  - kind = what sort of repo calls it: `app` (more later, e.g. `lib` for packages, `repo` for housekeeping)
  - project-type = what the caller would call their project: `flutter`, `android` (native Gradle), …
  - One workflow per project type. The platforms it builds for are an input, not part of the name.
  - The workflow's `name:` reads the same way: `Flutter app`, `Android app`.
- **Workflow inputs:** an input that only one platform's build uses starts with that platform (`android_build_args`). Inputs without a prefix apply to every platform.
- **Composite actions:** `actions/<verb>-<noun>/` (`setup-flutter`, `sign-android`, `publish-release`). Verbs for actions and nouns for workflows keep the two easy to tell apart.

## Workflows

| Workflow | For | Does |
|---|---|---|
| `app-flutter.yml` | Flutter apps | analyze + test once; builds each platform in `platforms` (APK, linux tar.gz, windows/macos zip); on `v*` tags, signs the APKs and publishes one GitHub Release with every build, only if everything passed |
| `app-android.yml` | Native Kotlin Android | runs a Gradle task (default `assembleRelease`), collects APK/AAB; on `v*` tags, signs them and publishes a release |

## Quick start

### Flutter app

`.github/workflows/ci.yml` in the app repo:

```yaml
name: CI
on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:

jobs:
  flutter:
    permissions:
      contents: write  # for the release job; see "Releases need write permission"
    uses: johan456789/ci-templates/.github/workflows/app-flutter.yml@v1
    secrets:
      DOTENV: ${{ secrets.DOTENV }}  # only if the app uses a .env; drop otherwise
```

Pass only the secrets the workflow needs rather than `secrets: inherit`. The signing secrets aren't passed at all: they live in the `release` environment (see [Android signing](#android-signing)).

Useful inputs:

```yaml
    with:
      platforms: '["android", "linux", "windows"]'  # default '["android"]'; "macos" also available
      lfs: true                 # fetch Git LFS files (fonts/assets) on checkout
      analyze_args: --no-fatal-infos            # extra flags for `flutter analyze`
      check_tag_version: false  # skip the v* tag == pubspec.yaml version check (default true)
      publish_release: true     # attach builds to release on v* tags (default true)
      flutter_version: '3.24.0' # pin if needed
      android_abi_splits: true  # one APK per CPU architecture instead of universal
      android_build_args: --dart-define-from-file=.env  # extra flags for `flutter build apk`
```

Inputs that only affect one platform's build start with that platform (`android_*`).

### Native Kotlin Android app

```yaml
jobs:
  android:
    permissions:
      contents: write
    uses: johan456789/ci-templates/.github/workflows/app-android.yml@v1
    with:
      gradle_task: assembleRelease
```

No `secrets:` needed: the signing secrets come from the `release` environment.

Repos that aren't build-ready after checkout (e.g. a gitignored native
library compiled by a repo script) can hook in setup without forking the
template:

```yaml
    with:
      prebuild_script: mkdir -p app/libs && ./build_ffmpegkit.sh  # what to run after checkout
      prebuild_cache_path: app/libs                               # what it produces
      prebuild_cache_key: ffmpeg-aar                              # cache namespace
      prebuild_cache_hash_files: build_ffmpegkit.sh               # auto-invalidate when this changes
```

The script runs in the *caller's* checkout, so `./` paths resolve to the app
repo. `prebuild_cache_hash_files` is hashed post-checkout (a caller-side
`hashFiles()` in `with:` would evaluate before checkout and always miss).
All four default to empty = hook skipped, so existing callers are unaffected.

### All inputs

Each workflow declares every input with its default and a description at the top of the file. That is the reference:

- [`app-flutter.yml`](.github/workflows/app-flutter.yml)
- [`app-android.yml`](.github/workflows/app-android.yml)

## Android signing

The signing key never reaches a job that builds the app. Build jobs run project code, Gradle plugins, `build_runner`, the prebuild script and every dependency, so they produce unsigned or debug-signed APKs. Only the `release` job, which runs on `v*` tags and runs no project code, gets the key: it downloads the builds, signs them with `apksigner` (APKs) or `jarsigner` (AABs), and publishes.

### Set up the `release` environment (each app repo)

1. **Settings → Environments → New environment**, name it `release`.
2. **Deployment branches and tags → Selected branches and tags → Add rule**, type **Tag**, pattern `v*`.
3. Add the signing secrets as **environment secrets**:

   | Secret | Description |
   |---|---|
   | `ANDROID_KEYSTORE_BASE64` | base64-encoded `.jks` keystore |
   | `ANDROID_KEYSTORE_PASSWORD` | keystore password |
   | `ANDROID_KEY_ALIAS` | key alias |
   | `ANDROID_KEY_PASSWORD` | key password — **optional**; defaults to `ANDROID_KEYSTORE_PASSWORD` (correct for PKCS12 keystores, which is `keytool`'s default) |

4. Delete any repo-level copies of those secrets (**Settings → Secrets and variables → Actions**).
5. Optional: a tag ruleset (**Settings → Rules → Rulesets**, target `v*` tags, restrict creations) so only you can create `v*` tags.

GitHub then hands those secrets only to jobs that declare `environment: release` **and** run on a `v*` tag. GitHub enforces that, not the workflow YAML, so someone who can push a branch can't add a workflow that prints them. Repo-level secrets offer no such protection.

Release builds fail if the signing secrets are missing, so an unsigned or debug-signed APK is never published. PR and `main` builds never sign and are just compile checks.

Create a keystore and the base64 secret:

```bash
just jks-gen   # writes release-keystore.jks (alias: release), prints the base64 for ANDROID_KEYSTORE_BASE64
```

Set `ANDROID_KEY_ALIAS` to the alias you generated with (`release` by default). Override with `just jks-gen file=my.jks alias=myalias`.

### No Gradle signing wiring

Apps don't need a `key.properties` signing config any more; remove it if you added one. Leave release builds on Flutter's default (`signingConfig = signingConfigs.getByName("debug")`) or, for native apps, with no signing config (Gradle writes `app-release-unsigned.apk`; the `-unsigned` suffix is dropped when signed). `apksigner` replaces the debug signature.

### Other guards

- The workflows fail immediately when called from `pull_request_target`, which runs with the repo's secrets and is how outsider PR code usually gets hold of them. Use `pull_request`; GitHub already withholds secrets from fork and Dependabot PRs.
- `DOTENV` is a **repo secret**, not a `release` environment secret, because every build (PRs and `main` too) needs it. It's stored as a secret to keep it out of git, but its values are compiled into the APK and can be extracted, so don't put real secrets in it.

### Releases need write permission

The release job creates GitHub Releases with `GITHUB_TOKEN`, so it needs `contents: write`. A called workflow can't get more than its caller grants, so grant it on the calling job instead of switching the whole repo to **Read and write** in Settings:

```yaml
jobs:
  flutter:
    permissions:
      contents: write
    uses: johan456789/ci-templates/.github/workflows/app-flutter.yml@v1
```

Without it, a repo whose default token is read-only fails at startup (`startup_failure`): the called workflow asks for more than the caller grants. Callers with `publish_release: false` can grant `contents: read` instead.

Only the release job uses the write grant. The workflows set `contents: read` for every other job, since those run project code and dependencies.

## Releases & Obtainium

Releases are created automatically when you push a tag:

```bash
git tag v1.2.3 && git push origin v1.2.3
```

- The tag becomes the release name; notes are auto-generated.
- Flutter apps: the APK version comes from `pubspec.yaml`, and the build fails if the tag doesn't match it (`v1.2.3` needs `version: 1.2.3+N`). Bump `pubspec.yaml`, including `+N`, before tagging.
- Built APKs are attached as release assets — point Obtainium at the repo's GitHub Releases and it picks up updates.
- Obtainium installs **APKs only** (not AABs) — use `app-flutter.yml` or `assembleRelease`, not `bundleRelease`.
- Private repos work in Obtainium since v0.14.11-beta but require each user to supply a PAT with read access.

## Versioning these templates

Callers pin `@v1`. To ship template changes:

1. Merge to `main`
2. Bump the tag (`git tag v2 && git push origin v2`) for breaking changes
3. Update callers to `@v2` on their own schedule

Never reference `@main` from app repos unless you want live-on-main changes everywhere.

## Notes

- All workflows run on `ubuntu-latest` by default — free for public repos (~300–500 Android builds/month within typical free quotas).
- macOS desktop runners cost ~10x per-minute vs Linux; keep `"macos"` out of `platforms` unless needed.
- The workflows call this repo's actions by full path (`johan456789/ci-templates/actions/<name>@main`), not `./actions/...`: inside a reusable workflow, `./` resolves against the *caller's* checkout. So a caller pinned to `@v1` still runs the actions from `main`; pin those refs too when cutting a tag.
