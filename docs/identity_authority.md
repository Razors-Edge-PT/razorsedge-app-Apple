# Username authority and the 1.7.13 compatibility window

## The problem

`username`, `usernameLower` and `displayName` on `users/{uid}` and
`users_public/{uid}` are supposed to be owned by one writer: the
`profileChangeUsername` callable, which is the only thing that writes the
case-insensitive reservation index at `usernames/{sha256(normalised)}`.

Until 1.7.13 the rules did not say so. `users/{userId}` allowed
`write: if isSelf(userId)`, and `users_public/{userId}` allowed the same with
only `profileShowcaseV1` excluded. So any client — including a patched one, or
simply an older build — could write those three fields directly and never
touch the reservation index. Case-insensitive uniqueness was a convention the
current app happened to follow, not a guarantee.

## Why a flat deny would have broken production

Installed builds before 1.7.13 stamp `username` + `usernameLower` onto **both**
user documents during signup. That write comes from
`buildIdentityPayloadFields()` in `lib/onboarding_identity_payload.dart`, called
from `OnboardingPageTwo._finish()`, and those builds never call the callable at
all.

Deploying a rule that denies every client identity write would therefore break
**account creation** on every install that has not yet updated — the worst
possible failure, because the person affected has no account yet and no way to
report it.

## The strategy

Three parts, and each one is load-bearing.

### 1. Rules: deny the rename, keep the first claim

`identityWriteAllowed()` in `firestore.rules` permits exactly one client
identity write:

* the **first** username on an account that has none
  (`hasNoUsernameYet()` — both `username` and `usernameLower` empty or absent),
* before the cutoff (`legacyIdentityClaimWindowOpen()`),
* obeying the same shape the callable enforces
  (`legacyUsernameShapeOk()`: 3–22 characters, no whitespace, and
  `usernameLower == username.lower()` so a claim cannot index one name while
  displaying another).

Everything else is denied, at all times, in every build:

| Write | Allowed? |
| --- | --- |
| First username on an account with none, inside the window | yes |
| Renaming an existing username | **no** |
| Changing only `usernameLower` | **no** |
| A casing-only change | **no** |
| Writing `displayName` | **no**, ever — no client build has written it |
| Removing a username | **no** |
| Another account's identity | **no** |
| Super admin | yes (unchanged, matching the rest of the file) |

The rename is the dangerous case: it is the one that can take a name from
another account. It also has no legacy caller, because renaming has always gone
through the settings screen and the profile page, both of which already use
`IdentityRepository.changeUsername`. So closing it costs nothing and is done
immediately.

Covered by `functions/test-rules/identity_authority.spec.js` (18 cases against
the real rules engine).

### 2. A reconciler behind the window

A write that skips the reservation service skips its uniqueness transaction, so
two pre-1.7.13 installs can still claim the same name in the same moment.
`identityOnPublicProfileWritten` (`functions/identity/reconcile.js`) closes that
gap: it fires on every `users_public` write and, in one transaction, compares
the stored name against `usernames/{hash(name)}`.

| Index state | Outcome |
| --- | --- |
| No reservation | **CLAIM** — index it to this account. The legacy write becomes indistinguishable from a callable-made one. |
| Reserved to this account | **NOOP**, beyond correcting stored display casing. Every callable-made change takes this path, so the callable is never fought by its own reconciler. |
| Reserved to another account, or a contested marker | **RENAME** — the existing holder keeps the name; the claimant is moved to the first free numbered variant and both of its documents are rewritten. |

The loser is *moved*, not emptied: an account with no username cannot be
searched for, and every historical comment and roster row that mentions it
resolves to nothing.

Convergence: the trigger writes `users_public`, so it re-fires itself once. The
second pass sees a name that matches its own reservation, takes the NOOP path
and writes nothing. Every path is idempotent, which is what makes `retry: true`
safe.

Cost in the normal case: a rename made through the callable already agrees with
its reservation, so the trigger reads a handful of documents and writes nothing.

Decision core covered by `functions/test/identity_reconcile.test.js`
(11 cases, no emulator needed).

### 3. Drift repair for everything written before the trigger existed

`node scripts/migrate_usernames_index.js --project goodlift-us-storage --reconcile`

reports index **drift** — a reservation whose stated owner has since moved to a
different name. Deleting one of those is always safe: the reservation asserts
"uid X holds name N", X's own documents say X displays something else, so the
assertion is already false and the only thing the stale key achieves is keeping
N unclaimable forever. Add `--apply` to delete them.

The opposite drift — an account **displaying** a name the index assigns to
somebody else — is reported and never repaired by the script. Both parties are
real accounts, resolving it means renaming one of them, and that is an
operator's decision. The trigger resolves this case for every claim made from
now on.

Existing modes are unchanged: default dry-run, `--apply`, `--verify`.

## Retiring the window

`legacyIdentityClaimWindowOpen()` compares `request.time` against a literal:

```
return request.time < timestamp.date(2027, 3, 1);
```

A literal rather than a config document, deliberately:

* no extra document read on every profile write,
* no "config document is missing, so fail open" hole,
* moving it is a reviewed change to a file in version control.

### When to move it

Move it into the past once the pre-1.7.13 install base is small enough that a
broken signup on those builds is acceptable — in practice, once Play Console
and App Store Connect show the 1.7.13+ share of active installs above ~99% and
the remaining versions are ones that can no longer sign in for other reasons.

### How to verify before moving it

1. Run the reconcile report. `driftNameHeldByOther` should be 0.
2. Check Cloud Functions logs for `username reconciled` entries with
   `decision: "claim"`. Those are legacy signups still using the window; when
   they stop appearing, nothing is using it.
3. Change the literal, deploy rules only, and watch signup completion rate.

### If it has to be reverted

Move the literal back and redeploy rules. Nothing else changes: the reconciler,
the callable and the index are all unaffected by the window, and no data
migration is involved in either direction.

## Where identity is READ

The other half of the same problem. Historical documents carry a denormalised
copy of whatever the author was called when the document was written —
`comments.username`, `buddyAssignments.athletes[uid].displayName`,
`coachAssignments` roster rows, leaderboard rows. That copy is **audit data**.
It records what the name was; it is not who the person is.

`LiveUserName` / `LiveUserAvatar` (`lib/profile/ui/live_identity.dart`) resolve
by uid through `IdentityRepository.watchPublicIdentity`, with the denormalised
value passed as `fallback` — used only for the first frame and for a genuinely
cold offline cache. Surfaces converted:

* feed post headers (`lib/post_header.dart`)
* historical comments (`lib/post_media.dart`)
* DM buddy picker and conversation list (`lib/directMessages.dart`)
* both leaderboards (`lib/leaderboard_page.dart`)
* coach weekly-review roster (`lib/coach_weekly_review_screen.dart`)
* coach admin roster (`lib/coach_mode/coach_admin_screen.dart`)
* the profile page itself (`ProfileController.displayName`)

`PostHeader` previously held a `static Map<String, Future<…>>` whose comment
proudly noted "exactly one Firestore read per uid per process lifetime". That
was true, and it was the bug: a rename was invisible until the app was killed
and reopened. One channel per uid now serves every surface — so N comments by
one author still cost one Firestore listener, and all N update together.

Covered by `test/profile_rename_propagation_test.dart` (13 cases), which
renames an account in Firestore underneath a mounted widget and asserts the
widget shows the new name with no restart and no rebuild of the tree.
