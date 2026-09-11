---
name: goodlift-release
description: Complete a user-requested GoodLift release through tests, versioning, push to main, necessary Firebase deployment, and a verified signed Android AAB for manual Play upload.
---

# GoodLift release

Run this workflow when the user requests a release, including as the final stage of a feature or fix. Follow the user's scope, version instructions and existing authorization. Loading this skill alone is not a release request. Continue through routine steps without requesting the same authorization again.

The deliverable is a verified signed Android AAB, the corresponding commit on `origin/main`, and verified backend updates where required. Richard uploads to Play internal testing and runs phone tests. An Android release does not establish iOS readiness.

## Project facts

- Repository: `Razors-Edge-PT/razorsedge-app-Apple`; release branch: `main`.
- Final Windows build checkout: `C:\Projects\RE-test` (Git Bash: `/c/Projects/RE-test`).
- Firebase production project: `goodlift-us-storage`; Android application ID: `com.goodlift.razorsedge`.
- Version source: `pubspec.yaml`. Android Gradle reads generated `flutter.versionName` and `flutter.versionCode` from local properties: the pubspec value alone does not prove the AAB version.
- Canonical AAB: `build/app/outputs/bundle/release/app-release.aab`. Preserve a versioned copy as `GoodLift-<version>+<build>-release.aab` in that folder.

Verify these facts against the checkout. Honor an explicit user override; report an unexplained repository, project or package mismatch before deploying.

## 1. Establish the release and preflight

- Read `CLAUDE.md` and applicable directory instructions. Inspect Git status, branch, remote and recent release history; fetch `origin`. Identify the completed task changes and integrate current `main` before final validation.
- Coordinate with other work in this checkout. Preserve unrelated edits; do not discard or silently stash them. Resolve routine integration conflicts using task context. An unresolved ownership conflict is a blocker.
- Identify the previous app release and the relevant backend deployment baseline separately. A clean Git tree or equality with `origin/main` does not establish what is deployed.
- Before overwriting the old AAB, record its embedded version, size, SHA-256 and upload-certificate fingerprint. Preserve any baseline needed for comparison outside directories about to be cleaned.
- Check Flutter/Android/JDK and signing-tool availability. For backend work, use the Node version specified by `functions/package.json` and check Firebase access to the intended project. Check gcloud/ADC only when the required operations use it. Reuse existing authentication and signing configuration; never print or commit credentials.
- If resuming a partial release, establish which version and stages already completed. Resume from that checkpoint rather than repeatedly bumping the version or redeploying completed resources.

## 2. Verify the completed changes

Run checks against the integrated candidate. Inspect exit codes, including `$LASTEXITCODE` for native commands in PowerShell; a shell returning to the prompt is not proof of success.

| Scope | Required checks |
| --- | --- |
| Android app release | From the repo root: `flutter pub get`, `flutter analyze`, `flutter test` |
| Functions logic, shared helpers or dependencies | From `functions`: restore locked dependencies when needed, then `npm test` |
| Firestore/Storage rules or affected client write contracts | From `functions`: `npm run test:rules` |
| Trigger, transaction or delivery behavior | From `functions`: `npm run test:emulator` |

Read the current package scripts before running them. Emulator scripts use the isolated `rules-test` project; do not redirect tests at production. The existing emulator setup uses Java 21.

Run relevant new regressions as well as the applicable existing gates. Fix failures caused by the task; do not weaken tests or alter unrelated production behavior to make the suite green. Compare analyzer findings with the pre-task baseline and report pre-existing issues. Reuse valid results for unchanged code instead of repeatedly rerunning full suites; rerun affected checks after fixes or integration changes. Clearly mark any required check that could not run.

Treat failed required tests or new analyzer regressions as release blockers. Environment-blocked gates must remain explicitly unverified.

## 3. Set the release version

Use the user's specified version, or default to one patch-version increment and an Android build number above the highest known used value. Check Git, local release records and Play when accessible. If Play's highest uploaded versionCode is unavailable, use the highest available evidence and explicitly mark the Play check as pending; do not claim it is verified.

Reuse a candidate version already bumped for this same release unless its build number has been uploaded or the user requests another release. Never reuse an uploaded versionCode. Read current values each time; do not hardcode a version in this skill.

