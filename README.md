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
    ├── sign-android/            # decode keystore + write key.properties (skips if no secrets)
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
| `app-flutter.yml` | Flutter apps | analyze + test once; builds each platform in `platforms` (APK, linux tar.gz, windows/macos zip); one GitHub Release with every build on `v*` tags, only if everything passed |
| `app-android.yml` | Native Kotlin Android | runs a Gradle task (default `assembleRelease`), collects APK/AAB, publishes releases on `v*` tags |

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
    uses: johan456789/ci-templates/.github/workflows/app-flutter.yml@v1
    secrets: inherit
```

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
    uses: johan456789/ci-templates/.github/workflows/app-android.yml@v1
    with:
      gradle_task: assembleRelease
    secrets: inherit
```

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

The workflows sign automatically when these **repo secrets** exist in the app repo (pass them via `secrets: inherit`):

| Secret | Description |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | base64-encoded `.jks` keystore |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias |
| `ANDROID_KEY_PASSWORD` | key password — **optional**; defaults to `ANDROID_KEYSTORE_PASSWORD` (correct for PKCS12 keystores, which is `keytool`'s default) |

Signing is **all-or-nothing**: if *any* signing secret is set, the keystore, keystore password, and key alias are required (the key password is optional and reuses the keystore password when omitted) — a partial config fails the build with an error naming exactly which secret is missing. With none set, builds still succeed but produce an APK signed with the debug key (Flutter) or left unsigned (native Gradle projects without signing wiring) — fine for CI checks, but **not** shippable to Obtainium.

Create a keystore and the base64 secret:

```bash
just jks-gen   # writes release-keystore.jks (alias: release), prints the base64 for ANDROID_KEYSTORE_BASE64
```

Set `ANDROID_KEY_ALIAS` to the alias you generated with (`release` by default). Override with `just jks-gen file=my.jks alias=myalias`.

### Releases need write permission

The release steps create GitHub Releases with `GITHUB_TOKEN`. If your repo or org defaults workflow tokens to read-only, allow **Settings → Actions → General → Workflow permissions → Read and write**, or the release job fails.

### Gradle wiring

`sign-android` writes `storeFile` as an absolute path plus the passwords into `key.properties` (next to your Gradle project). Your `android/app/build.gradle.kts` must read it:

```kotlin
import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
```

Recent Flutter templates ship most of this already — just make sure it's present.

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
