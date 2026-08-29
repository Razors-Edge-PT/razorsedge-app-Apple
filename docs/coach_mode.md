# Coach Mode

Server-authoritative coach onboarding, entitlements and coach⇄athlete
relationships for GoodLift (`goodlift-us-storage`).

Replaces the previous model, in which coach access came from hard-coded UID
lists in `lib/main.dart`, `lib/user_context.dart` and
`lib/membership_gate.dart` — every new coach needing a code change, a review
and an app release — and in which `coachAssignments` was writable by its own
coach.

---

## 1. The super admin

Richard is the **single hard-coded super admin**:

```
yoVAqScwLMQLAgNHh8v9IK49fBw2
```

It is defined in exactly four places, which must always agree:

| Layer | Location |
|---|---|
| Firestore rules | `firestore.rules` → `isSuperAdmin()` |
| Functions (domain model) | `functions/coach/coach_mode_model.js` → `SUPER_ADMIN_UID` |
| Functions (authorization) | `functions/coach/authz.js` → `SUPER_ADMIN_UIDS` (re-exports the above) |
| Flutter | `lib/coach_mode/coach_mode_models.dart` → `kSuperAdminUid` (used by `UserContext.isSuperAdmin`) |

Super admin is **never** an entitlement, an application or a purchase:

* `coachModeGrantCoach` and `coachModeSetCoachState` explicitly refuse to
  target the super-admin UID.
* `entitlementIsActive()` deliberately does not consider super admin, so a
  document can never grant or withdraw it.
* `isCoachFor()` short-circuits to `true` for the super admin, reading no
  documents at all.
* A rules test asserts that even an explicitly `revoked` entitlement written
  against the super-admin UID does not reduce their access.

Every other coach account is managed entirely through data — **no UID
additions, code changes, rules changes or deploys.**

---

## 2. Collections

All five are **written exclusively by Cloud Functions** (Admin SDK, which
bypasses rules). `allow write: if false` is the entire client write model.

### `coachApplications/{applicantUid}`

Private to the applicant and the super admin.

```
uid                 string
status              'submitted' | 'more_info_requested' | 'approved' | 'declined' | 'withdrawn'
answers             { athleteCountBand, experienceBand, coachingFocus[],
                      competitionExperience[], qualifications, competitionDetails,
                      intendedUse, profileUrl, agreesToAthleteConsent }
applicantSnapshot   { displayName, email }
submittedAt         timestamp
updatedAt           timestamp
submissionCount     number
reviewedAt          timestamp | null
reviewedBy          uid | null
decisionReason      string | null      (decline)
infoRequest         string | null      (more information requested)
withdrawnAt         timestamp | null
```

Enums and limits live in `functions/coach/coach_mode_model.js` and are
mirrored exactly in `lib/coach_mode/coach_mode_models.dart`:

| Field | Values / limit |
|---|---|
| `athleteCountBand` | `0`, `1-5`, `6-15`, `16-30`, `31+` |
| `experienceBand` | `less_than_1`, `1-3`, `4-7`, `8+` |
| `coachingFocus` (multi, ≥1) | `powerlifting`, `bodybuilding`, `general_strength`, `other` |
| `competitionExperience` (multi, ≥1) | `none`, `powerlifting`, `bodybuilding` — `none` is exclusive |
| `qualifications` | optional, ≤ 500 chars |
| `competitionDetails` | optional, ≤ 500 chars |
| `intendedUse` | **required**, 20–600 chars |
| `profileUrl` | optional, http(s) only, ≤ 300 chars |
| `agreesToAthleteConsent` | must be boolean `true` |

Unknown client keys are never persisted — the callable stores exactly the
whitelisted field set returned by `validateApplication()`.

### `accountEntitlements/{uid}` — the authoritative grant

Readable by the account itself and the super admin.

```
uid       string
coach: {
  state              'active' | 'suspended' | 'revoked'
  source             'manual_review' | 'super_admin_grant' | 'iap'
  grantedAt/By       timestamp / uid
  approvedAt/By      timestamp / uid        (manual_review)
  suspendedAt/By     timestamp / uid
  suspensionReason   string
  revokedAt/By       timestamp / uid
  revocationReason   string
  restoredAt/By      timestamp / uid        (re-activation only)
  restoredFrom       'suspended' | 'revoked'
  restoreReason      string
  restoreCount       number
  updatedAt          timestamp
}
coachInviteRate: { recentMs: number[] }     sliding-window rate-limit state
```

