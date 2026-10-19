# MOpus Studio — Build & Release Guide

Open-source, ultra-lightweight Flutter video editor tuned for **2GB-RAM Android
devices**. This document covers everything needed to go from a clean checkout to
a signed, split-per-ABI release APK.

**Brand reference**

| Token | Hex | Use |
| --- | --- | --- |
| Jet Black | `#050505` | App background, icon background, canvas base |
| Electric Orange | `#FF6B00` | Accents, CTA buttons, "MO" emblem, shape default |
| Pure White | `#FFFFFF` | Text, "pus" emblem, text layers in exports |

**Module status**

| Module | Content | State |
| --- | --- | --- |
| 1 | Core UI, multi-track timeline, layer architecture | ✅ shipped |
| 2 | Keyframes, transform matrices, motion blur, playback | ✅ shipped |
| 3 | Offline render engine (FFmpeg graph), effects library, AI staging | ✅ this module |
| 3.5 | Android FFmpeg native backend (`RenderBackend`) | staged |
| 4 | Media pipeline (import/probe), text module, project I/O | planned |

---

## 1. Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| Flutter | 3.19+ (stable) | `flutter --version` |
| Dart | 3.3+ | bundled with Flutter |
| JDK | 17 | required by AGP 8 / Gradle 8 |
| Android SDK | Platform 34, Build-Tools 34.0.0 | `sdkmanager "platforms;android-34" "build-tools;34.0.0"` |
| FFmpeg (desktop/CI only) | **4.4+** (5.x/6.x recommended) | export runs on device *or* renders a script for desktop |

Verify the toolchain:

```powershell
flutter doctor -v
```

> **Check your FFmpeg build before trusting it.** Run `ffmpeg -version` and look
> at the first line. If it does not start with `ffmpeg version 4.4` or newer
> (nightlies print `ffmpeg version N-55702-...`), it cannot run the render graph:
> `force_divisible_by`, `amix=normalize`, `overlay=eof_action`,
> `-filter_complex_threads` and `-progress pipe:1` are all 4.4+/newer features.
> Old builds often hide inside tool folders — e.g. a 2013 build shipped in
> `...\Python3xx\Scripts\ffmpeg.exe` — so fix `PATH` or install a current build:
>
> ```powershell
> winget install Gyan.FFmpeg        # or https://www.gyan.dev/ffmpeg/builds/
> ```
>
> The app itself does not care: `FfmpegRenderer.probe()` reports the exact reason
> (`Unrecognized FFmpeg version line...` / `FFmpeg 2.0 is older than 4.4 ...`)
> and `isAvailable()` simply returns `false`, so editing stays fully usable and
> the UI can show an install hint instead of failing mid-export.

> The project ships **zero third-party runtime packages** — `flutter pub get`
> works fully offline once the Flutter SDK is cached.

---

## 2. First-time Android scaffolding

The repository contains `lib/`, `test/`, `pubspec.yaml`, the Android manifest and
the docs. Generate the remaining platform folders **once** (this never touches
`lib/`):

```powershell
cd "C:\Users\USER\OneDrive\Desktop\MOpus STUDIO"
flutter create --org com.mopus --project-name mopus_studio --platforms=android .
```

Then apply the package + memory settings. Open **`android/app/build.gradle`** and
make the `android { ... }` block match:

```gradle
android {
    namespace "com.mopus.studio"          // resolves ".MainActivity" in the manifest
    compileSdkVersion 34

    defaultConfig {
        applicationId "com.mopus.studio"   // Play Store identity: com.mopus.studio
        minSdkVersion 24                   // Android 7.0 — 2GB-device floor
        targetSdkVersion 34
        versionCode flutterVersionCode.toInteger()
        versionName flutterVersionName

        // Ship only real device ABIs; x86_64 stays for emulators.
        ndk {
            abiFilters "armeabi-v7a", "arm64-v8a", "x86_64"
        }
    }

    buildTypes {
        release {
            // Replace with a release keystore before publishing (section 6).
            signingConfig signingConfigs.debug
            minifyEnabled true
            shrinkResources true
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'),
                          'proguard-rules.pro'
        }
    }
}
```

