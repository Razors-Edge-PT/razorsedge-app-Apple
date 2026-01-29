# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Razor's Edge (RE) is a Flutter fitness coaching app for workout logging and periodized training. The app targets iOS and Android with Firebase backend and Cloud Functions.

- **Firebase Project**: `goodlift-us-storage`
- **Bundle ID**: `com.goodlift.razorsedge`
- **Flutter SDK**: >=3.4.4 <4.0.0

## Common Commands

```bash
# Flutter (main app)
flutter analyze          # Lint check
flutter test             # Run tests
flutter run              # Run in debug mode
flutter build apk        # Build Android APK
flutter build ios        # Build iOS
flutter pub get          # Install dependencies

# Cloud Functions (run from /functions directory)
npm run serve            # Start Firebase emulator
npm run deploy           # Deploy to Firebase
npm run logs             # View function logs
```

## Architecture

### State Management
- **Provider** with `UserContext` (`lib/user_context.dart`) as the central state container
- `UserContext` tracks: authenticated user UID, coach role, active block metadata, avatar
- Block metadata cached in `SharedPreferences` for instant hydration on app launch

### Authentication & Roles
- Firebase Auth (email + Google Sign-In)
- Coach status via JWT custom claim `isCoach` OR hardcoded UID list in `main.dart` and `user_context.dart`
- `MembershipGate` widget wraps protected routes

### Data Layer
- **Firestore**: Users, exercises, workouts, planned blocks, templates, posts
- **Isar** (local DB): Offline-first sync via autosave queue (`lib/local_cache/`)
- **WarmupService**: Preloads workout data in background

### Key Screens
- `home_screen.dart` - Main dashboard/feed
- `workout_entry_screen.dart` - Workout logging (WES) - largest file
- `Camp_BB2.dart` - Block builder / week planner
- `Block_Planner.dart` - Block planning interface
- `templates.dart` / `template_generator.dart` - Training template management
- `exercises.dart` - Exercise library

### Cloud Functions (`/functions`)
- Stripe payment integration
- RE Points monthly aggregation
- User lookup index maintenance

### Key Patterns
- Global snackbar via `rootScaffoldMessengerKey` and `showAppSnack()` function
- Route observer at app root for analytics
- Non-blocking background refresh pattern (see `_refreshFromServerInBackground` in UserContext)

## File Naming
- PascalCase for screen files: `Block_Planner.dart`, `Camp_BB2.dart`
- snake_case for utilities: `user_context.dart`, `warmup_service.dart`
- Isar models prefixed with `isar_`: `isar_block_plan.dart`

## Development Rules

**This is a production app (Goodlift). Follow these rules:**

- Do NOT change Firestore schemas or paths unless explicitly asked
- Prefer minimal, localized changes
- Never refactor for style unless requested
- Always explain where a change will be made before editing
- Avoid breaking existing BB2, WES, and Block Planner behavior
- Ask before modifying `PeriodizationModelUtils` or progression logic

**Sensitive files** (extra caution required):
- `Camp_BB2.dart` - Block builder / week planner
- `workout_entry_screen.dart` - Workout entry screen (WES)