**Only `state === 'active'` grants coach access.** A suspended or revoked
coach loses athlete access immediately, even though their relationship
documents still exist.

**Provenance is immutable.** Only a FIRST grant sets `source`, `grantedAt/By`
and `approvedAt/By`. A restore (suspended/revoked → active) preserves all of
them verbatim and records the re-activation separately in `restoredAt/By`,
`restoredFrom`, `restoreReason` and `restoreCount`, so the audit trail of how
an account originally obtained Coach Mode can never be rewritten.

### `coachProfiles/{coachUid}` — invitation-safe identity

```
uid, displayName, email, photoUrl, updatedAt
```

Deliberately contains **none** of the application answers. Readable by the
coach, the super admin, and any athlete who has a link document with that
coach (so an invitation card can name who is asking). It is not a directory:
an unrelated account cannot read it.

### `coachAthleteLinks/{coachUid}__{athleteUid}` — the canonical relationship

Deterministic id ⇒ every operation is naturally idempotent.

```
coachUid, athleteUid    string
status                  'pending' | 'active' | 'declined' | 'cancelled'
                        | 'revoked_by_athlete' | 'released_by_coach'
coachSnapshot           { displayName, email }
athleteSnapshot         { displayName, email }
requestedAt/By          timestamp / uid
respondedAt/By          timestamp / uid
endedAt/By              timestamp / uid
lastAction, lastActorUid, reason
createdAt, updatedAt
```

Readable only by the two parties and the super admin. Multiple coaches per
athlete are fully supported — the id is per pair.

### `coachAdminAudit/{autoId}` — super-admin action log

```
actorUid, targetUid, action, at, metadata { from, to, source, reason, idempotent }
```

Actions recorded: `application_approved`, `application_decline`,
`application_request_info`, `direct_grant`, `coach_suspend`, `coach_revoke`,
`coach_restore`. Super-admin read only; client-unwritable.

---

## 3. State machines

### Application

```
        (none) ──submit──> submitted ──approve──────> approved  (terminal)
                              │  ├──decline────────> declined ──submit──> submitted
                              │  ├──request_info───> more_info_requested
                              │  │                        ├──submit──> submitted
                              │  │                        ├──approve/decline
                              │  │                        └──withdraw
                              │  └──withdraw───────> withdrawn ──submit──> submitted
```

`approved` is terminal — access is managed by the entitlement from then on.

### Entitlement

```
   (none) ──grant/approve──> active ──suspend──> suspended ──restore──> active
                               │                    │
                               └──revoke──────> revoked ──restore──> active
```

Restoring clears the stale suspension/revocation reason so a reactivated coach
is not shown a dead message.

### Relationship

```
   (none) ──coach invites──> pending ──athlete accepts──> active
                               │                            │
                               ├──athlete declines──> declined
                               ├──coach cancels─────> cancelled
                                                            ├──athlete revokes──> revoked_by_athlete
                                                            └──coach releases───> released_by_coach

   every terminated status ──coach re-invites──> pending
```

Each transition is bound to an actor role (`LINK_TRANSITION_ACTOR`): a coach
can never accept on an athlete's behalf, and an athlete can never invite
themselves onto a roster. `transitionLink()` authorises against the **stored**
parties, not the request payload, inside a transaction.

---

## 4. The authorization model

### The rule

**1. The hard-coded super admin is the sole unconditional bypass.** Authorised
for every athlete, reading no documents at all.

**2. For every other account, an ACTIVE coach entitlement is MANDATORY.**

```
accountEntitlements/{coachUid}.coach.state == 'active'
```

A **suspended, revoked, missing or malformed** entitlement denies athlete
access outright — *including* when a legacy seeded assignment or a legacy
approved entry exists. The legacy collections may narrow **which** athletes a
coach reaches; they can never confer coach status. (`coachAssignments` was
historically self-writable, so trusting it alone was the original
vulnerability.)

**3. Given an active entitlement, any ONE of these authorises the pair:**

