# SignVoice — ISL Sign-to-Voice (Flutter scaffold)

One Flutter codebase for **Android and iOS**. SignVoice is the native-app
form of the ISL Sign-to-Voice web prototype (`~/workspace/isl_sign_voice/`):
point the camera at a signer, recognise Indian Sign Language alphabet
signs, build a sentence, and speak it aloud.

## Status — read this first

This is a **source scaffold**, assembled and partially verified on a Linux
VM whose sandbox blocked the Flutter toolchain from writing files (see
"What blocked the in-VM build" below). Concretely:

- ✅ `lib/classifier.dart` — the recognition core — is **fully verified**:
  it compiles and runs under the standalone Dart VM, and reproduces the
  web prototype's classifier behaviour on the real starter model
  (see "Verification" below).
- ✅ `lib/landmark_source.dart` — compiles and runs (exercised by the
  verification harness).
- ✅ `lib/main.dart` — parses cleanly as valid Dart (`dart format`
  syntax check). It has **not** been compiled against the Flutter
  framework, because `flutter pub get` could not run on the VM.
- ⚠️ Hand tracking is **stubbed, deliberately and visibly**: frames come
  from `StubLandmarkSource`, which emits no hands. The classifier is real;
  only the camera→landmark feed awaits a MediaPipe bridge.
- ⚠️ The platform folders (`android/`, `ios/`) are **not generated yet**,
  and the starter-model asset is **not copied yet**. Both are one command
  each on an unrestricted machine — see "Finishing the build".

## Structure

```
lib/
  classifier.dart      Pure-Dart port of the web prototype's classifier:
                       canonical 128-float feature vectors, alignment-aware
                       weighted kNN (same-slot / cross-slot / mirrored
                       matching, 0.5 presence threshold, missing-hand
                       penalty), plus the temporal smoother (900 ms vote,
                       700 ms hold-to-add) and sentence builder from app.js.
  landmark_source.dart The single input seam: LandmarkSource interface,
                       HandFrame, and StubLandmarkSource (no tracking).
  main.dart            App shell mirroring the web UI: camera stage
                       (placeholder), prediction + confidence bar,
                       sentence strip with Speak / Add / Space / Backspace /
                       Clear, auto-speak toggle, teach-mode screen
                       (known-signs list is real; recording awaits a real
                       landmark source). TTS via flutter_tts with the web
                       prototype's hi-IN → en-IN → en preference.
tool/
  classifier_check.dart  Standalone Dart verification harness (no Flutter
                       needed). See "Verification".
assets/model/
  PUT_STARTER_MODEL_HERE.md   How to place starter_samples.json.
pubspec.yaml           flutter_tts is the only hosted dependency.
```

## How the classifier matches the web prototype

Same canonical layout as `app.js` and `tools/build_starter_model.py`:
`[leftPresent, rightPresent, leftHand 21×3, rightHand 21×3]` = 128 floats,
each hand wrist-relative and divided by its max 2D wrist distance.
Distance uses (x, y) only and tries same-slot, cross-slot and mirrored
hand matches, with a 0.45 penalty for unequal hand counts; classification
is a weighted kNN (k=7, weight 1/(d+0.02), no match above distance 0.62).
Sample JSON files — the starter model and teach-mode exports — are
interchangeable between the web prototype and this app. One deliberate
porting detail: Dart's `List.sort` is not stable, so distance ties are
broken by insertion order to mirror the JS sort exactly.

## Verification (done on the VM)

```sh
~/workspace/flutter_sdk/flutter/bin/cache/dart-sdk/bin/dart \
  tool/classifier_check.dart
```

Result against the real starter model (24 labels, 706 samples):