`android/app/proguard-rules.pro` must exist when `minifyEnabled` is on:

```powershell
New-Item -ItemType File android\app\proguard-rules.pro -Force
```

Open **`android/gradle.properties`** and keep the JVM heap small (a 2GB machine
cannot feed Gradle 4 GB and still run an emulator):

```properties
org.gradle.jvmargs=-Xmx1536M -XX:MaxMetaspaceSize=512m
android.useAndroidX=true
android.enableJetifier=true
```

**Manifest**: this repo already contains the final
`android/app/src/main/AndroidManifest.xml` (permissions, `largeHeap`,
OpenGL ES 2.0 feature, share intent filters, label `MOpus Studio`). If
`flutter create` generated its own version, replace it with the one in this
repo — do not merge by hand.

Regenerate the Gradle wrapper files after editing:

```powershell
flutter clean
flutter pub get
```

---

## 3. Verify the code before building

```powershell
flutter pub get          # resolve (no external runtime deps)
flutter test             # 28+ engine/controller tests must pass
flutter analyze          # must report "No issues found!"
```

The engine tests cover Module 1 (timeline controller) and Module 2 (interpolation,
matrices, adjustment aggregation, motion blur, playback). Add
`test/render_engine_test.dart` results to any bug report — it validates the
FFmpeg graph without spawning a process.

---

## 4. Build the release APK

### 4.1 Full split-per-ABI build (recommended for distribution)

```powershell
flutter build apk --release --split-per-abi
```

Outputs (upload all three, or only the arm64 one if size-limited):

```
build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk
build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
build\app\outputs\flutter-apk\app-x86_64-release.apk
```

### 4.2 Low-memory build machine / 2GB target tuning

```powershell
# Build only the two device ABIs, skip R8 shrinking, cap Gradle's heap:
flutter build apk --release --split-per-abi `
  --target-platform android-arm,android-arm64 `
  --no-shrink
```

* `--target-platform android-arm,android-arm64` — skips x86_64 (emulators only).
* `--no-shrink` — R8 is the most memory-hungry build step; skipping it costs a
  few MB of APK size and saves ~1 GB of build RAM.
* Keep `org.gradle.jvmargs=-Xmx1536M` from section 2.
* Pass release-time configuration without editing code:

```powershell
flutter build apk --release --split-per-abi `
  --dart-define=MOPUS_AI_ENDPOINT=https://api.example.com `
  --dart-define=MOPUS_AI_API_KEY=sk-... `
  --dart-define=MOPUS_ALLOW_NETWORK_AI=false
```

`MOPUS_ALLOW_NETWORK_AI=false` is the default: AI providers stay dark until the
user opts in, so an APK built now behaves exactly like an offline editor.

### 4.3 Install and smoke-test on the device

```powershell
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
adb shell am start -n com.mopus.studio/.MainActivity
```

Runtime checklist for 2GB devices:

1. Timeline scrub stays at 60 fps (Module 2 playback controller).
2. Export uses `ExportSettings.lowRam720p30` (720p30, CRF 23, 2 encoder
   threads, 1 filter thread, proxy cache on).
3. Long exports keep the screen awake (`WAKE_LOCK`) and survive backgrounding
   (`FOREGROUND_SERVICE_DATA_SYNC`).

---

## 5. How the render pipeline runs

| Environment | Path |
| --- | --- |
| Desktop / CI | `FfmpegRenderer().render(plan)` spawns the system `ffmpeg` |
| Script export | `FfmpegRenderer(keepScript: true)` writes `<output>.mp4.sh` |
| Android (staged) | `AndroidFfmpegBackend implements RenderBackend`, feeding the **same** `FfmpegRenderJob.arguments` to a bundled FFmpeg exec/JNI bridge |

Because `ExportEngine.plan()` and `FfmpegRenderer.buildJob()` are pure Dart, the
exact same graph that ships on Android can be reproduced on a workstation:

```powershell
# 1. In a debug build (or a test), call buildJob() and dump the script:
#    final job = FfmpegRenderer().buildJob(plan);
#    File('render.sh').writeAsStringSync(job.toShellScript());
# 2. Run it anywhere FFmpeg 4.4+ exists (Git Bash, WSL, Linux, macOS):
sh render.sh
```

Graph facts worth knowing while debugging:

* Canvas defaults to Jet Black `#050505` at the export resolution.
* Positions are canvas-centre relative: `overlay x = (main_w - overlay_w)/2 + x(t)`.
* Animated position/rotation become per-frame `overlay`/`rotate` expressions;
  animated opacity/scale are baked as constant `trim`+`concat` slices, and a
  linear 0↔1 fade stays a single smooth `fade` slice.
* Adjustment layers apply to every visual layer **below** them (Module 2
  semantics), compiled through `EffectsLibrary`.
* Audio is `adelay` + `amix` with `normalize=0`, AAC 192 kbit/s, 48 kHz stereo.

---

## 6. Release signing (before any store upload)

```powershell
keytool -genkey -v -keystore "$env:USERPROFILE\mopus-release.jks" `
  -keyalg RSA -keysize 2048 -validity 10000 -alias mopus
```

Create `android/key.properties` (never commit it):

```properties
storePassword=********
keyPassword=********
keyAlias=mopus
storeFile=C:/Users/USER/mopus-release.jks
```

Load it in `android/app/build.gradle` **above** `android { ... }`:

```gradle
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile file(keystoreProperties['storeFile'])
            storePassword keystoreProperties['storePassword']
        }
    }
    buildTypes {
        release { signingConfig signingConfigs.release }
    }
}
```

---

## 7. Launcher icon (MOpus Studio branding)

1. Create the master artwork:
   `assets/branding/icon_1024.png` — 1024×1024, Jet Black `#050505` background,
   Electric Orange `#FF6B00` **"MO"** + Pure White `#FFFFFF` **"pus"** emblem.
   Optionally `assets/branding/icon_foreground_1024.png` with ~15% safe padding
   for Android's adaptive icon mask.
2. In `pubspec.yaml`, uncomment the `assets:` block **and** the
   `flutter_launcher_icons` block (dev dependency included). A listed asset that
   does not exist fails the build — create the files first.
3. Generate the mipmaps:

```powershell
flutter pub get
dart run flutter_launcher_icons:main
```

4. The manifest already points at `@mipmap/ic_launcher`, and the generator
   writes the adaptive background colour `#050505` plus the orange/white
   foreground layer, so no manifest edit is needed.

---

## 8. Troubleshooting

| Symptom | Fix |
| --- | --- |
| `unable to find directory entry in pubspec.yaml: assets/...` | The asset file/dir does not exist; create it or re-comment the block. |
| `Could not resolve com.mopus.studio` / `.MainActivity` not found | `namespace` in `build.gradle` must be `com.mopus.studio`. |
| Gradle OOM during `:app:minifyReleaseWithR8` | Use `--no-shrink`, lower `org.gradle.jvmargs`, close the emulator. |
| `Execution failed for task ':app:processReleaseManifest'` | Two manifests merged (template + repo). Keep only `android/app/src/main/AndroidManifest.xml`. |
| Export fails with `Unknown filter` / `Unrecognized option 'hide_banner'` | The FFmpeg on PATH is pre-4.4 (old builds reject `-hide_banner` too). Install a current build and re-run `ffmpeg -version`. |
| `isAvailable()` returns `false` although ffmpeg runs | Read the `probe()` message: it names the version line it found and the required `4.4`. |
| `Module not found: flutter_lints` while offline | `flutter pub get` needs the pub cache; lints are dev-only and never ship. |
| Animation looks stepped when exporting a zoom | Raise `ExportSettings.bakeSubdivisions` (8–12) — animated scale is baked as slices by design. |

---

## 9. Quick reference

```powershell
flutter create --org com.mopus --project-name mopus_studio --platforms=android .
flutter clean
flutter pub get
flutter test
flutter analyze
flutter build apk --release --split-per-abi
flutter build appbundle --release          # Play Store AAB
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```