| # | Source | Notes |
|---|---|---|
| CANONICAL | `coachAthleteLinks/{coachUid}__{athleteUid}.status == 'active'` | What all new UI and Functions write |
| LEGACY 1 | `coachAssignments/{coachUid}.athletes[athleteUid] != null` | Super-admin seeded; super-admin-writable only. **Not** overridden by a terminated link |
| LEGACY 2 | `athleteAssignments/{athleteUid}.coaches[coachUid].approved == true` | Strictly boolean `true`. **Overridden** by a terminated canonical link |

An active entitlement **alone** authorises nothing — it says *this account may
coach*, never *which athletes*.

### Terminal links beat stale legacy approvals

After migration a canonical link and an old `approved: true` entry coexist. A
link in `declined` / `cancelled` / `revoked_by_athlete` / `released_by_coach`
is the **newer, explicit decision**, so an athlete revocation or a coach
release takes effect immediately instead of being silently undone by the
approval flag the link was migrated from.

`pending` is **not** terminal — it neither grants nor terminates.

A terminated link deliberately does **not** override a super-admin seed:
seeding is a separate admin-controlled compatibility path, and this pass does
not redesign it. A coach removes a seed through the removal-only callable.

### Termination with no canonical link

When a relationship exists **only** in the legacy collections, neither party
can edit `athleteAssignments` from a client. Release/revoke therefore writes a
terminal **tombstone** link, which is what cancels the stale approval. So
termination genuinely ends access rather than reporting success while the
legacy entry keeps authorising.

### One rule, three layers

Implemented identically and tested against each other:

| Layer | Implementation |
|---|---|
| Rules | `firestore.rules` → `isCoachFor()` = `hasCoachEntitlement()` **AND** (`hasActiveLink()` OR `hasSeededAssignment()` OR (`hasLegacyApproval()` AND NOT `hasTerminatedLink()`)) |
| Functions | `functions/coach/authz.js` → `evaluateAssignmentDetail()` / `evaluateAssignment()` / `isCoachFor()` |
| Flutter | `lib/coach_roster.dart` → `loadRoster()` switches on `UserContext.coachRole`; `CoachRoster.assignedUids()` composes candidates only and never widens authorization |

### Coach access is not a bypass

Coach access is limited to the explicitly allowlisted training subcollections.
It is **not** a bypass for:

* DMs (`conversations/**` require a confirmed buddy relationship),
* social content (`posts/**`, gated by `isSocial()`, which excludes coaches),
* media (`users/{uid}/liftVideos/**`, social-only reads *and* writes),
* subscription state (`users/{uid}/profile/membership`),
* social invitations (`users/{uid}/buddyInvites/**`),
* the athlete's identity document (`users/{uid}` root doc is read-only to a coach).

### Fail-closed users subcollections

`users/{userId}/{subcoll}/{doc=**}` now reads:

```
allow read, write: if isSelf(userId)
                   || isSuperAdmin()
                   || (isTrainingSubcollection(subcoll) && isCoachFor(userId));
```

The owner and the super admin keep full access to everything. A coach reaches
**only** this allowlist (`isTrainingSubcollection`):

`workouts`, `weights`, `planned_blocks`, `block_planner`, `block_data`,
`plannedExerciseDetails`, `templates`, `customExercises`

`planned_blocks` covers the canonical nested hierarchy
`users/{userId}/planned_blocks/{blockId}/...` via the `{doc=**}` recursion.

> **Two rules bugs fixed here.** Rule evaluation is a logical OR across
> matching blocks, so the previous blanket `canAccessTraining(userId)`
> catch-all silently overrode the narrower blocks above it and handed assigned
> coaches read **and write** on `profile/membership`, `buddyInvites` and
> `liftVideos` — and would have done the same for every subcollection added
> later. Anything not on the allowlist is now unreachable by a coach, so a
> **new** subcollection fails closed until deliberately added.

---

## 5. Cloud Functions

All are v2 callables in `functions/coach/coach_mode.js`, exported from
`functions/index.js`.