After updating `pubspec.yaml`, run `flutter pub get` again and review any generated or lockfile changes. Do not use `--no-pub` for the release AAB: this project has encountered stale version/splash metadata with that shortcut. Do not run `flutter clean` routinely; use it to resolve an identified build-cache issue.

## 4. Commit and push

Review and stage only the intended source, tests, version and necessary configuration changes. Exclude credentials, local machine settings, build outputs and signing material. Commit with a clear message, push normally to `main`, and confirm the release commit is on `origin/main`. Never force-push.

Record the exact release SHA. Deployment and AAB production must use that same source revision with no unexplained tracked changes. If `main` advances, integrate safely and rerun affected validation before continuing. A failed push is not a completed release.

## 5. Deploy only necessary Firebase resources

Determine deployment needs from the changes since the relevant deployment baseline and live state, not just the latest commit or dirty files.

- Client-only changes require no Firebase deployment.
- Trace changes in shared Functions helpers to every affected exported function. Build a precise `--only` list using selectors such as `functions:exportName`; do not use the broad `npm run deploy` script by default.
- Deploy changed Firestore rules, indexes or Storage rules with their appropriate selectors. Before replacing rules/index configuration, reconcile unexpected production drift with the intended change. Preserve compatibility with installed app versions.
- Always specify `--project goodlift-us-storage`. Use the configured regions and trigger locations; do not infer them from an old session note.
- Follow the feature's dependency order. Migrations, backfills, resource deletion and changes to access or billing require authorization within the actual task; they are not automatic release steps. Inspect CLI prompts rather than blanket-accepting them with `--force`.

Verify the affected resources after deployment: deployed state/revision, rules/index status, relevant startup logs, and a suitable smoke check when available. A successful CLI exit alone does not prove the feature works. Keep smoke checks within the task's authorized test accounts/data. If no deploy is needed, record that conclusion and its basis.

## 6. Build and verify the signed AAB

From the verified release checkout, run:

```text
flutter build appbundle --release
```

Use the existing upload signing configuration. If the build causes tracked changes, inspect them and restore source/release consistency before declaring completion; never quietly ship an artifact from uncommitted source.

Verify the actual newly built artifact:

1. Inspect its embedded base manifest with `bundletool` or an equivalent available decoder: package `com.goodlift.razorsedge`, expected versionName and versionCode. Do not infer these from the filename or pubspec.
2. Run `jarsigner -verify` and inspect the certificate with `keytool -printcert -jarfile`. Compare the fingerprint with a trusted previous upload-signed AAB or the configured upload certificate, not an APK signed by Google's separate Play app-signing key.
3. Inspect task-relevant manifest entries/components when native wiring changed.
4. Record SHA-256, exact byte size and delta against the previous AAB. Raw AAB size is not Play's device download estimate.
5. Create the versioned copy and confirm its SHA-256 matches the canonical file. Confirm the final commit/worktree status and fetch/check `origin/main` again; report any later remote changes rather than claiming equality.

A manifest/version or signing mismatch blocks a ready-to-upload claim. If the source, deployment or build fails, report the completed stages and exact blocker; do not describe a partial release as complete.

## Handoff

Save a concise release record under the ignored `build/release-verification/` directory and present the essentials directly in the final response:

- Version/build, release SHA, `origin/main` relationship and working-tree status.
- Tests and analyzer results, with skipped/unverified gates and any baseline issues.
- Firebase resources deployed and verification, or why no deployment was needed.
- Absolute Windows AAB paths, embedded identity/version, signature/certificate result, SHA-256, size and size delta.
- A short feature-specific Play internal-testing checklist, including relevant upgrade, account and offline cases.
- Remaining manual steps. Richard handles Play upload and phone testing; identify any unverified Play versionCode, APNs/iOS setup or device delivery explicitly.

Give actionable blockers with the minimal login or environment commands required. Do not claim a device test, cloud check or artifact verification that was not actually performed.

References: [Flutter Android release](https://docs.flutter.dev/deployment/android), [Firebase partial deployment](https://firebase.google.com/docs/cli#partial_deploys).
