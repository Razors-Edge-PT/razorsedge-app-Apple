# Razor's Edge

Razor's Edge (RE) is the Goodlift Flutter app for workout logging and periodized
strength training. It targets iOS and Android, backed by Firebase and Cloud
Functions.

- **Firebase project**: `goodlift-us-storage`
- **Bundle ID**: `com.goodlift.razorsedge`
- **Flutter SDK**: >=3.4.4 <4.0.0

## Getting started

```bash
flutter pub get          # install dependencies
flutter run              # run in debug mode
flutter analyze          # lint check
flutter test             # run tests
```

Builds:

```bash
flutter build apk        # Android APK
flutter build appbundle  # Android AAB (Play)
flutter build ios        # iOS
```

## Cloud Functions

Run from the `functions/` directory (Node 22):

```bash
npm install
npm run serve            # Firebase emulator
npm run test             # unit tests
npm run test:rules       # Firestore/Storage rules tests (emulator)
npm run deploy           # deploy to Firebase
npm run logs             # view function logs
```

Stripe, Meta and other secrets are supplied as Cloud Functions secrets and
environment variables — never committed to this repository.

## Layout

| Path | Contents |
| --- | --- |
| `lib/` | Flutter app source |
| `lib/local_cache/` | Isar models and the offline autosave/sync queue |
| `functions/` | Cloud Functions (Stripe, RE Points, lookup indexes) |
| `test/` | Dart tests |
| `assets/` | Images, fonts and bundled data |
| `docs/` | Feature specs and working notes |
| `firestore.rules`, `storage.rules`, `firestore.indexes.json` | Deployed Firebase security rules and indexes |
| `.claude/skills/` | Project automation skills (e.g. the Android release workflow) |

Key screens are documented in [CLAUDE.md](CLAUDE.md), along with the state
management, auth and data-layer conventions this codebase follows.

## Releases

The Android release sequence (tests, version bump, push to `main`, Firebase
deployment, signed AAB) is documented in
[.claude/skills/goodlift-release/SKILL.md](.claude/skills/goodlift-release/SKILL.md).

## Notes

This is a production app. Before making changes, read the development rules in
[CLAUDE.md](CLAUDE.md) — in particular, Firestore schemas and paths, the block
builder (`Camp_BB2.dart`), the workout entry screen
(`workout_entry_screen.dart`) and progression logic are all sensitive.