| Callable | Caller | Purpose |
|---|---|---|
| `coachModeSubmitApplication` | any signed-in account | submit / resubmit own application |
| `coachModeWithdrawApplication` | applicant | withdraw own pending application |
| `coachModeReviewApplication` | **super admin** | `approve` \| `decline` \| `request_info` |
| `coachModeGrantCoach` | **super admin** | direct grant by uid or exact email |
| `coachModeSetCoachState` | **super admin** | `suspend` \| `revoke` \| `restore` |
| `coachModeAdminLookupAccount` | **super admin** | exact-email account lookup for the grant UI |
| `coachModeInviteAthlete` | active coach | invite by exact normalized email |
| `coachModeCancelInvite` | coach | cancel own pending invitation |
| `coachModeRespondToInvite` | athlete | `accept` \| `decline` |
| `coachModeRevokeCoach` | athlete | revoke an active coach |
| `coachModeReleaseAthlete` | coach | release an active athlete |
| `coachModeRemoveSeededAthlete` | coach (own roster) or super admin | LEGACY seeded removal — **removal only** |
| `coachModeRemoveAthleteFromRoster` | coach | SOURCE-AWARE removal: clears every source the coach may clear, then re-reads and reports `stillAuthorized` / `remainingSources` |

Triggers:

| Trigger | Purpose |
|---|---|
| `coachOnCoachAthleteLinkWritten` | when a link leaves `active`, disable that coach's reporting for the athlete |
| `coachOnAccountEntitlementWritten` | when an entitlement leaves `active`, do the same across that coach's reporting-enabled athletes |

Guarantees enforced server-side:

* Authentication on every callable.
* Hard-coded super-admin check on every admin action.
* Active entitlement checked at invocation time — not from a claim.
* Deterministic document ids ⇒ idempotent operations.
* Self-invites rejected; duplicate pending/active invitations rejected.
* All state transitions validated against the tables above.
* Transactions wherever concurrent responses could conflict (accept vs decline).
* Invitation rate limit: 25 per rolling 24 h, applied **before** the account
  lookup, so a throttled coach learns nothing about which emails exist.
* **No account-search or email-enumeration endpoint.** The only lookup
  (`coachModeAdminLookupAccount`) is unreachable for every account except the
  hard-coded super admin.

### Custom claims

`isCoach: true` is mirrored onto the Firebase custom claim for fast client
routing only. It is **never** the authorization source.

`syncCoachClaim()` reads the account's existing claims and writes them back
through `mergeCoachClaim()`, so **unrelated claims are preserved**. Never call
`setCustomUserClaims(uid, { isCoach: true })` — that destroys every other
claim the account carries. Covered by
`functions/test/coach_mode_model.test.js`.

---

## 6. Membership

An active Coach Mode entitlement grants app + Coach Dashboard access without
adding the UID to `freeMembershipUids` (`lib/membership_gate.dart`):

* `_watchCoachEntitlement()` streams `accountEntitlements/{uid}`.
* Only `state === 'active'` passes the gate.
* On error, nothing is granted — the account falls back to normal membership
  rules, so the athlete paywall is unweakened.

**Applying is never gated by the paywall.** Entry points:

* Drawer → *Coaching* → **Coach Mode**
* `MembershipInactiveScreen` → *"Are you a coach? Apply for Coach Mode"*

### Where future coach IAP plugs in

Nothing about authorization changes. A verified coach purchase simply calls
the same entitlement writer with `source: 'iap'`:

```js
await applyEntitlementState(uid, 'active', {
  actorUid: 'system:iap',
  source: 'iap',
  action: 'iap_activation',
});
```

`CoachEntitlementSource.iap` already exists on the client, the membership gate
already honours it, and `entitlementIsActive()` already accepts it. A lapsed
subscription calls the same writer with `'revoked'`.

---

## 7. Migration

`functions/migrate_coach_mode.js` — **dry run by default**, `--apply` required
to write, never deletes anything, safe to rerun.

```bash
# 1. Inspect what would change (writes nothing)
node functions/migrate_coach_mode.js

# 2. Machine-readable form, for diffing between runs
node functions/migrate_coach_mode.js --json > migration-dryrun.json

# 3. Perform the writes
node functions/migrate_coach_mode.js --apply

# 4. Also refresh the mirrored isCoach custom claims (merged, never replaced)
node functions/migrate_coach_mode.js --apply --claims

# 5. Only after super admin has REVIEWED the unresolved uids (see below)
node functions/migrate_coach_mode.js --apply --allow-unresolved
```

### Exit-code contract

| Code | Meaning | Notes |
|---:|---|---|
| `0` | OK | dry run completed, or apply completed with no failures |
| `1` | Unexpected exception | unhandled error |
| `2` | Project blocked | wrong or unresolved Firebase project; no reads attempted |
| `3` | Unresolved legacy coaches | a DATA condition; overridable with `--allow-unresolved` |
| `4` | Incomplete audit / preflight | a REQUIRED read failed. Dry runs return this too. `--apply` performs **zero** writes. **Not** overridable |
| `5` | Apply failed | one or more MUTATIONS failed. Does **not** imply zero writes |

