# ci-templates

Reusable GitHub Actions workflows and composite actions for my apps — Flutter and native Kotlin, Android and desktop. One private repo holds all the CI logic; every app repo keeps a thin ~5-line workflow that calls into it.

## Layout

```
ci-templates/
├── .github/workflows/
│   ├── flutter-app.yml          # reusable: analyze + test + build APK + release
│   ├── android-gradle-app.yml   # reusable: native Kotlin/Java Android apps
│   └── desktop-app.yml          # reusable: Flutter desktop (linux/windows/macos matrix)
└── actions/
    ├── setup-flutter/           # JDK + Flutter toolchain with caching
    └── sign-android/            # decode keystore + write key.properties
```

## Workflows

| Workflow | For | Does |
|---|---|---|
| `flutter-app.yml` | Flutter mobile | analyze + test on every call; builds release APK; attaches APKs to a GitHub Release on `v*` tags |
| `android-gradle-app.yml` | Native Kotlin Android | runs a Gradle task (default `assembleRelease`), collects APK/AAB, publishes releases on `v*` tags |
| `desktop-app.yml` | Flutter desktop | matrix over `linux` / `windows` / `macos`, zips each bundle, publishes releases on `v*` tags |

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
    uses: johan456789/ci-templates/.github/workflows/flutter-app.yml@v1
    secrets: inherit
```

Useful inputs:

```yaml
    with:
      abi_splits: true          # split-per-ABI APKs instead of universal
      publish_release: true     # attach APKs to release on v* tags (default true)
      flutter_version: '3.24.0' # pin if needed
```

### Native Kotlin Android app

```yaml
jobs:
  android:
    uses: johan456789/ci-templates/.github/workflows/android-gradle-app.yml@v1
    with:
      gradle_task: assembleRelease
    secrets: inherit
```

### Flutter desktop app

```yaml
jobs:
  desktop:
    uses: johan456789/ci-templates/.github/workflows/desktop-app.yml@v1
    with:
      platforms_json: '["linux", "windows"]'   # add "macos" if desired
```

### All inputs (defaults in parentheses)

| Input | Workflow | Values |
|---|---|---|
| `flutter_version` (`''`) | flutter-app, desktop-app | pinned Flutter version, empty = latest stable |
| `java_version` (`17`) | all | Temurin JDK version |
| `run_analyze` / `run_test` (`true`) | flutter-app | toggle analyze/test steps |
| `abi_splits` (`false`) | flutter-app | split-per-ABI APKs instead of universal |
| `gradle_task` (`assembleRelease`) | android-gradle-app | any Gradle task(s) |
| `project_dir` (`.`) | android-gradle-app | dir containing `gradlew` |
| `properties_file` (`key.properties`) | android-gradle-app | where key.properties is written |
| `platforms_json` (`'["linux"]'`) | desktop-app | JSON array subset of linux/windows/macos |
| `publish_release` (`true`) | all | attach artifacts to a GitHub Release on `v*` tags |

> Until this repo has a `v1` tag, callers must reference `@main` instead of `@v1`.

## Android signing

The workflows sign automatically when these **repo secrets** exist in the app repo (pass them via `secrets: inherit`):

| Secret | Description |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | base64-encoded `.jks` keystore |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias |
| `ANDROID_KEY_PASSWORD` | key password |

Signing is **all-or-nothing**: if *any* of the four secrets is set, all four are required — a partial config fails the build with an error naming exactly which secret is missing. With none set, builds still succeed but produce an APK signed with the debug key (Flutter) or left unsigned (native Gradle projects without signing wiring) — fine for CI checks, but **not** shippable to Obtainium.

Create a keystore and the base64 secret:

```bash
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
base64 -w0 upload-keystore.jks   # paste output into ANDROID_KEYSTORE_BASE64
```

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
- Built APKs are attached as release assets — point Obtainium at the repo's GitHub Releases and it picks up updates.
- Obtainium installs **APKs only** (not AABs) — use `flutter-app.yml` or `assembleRelease`, not `bundleRelease`.
- Private repos work in Obtainium since v0.14.11-beta but require each user to supply a PAT with read access.

## Versioning these templates

Callers pin `@v1`. To ship template changes:

1. Merge to `main`
2. Bump the tag (`git tag v2 && git push origin v2`) for breaking changes
3. Update callers to `@v2` on their own schedule

Never reference `@main` from app repos unless you want live-on-main changes everywhere.

## Notes

- All workflows run on `ubuntu-latest` by default — free within GitHub's 2,000 min/month private-repo quota (~300–500 Android builds/month).
- macOS desktop runners bill at 10x on private repos; keep `"macos"` out of `platforms_json` unless needed.
- Reusable workflows referenced here resolve local actions (`./actions/...`) against **this** repo at the pinned ref — no cross-repo action config needed.
