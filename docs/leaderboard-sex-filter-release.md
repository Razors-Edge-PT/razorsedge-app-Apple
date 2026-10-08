# Leaderboard sex filter release — 1.7.54+124

The app and both goodliftapp.com leaderboard views offer All / Male / Female
as one checked selection beside the independent age-weighting option. All is
the default after leaving the leaderboard, backgrounding/closing the app,
reloading the website, or returning through browser history. Changing the
leaderboard period keeps the active filters. Ranks start at 1 within the
selected group; existing category medals retain their existing meaning.

The publisher selects each sex's top 20 from the complete server-ranked pool,
for both score views. Explicit profile M/Male and F/Female values select their
respective group; unknown and Yes. remain in All. It writes hourly derived root
snapshots under existing signed-in leaderboard rules and anonymous snapshots
under the existing server-only public collection. No private profile access,
new composite index, scoring change, workout migration or new rule is needed.
Existing unfiltered app queries and public responses remain compatible.

## Validation performed in the implementation environment

- Functions unit suite: 975 passed.
- Full Functions emulator suite, isolated rules-test project: 137 passed.
- Relevant leaderboard access-rule suite: 17 passed, including filtered roots.
- Website contract/proxy suite: 15 passed, including all 12 cache combinations.
- Browser DOM integration: 7 scenarios passed, including navigation/background
  reset, sex plus age weighting, and discarded late responses.
- Dart sources parsed with the SDK formatter; full Flutter dependency
  restoration, analysis and widget tests remain unverified. Automatic approval
  review stopped SDK setup after unexpected cloud-metadata HTTP access.
- A broader rules-suite attempt failed in unchanged profile/DM Storage-read
  tests. firestore.rules, storage.rules and that test file are unchanged.
  This is not a claim that the full rules suite passed.

## Rollout and desktop command

App source is intended for main. The website release branch is
`codex/leaderboard-sex-filter-20261008`; its main publication must follow the
backend rollout so the new controls do not point at an unsupported API.
The implementation environment has no authorized Firebase account, so cloud
rollout and the signed Android build require the existing desktop credentials.

From C:\Projects\RE-test after a normal fast-forward pull of main, run:

```powershell
& .\tool\release_leaderboard_filters.ps1
```

The script runs Flutter and backend checks, deploys only
leaderboardPublicPublisher/publicLeaderboard to goodlift-us-storage, preserves
the existing public endpoint access, immediately publishes all derived sex
boards, and smoke-checks all 12 backend combinations. It then normally pushes
the prepared website branch to website main, waits for the existing Cloudflare
Pages deployment, and builds the signed AAB with existing upload signing.
It stops on errors and preserves an existing canonical AAB before rebuilding.

Expected versioned artifact:
C:\Projects\RE-test\build\app\outputs\bundle\release\GoodLift-1.7.54+124-release.aab

Signing is checked and SHA-256 printed by the script. Embedded package/version,
comparison with the trusted upload certificate, the highest Play versionCode,
Play upload, and phone/iOS verification remain manual and are not claimed
verified by this source update. Intended Android package: com.goodlift.razorsedge.

Phone checks: Male and Female on both periods; add/remove age weighting without
changing sex; check rank 1 within the selected group; leave/return, background,
close/reopen and open profile/medal detail to confirm reset to All; reopen a
previously viewed filtered board offline. Richard uploads only to Internal
Testing for this release.