### Safety gates on `--apply`

A dry run is safe anywhere. Gates run in order, all before any write.

**Gate 1 — project.** Must resolve to exactly `goodlift-us-storage`. Anything
else — unresolved, or a near-miss like `goodlift-us-storage-dev` — exits **2**
before a single read.

**Gate 2 — audit completeness (operational).** Every required read runs first,
in a planning phase that writes nothing: the discovery scans, each reviewed
coach's entitlement, each candidate link, and **every identity lookup**
(Firebase Auth + `users/{uid}`). If any fails, `auditComplete` is `false`, the
counts are untrustworthy, and the run exits **4** — for a dry run too. Under
`--apply` the abort happens before the first write.

`--allow-unresolved` deliberately cannot reach this gate: it overrides reviewed
**data**, never a failure to read.

**Gate 3 — unresolved legacy coaches (data).** Only reachable once the audit is
known complete, so the verdict is a real answer rather than the empty list a
failed scan used to produce. Exits **3**; `--allow-unresolved` overrides.

**Gate 4 — mutation outcome.** Any failed Firestore or Auth write exits **5**.

### Preflight / mutation separation

Planning (`planEntitlements`, `planClaims`, `planRelationships`) performs every
required read and caches resolved identities on the plan. Mutation
(`applyEntitlements`, `applyClaims`, `applyRelationships`) uses only prepared
values and performs **no ordinary identity or discovery reads**. A credential,
permission or network failure therefore cannot strike mid-mutation.

### Concurrency

* **Entitlement + profile** are written in **one Firestore transaction** that
  **revalidates the entitlement state inside the transaction**. An entitlement
  suspended or revoked between preflight and mutation is never resurrected —
  it is reported as `entitlement-state-conflict` and exits 5.
* **Links** use `create()`, which fails if the document now exists. A link
  created, accepted, declined, revoked or released between preflight and
  mutation is never overwritten; the collision is reported as
  `link-create-conflict` and exits 5.

### Honest partial-write reporting

This migration spans Firestore **and** Auth, so it cannot be globally atomic
and does not pretend to be. Two report fields carry the truth, and the
human-readable banner is derived from them — not from `blocked`, which is also
set by the pre-mutation gates:

| Field | Meaning |
|---|---|
| `mutationStarted` | the mutation phase began; the script can no longer prove nothing was written |
| `writesPerformed` | how many individual writes actually landed |

| Situation | Banner |
|---|---|
| Gate 1/2/3 (before mutation) | `*** BLOCKED - NO WRITES PERFORMED ***` |
| Gate 4, `writesPerformed > 0` | `*** APPLY INCOMPLETE - PARTIAL WRITES MAY HAVE LANDED ***` + counts |
| Gate 4, `writesPerformed == 0` | `*** APPLY FAILED - NO WRITES LANDED (preflight was OK) ***` |

The banner never claims zero writes unless the script can prove mutation never
began, and the JSON and human reports always describe the same state. On exit 5
the report names exactly what landed (`applied.entitlements` / `.profiles` /
`.claims` / `.links`) and what did not (`applyFailures`), and states that a
**rerun is required**. Every operation is idempotent — the next preflight skips
whatever already succeeded.

### The mirrored claim follows the entitlement

`isCoach` is only a routing hint, but it must never contradict a deliberate
suspension or revocation. `planClaims()` therefore decides per uid:

| Entitlement disposition | Claim action |
|---|---|
| active at preflight | grant, **revalidated inside `applyClaims`** |
| will be activated this run | grant **only if** the entitlement transaction succeeded |
| suspended / revoked | **remove** `isCoach` if a stale one exists; never grant. Unrelated custom claims are preserved (`mergeCoachClaim`) |
| account missing, entitlement unreadable, super admin | nothing |

The revalidation read in `applyClaims` happens *after* mutation has begun, so a
failure there is an **apply failure (exit 5)**, never an incomplete-preflight
error. The entitlement remains the sole authorization source; the claim only
mirrors it.

### Deleted and missing accounts

`auth/user-not-found` is a **data fact**, not an operational failure, so a stale
uid never blocks the migration. But:

* a reviewed coach whose Auth account is gone is **not** planned for an
  entitlement, profile or claim (`reviewed-coach-account-missing`);
* an approved legacy relationship whose coach or athlete is gone is **skipped**
  rather than written as a blank active link (`link-party-account-missing`).

### Unresolved legacy coaches

The script scans **both** assignment collections for every uid that legacy data
would authorise as a coach, and reports each that is neither in the reviewed set
(`LEGACY_COACH_UIDS`) nor already actively entitled.

These are **never auto-entitled.** `coachAssignments` was historically
self-writable, so a discovered uid may simply be an account that wrote itself a
roster; auto-granting from that data would re-open the very vulnerability this
work closed. Resolve by having super admin review each uid and grant Coach Mode
explicitly (Coach Management → Grant, or `coachModeGrantCoach`), then rerun.

## 8. Retiring the legacy path

Do **not** do any of this until adoption is confirmed in production.

**Order matters.** Each step must be verified before the next.

1. **Confirm coverage.** Rerun the migration in dry-run mode; every legacy
   approved relationship should report `link-already-active`, and every
   hard-coded coach `entitlement-already-active`.
2. **Confirm client adoption.** Ensure the app version that reads
   `coachAthleteLinks` (this release) is the effective floor — older versions
   still depend on `athleteAssignments` and `accessRequests`.
3. **Remove the legacy branches from `isCoachFor()`** in *all three* layers at
   once — `firestore.rules`, `functions/coach/authz.js`, `lib/coach_roster.dart`
   — leaving only the canonical entitlement + link check. Deploy rules and
   functions together.
4. **Remove the hard-coded lists**: `_devCoachUids` (`lib/main.dart`),
   `UserContext.isAdmin` (`lib/user_context.dart`), and the non-super-admin
   entries of `freeMembershipUids` (`lib/membership_gate.dart`). Keep
   `kSuperAdminUid` forever.
5. **Retire `accessRequests`** — already unused by the new UI; the collection
   and its rules block can go once no old client writes to it.
6. **Retire `athleteAssignments`** — read-only first for one release, then
   remove.
7. **Decide on `coachAssignments` separately.** Seeded data is deliberately
   untouched in this pass. Migrating it into canonical links needs a product
   decision (seeded athletes never explicitly consented, so converting them to
   `active` links changes their meaning). Until then it stays a valid,
   super-admin-only authorization source.

`lib/request_access_screen.dart` is no longer referenced by the coach
experience but is left in the tree so any remaining route/rollback path keeps
compiling. Delete it in step 5.

---

## 9. Deployment

### The Cloud Run invoker step (specific to this project)

This organisation enforces Domain Restricted Sharing
(`constraints/iam.allowedPolicyMemberDomains`), so granting `allUsers` the
`roles/run.invoker` binding is **rejected**:

```
FAILED_PRECONDITION: One or more users named in the policy do not belong to a
permitted customer, perhaps due to an organization policy.
```

`{ invoker: 'public' }` in the function options is therefore **not sufficient**.
Every **newly created** callable needs this once, out of band:

```bash
gcloud run services update <lowercased-function-name> \
  --no-invoker-iam-check \
  --region=us-central1 \
  --project=goodlift-us-storage
```

### Deploying ONLY the Coach Mode exports

Never run an unrestricted `firebase deploy --only functions` for this feature —
it would touch every unrelated function in the project. Deploy exactly the 13
callables and 2 triggers, and nothing else.

Build the selector from an array so no stray whitespace can corrupt it:

```bash
COACH_MODE_EXPORTS=(
  coachModeAdminLookupAccount
  coachModeCancelInvite
  coachModeGrantCoach
  coachModeInviteAthlete
  coachModeReleaseAthlete
  coachModeRemoveAthleteFromRoster
  coachModeRemoveSeededAthlete
  coachModeRespondToInvite
  coachModeReviewApplication
  coachModeRevokeCoach
  coachModeSetCoachState
  coachModeSubmitApplication
  coachModeWithdrawApplication
  coachOnAccountEntitlementWritten
  coachOnCoachAthleteLinkWritten
)
SELECTOR=$(printf "functions:%s," "${COACH_MODE_EXPORTS[@]}")
SELECTOR=${SELECTOR%,}

firebase deploy --project goodlift-us-storage --only "$SELECTOR"
```