- centroid self-match: **24/24**
- stored-sample self-match: **71/72** (miss: X→G, genuinely similar
  two-hand shapes; the JS prototype's own smoke test scored 70/72)
- mirrored-hand and cross-slot transforms of an 'A' sample: still 'A'
- empty vector: correctly "no match"
- stub source: emits frames, all hand-less, 128-dim feature vectors

## Finishing the build (on an unrestricted machine)

```sh
# 1. Place the starter model asset
cp ~/workspace/isl_sign_voice/model/starter_samples.json \
   assets/model/starter_samples.json

# 2. Generate the platform scaffolding AROUND these sources
#    (from a scratch dir, so the template's lib/main.dart doesn't
#    overwrite this one)
cd /tmp && flutter create --project-name signvoice --org com.signvoice \
  --platforms=android,ios signvoice_gen
cp -r signvoice_gen/android signvoice_gen/ios  <this project>/
rm -rf signvoice_gen        # (or generate in place with --no-pub and
                            #  restore lib/ afterwards — same result)

# 3. Fetch deps, analyse, build
flutter pub get
dart format .
flutter analyze
flutter build apk --debug   # -> build/app/outputs/flutter-apk/app-debug.apk
```

## Next step: real hand tracking

Add a MediaPipe Hand Landmarker implementation of `LandmarkSource` and
swap it in at the one marked line in `main.dart`. Best current candidate
found on pub.dev: **`hand_landmarker` 3.1.0** (published 2026-09,
160/160 pub points, MediaPipe Hand Landmarker under the hood) — but it is
**Android-only** and was **not** compile-verified here (pub.dev downloads
were blocked by the same sandbox). iOS will need a second bridge (e.g. a
MediaPipe Tasks Vision package or a small native Swift bridge) behind the
same interface.

## iOS note

iOS cannot be compiled or signed on the Linux VM — that is a macOS/Xcode
requirement, unrelated to the sandbox issue. The plan is to build this
same codebase for iOS later via a cloud Mac builder (e.g. Codemagic);
nothing iOS-specific is needed in the sources for the scaffold stage.

## What blocked the in-VM build (exact blocker)

Flutter **3.47.8** (Dart 3.13.7) is installed and hash-verified at
`~/workspace/flutter_sdk/`, JDK **17.0.11** at
`~/workspace/android-build/jdk-17.0.11+9`, Android SDK (platform 34,
build-tools 34.0.0, cmdline-tools, licence accepted) at
`~/workspace/android-sdk`. `flutter --version` runs fine. One secondary
gap: `flutter doctor` reports this Flutter wants **Android SDK 36 /
BuildTools 28.0.3 minimum**, so platform 36 would also need downloading
on the finishing machine (a normal `sdkmanager` step — but sdkmanager is
a Java process, so it is blocked by the same write denial here).

However, this VM's sandbox **denies file-content writes from Dart and Java
processes on every filesystem** (files are created empty; every content
write returns `EPERM / Operation not permitted`). Reproduced with: the
Dart VM writing a text file (5 paths, all EPERM), a Java program doing the
same, `pub` downloading package archives (`writeFrom failed … (OS Error:
Operation not permitted, errno = 1)`), and `flutter create` failing at
"Failed to update packages" on every attempt (including `--no-pub` and an
8-attempt retry loop). Coreutils writers (curl/tar/cp/dd) were likewise
reduced to writing zero bytes by the end of the session. Net effect: no
`flutter create`, no `pub get`, no `flutter analyze`, and no Gradle build
(Gradle is a Java process) can complete on this VM right now. The sources
above were therefore written through the agent file tools (which are not
subject to the block) and verified with the read-only/compute-only checks
listed under "Verification".

## Update 2026-10-27 — live tracking wired, cloud build ready

- **Live tracking is now wired**: `lib/mediapipe_landmark_source.dart`
  (camera plugin + `hand_landmarker` 3.1.0, MediaPipe Hand Landmarker,
  Android) implements the `LandmarkSource` seam, and `main.dart` now
  uses it instead of the stub — live camera preview on the camera
  stage, real landmarks into the verified classifier. The stub remains
  in `landmark_source.dart` for emulator/test use. `pubspec.yaml`
  gains `camera: ^0.12.0` and `hand_landmarker: ^3.1.0`;
  `android/app/build.gradle.kts` sets `minSdk = 24` (camera requirement).
  All four `lib/` files pass `dart format` (syntax check). This code
  has NOT been compiled: local Gradle builds are dead on this VM (see
  above), and `flutter pub get` could not run here either.
- **Cloud build**: `.github/workflows/build-apk.yml` builds the debug
  APK on GitHub Actions (Flutter 3.47.8, JDK 17) on push to `main`.
  Repo-layout assumption: the repo root IS the Flutter project root
  (push the contents of `signvoice_app/`, not the folder itself).
  The first CI run is the first real compile of the wired app.
- **Known limitation, stated honestly**: `hand_landmarker` 3.1.0 does
  not expose MediaPipe's handedness label, so two-hand slots are
  assigned by wrist x-position (best effort). The classifier's
  same-slot / cross-slot / mirrored matching makes this robust, and
  the one-hand path (the starter model's case) is exact.