The first 13 entries are the callables; the last two are the Firestore
triggers. Regenerate the list straight from the source of truth:

```bash
grep -oE "^exports\.(coachMode[A-Za-z]+|coachOn(CoachAthleteLink|AccountEntitlement)Written)" \
  functions/index.js | sed 's/exports\.//' | sort
```

For the thirteen new callables:

```
coachmodesubmitapplication      coachmodeinviteathlete
coachmodewithdrawapplication    coachmodecancelinvite
coachmodereviewapplication      coachmoderespondtoinvite
coachmodegrantcoach             coachmoderevokecoach
coachmodesetcoachstate          coachmodereleaseathlete
coachmodeadminlookupaccount     coachmoderemoveseededathlete
                                coachmoderemoveathletefromroster
```

Always confirm the exact service names Cloud Run reports rather than trusting
this list: `gcloud run services list --project=goodlift-us-storage`.

The two Firestore TRIGGERS — `coachOnCoachAthleteLinkWritten` and
`coachOnAccountEntitlementWritten` — must **not** be given invoker-disabled or
public access. They are event-driven and are never invoked over HTTP.

Verify: the service annotation `run.googleapis.com/invoker-iam-disabled` is
`"true"`, and an unauthenticated POST returns **401** (our application layer)
rather than **403** (infrastructure block).

### Full deployment order

Designed so **no existing coach is ever locked out**.

| # | Step | Verify before continuing |
|---|---|---|
| 1 | `node functions/migrate_coach_mode.js` (dry run) | Counts look right; zero unexplained `problems` |
| 2 | `node functions/migrate_coach_mode.js --apply` | Every hard-coded coach has `accountEntitlements/{uid}.coach.state == 'active'`; approved relationships are active links |
| 3 | `node functions/migrate_coach_mode.js --apply --claims` | `isCoach` claim set; unrelated claims intact |
| 4 | Deploy ONLY the Coach Mode exports (see the `--only` selector below) | All thirteen callables + two triggers listed |
| 5 | Apply the `--no-invoker-iam-check` step above to each **new** callable | Unauthenticated POST returns 401, not 403 |
| 6 | `firebase deploy --only firestore:indexes` then `firebase deploy --only firestore:rules` | Indexes **Enabled** before rules go live, so admin queries do not fail |
| 7 | Release the compatible app version | Coach Dashboard, Coaching area and Coach Mode screen all load |
| 8 | Verify a seeded coach and an approved coach in production | Both still see their athletes |
| 9 | Later, after adoption: §8 legacy retirement | — |

Steps 2 and 3 run **before** the rules deploy, so the moment the rules begin
requiring an entitlement, every existing coach already has one.

### Rollback

| Symptom | Action |
|---|---|
| Rules problem | Redeploy the previous `firestore.rules`. The legacy branches are still present in this release, so seeded and approved coaches keep working with no data change. |
| Functions problem | Redeploy the previous functions. The new collections are additive; nothing in the old code reads them. |
| App problem | Ship the previous app build. It reads `athleteAssignments` / `coachAssignments`, both untouched by the migration. |
| Bad entitlement | `coachModeSetCoachState` with `revoke`, or delete the `accountEntitlements` document with the Admin SDK. |
| Bad relationship | `coachModeReleaseAthlete` / `coachModeRevokeCoach`, or set the link `status` directly with the Admin SDK. |

The migration never deletes legacy data, so **every rollback path is a
redeploy, never a data restore.**

---

## 10. Tests

```bash
# Functions unit tests (no emulator)
cd functions && npm test

# Firestore rules + Functions integration (needs JDK 21+ for the emulator)
cd functions && npm run test:rules

# Flutter
flutter test
flutter analyze
```

| Suite | File |
|---|---|
| Domain model, validation, state machines, claim merging, rate limit | `functions/test/coach_mode_model.test.js` |
| Legacy + canonical authorization evaluation | `functions/test/coach_authz.test.js` |
| Callable behaviour, authorization, idempotency, atomicity, audit, enrollment | `functions/test-rules/coach_mode.spec.js` |
| Rules: vulnerability closure, canonical/legacy access, privacy, forgery, no social/DM bypass | `functions/test-rules/coach_mode_rules.spec.js` |
| Client models, role resolution, roster composition, screen state | `test/coach_mode_models_test.dart` |
