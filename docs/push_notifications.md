# Push notifications

GoodLift sends **exactly three** push notifications. Nothing else in the app
sends one: no coach, workout, streak, feed, reaction, marketing or reminder
alerts.

| Event | Recipient | Default text | Tap opens |
|---|---|---|---|
| Incoming friend request | the receiver | "[Name] sent you a friend request" | Buddy Hub → People (REQUESTS) |
| Friend request accepted | the original requester | "[Name] accepted your friend request" | Buddy Hub → People (NEW BUDDIES; marked seen once displayed) |
| Direct message (text/photo/video) | the other participant | "[Name] sent you a message / a photo / a video" | that exact ConversationPage |

Message text appears in a notification only if the recipient turned on
**Settings → Notifications → Show message previews** (default off). With it
off, the text is never put in the FCM payload.

## Architecture

```
buddyInvites write ─► socialOnBuddyInviteWritten ─┬─ acceptance notice + friendAccepted job (one transaction)
                                                   └─ friendRequest job (create-if-absent)
messages write ────► pushOnDirectMessageWritten ──── directMessage job (create-if-absent)
pushOutbox create ─► pushOutboxOnCreated ─────────── validate → FCM sendEach → record per device
```

* `functions/push/push_model.js`: pure rules (occurrences, deliverability,
  wording, payloads, FCM error classes, job state machine).
* `functions/push/outbox.js`: enqueue helpers and the delivery worker.
* `functions/push/triggers.js`: `pushOnDirectMessageWritten`, `pushOutboxOnCreated`.
* `functions/social/notifications.js`: the existing invite trigger, extended.
* `lib/push/`: device registration, tap routing, foreground banner,
  Settings → Notifications.

### Data (all new, nothing existing re-shaped)

| Path | Written by | Client access |
|---|---|---|
| `pushDevices/{sha256(token)}` `{uid, token, platform, appVersion, updatedAt}` | the device | owner get/list/delete; create/update must name the caller, bind the id to the token by SHA-256 and stamp `request.time`; a takeover must present the same token |
| `pushPreferences/{uid}` `{friendRequests, friendAccepted, directMessages, messagePreviews, updatedAt}` | the account | the account only (not a coach, friend or super admin) |
| `pushOutbox/{jobId}` | server | none |
| `pushConfig/delivery` `{enabled}` | console/admin | none (kill switch) |
| `users/{u}/socialNotifications/buddyAccepted_{a}.occurrenceKey` | server | unchanged rule (owner may only set `seen`/`seenAt`) |

These are top-level collections, so the `users/{userId}/{subcoll}` catch-all
cannot grant anything on them.

### Occurrences and duplicates

Friend-pair documents are reused, so identity is the **invite's `createdAt`**.
Every send path (the callable and every older installed build) writes a
fresh one, and every acceptance path keeps it.

* request occurrence = (receiver, sender, `createdAt`)
* accepted occurrence = (requester, acceptor, `createdAt`)
* message occurrence = (recipient, conversation, message id)

Job id = hash(type, recipient, occurrence), created only if absent. The
following never produce a second alert: a redelivered event, repeated Add, a
repair edit, a receiver toggling one invite accepted→pending→accepted, a shell
message later patched with its URL, reactions, read receipts and URL rewrites.
A **new** request after cancel/decline/unfriend has a new `createdAt` and does
notify.

The acceptance notice now records `occurrenceKey`. An acceptance is applied
only when the invite, re-read inside the transaction, is still accepted and is
still that same request. So a replayed or out-of-order old event neither
revives a notice nor re-notifies. Marking a notice seen writes only
`seen`/`seenAt`, which never reaches the trigger, so it can't push or reset
the badge.

### Direct messages

The event source is `conversations/{c}/messages/{m}`. A message notifies once,
on the write that first makes it deliverable:

* text: when saved;
* photo/video: when `imageUrl`/`videoUrl` is attached. The app writes an
  empty shell before uploading (`_pickAndSendImage`, `_pickAndSendVideo`).
  The shell is not deliverable, so a failed upload never notifies.

The recipient is the other account named by the conversation id. The worker
checks that it matches the conversation's `participants`, that the sender is
still the message's `senderId`, and that the pair is still mutually friends.
Unread counts are untouched; the client keeps its own increment.

Rules hardened for this (installed builds' writes all still pass; see
`push_rules.spec.js`):

* message `create` requires `senderId == request.auth.uid`;
* `senderId` is immutable, and only the sender may change content fields
  (attach the URL). The other participant may only change `reactions`;
* conversation `participants` must be exactly the two ids in the conversation
  id (both `true`) on create, and can't be changed on update.

### Delivery worker

1. **Claim** in a transaction: terminal jobs are skipped, jobs past their
   deadline expire, jobs are abandoned after 8 attempts, and a live lease held
   by another worker makes this invocation throw so it is retried later.
2. **Validate against current state**: account exists and is enabled; request
   still pending and the same occurrence; notice the same occurrence and
   **not yet seen**; message still deliverable from the same sender; pair
   still mutual friends; category enabled; kill switch not set.
3. **Send**, outside any transaction, with `sendEach` to the recipient's
   registrations that haven't had this job. Registrations not refreshed for
   60 days are pruned instead.
4. **Record** each device's result. `sent` devices are never resent. Invalid
   tokens (`UNREGISTERED`, bad token, or `INVALID_ARGUMENT` when the same
   payload succeeded elsewhere) are deleted with a guard: only if the
   document still has the same owner and token and wasn't refreshed after the
   send started. Transient failures leave the job pending and the worker
   throws, so Cloud Functions retries it (10–600 s backoff, 24 h retry
   window). That is bounded by the job deadline (24 h social, 12 h DM) and
   the attempt budget.

Payloads are **user-visible notification messages** with routing data. The OS
shows them in the background and when the app is killed. Android uses stable
channels (`goodlift_friend_requests`, `goodlift_friend_accepted`,
`goodlift_direct_messages`), a `tag` per occurrence and `ttl` up to the
deadline. APNs gets `apns-collapse-id`, `apns-expiration` and
`apns-push-type: alert`.

**Not exactly-once.** If a worker dies after FCM accepted a message but before
step 4 commits, the retry sends it again. The stable tag / collapse id makes
the second copy replace the first on the device instead of stacking, but a
second sound is possible. No logs contain message text or whole tokens (token
labels are a 10-character hash prefix).

## App behaviour

* **Registration**: `PushNotificationService.onSignedIn(uid)` is called from
  `AppRoot._handleValidUser` with the FirebaseAuth uid (never
  `UserContext.actingAsUid`), fire-and-forget. It registers only when the OS
  allows notifications, refreshes on token rotation and weekly on resume, and
  drops results that land after an account change. Coach Mode viewing an
  athlete stays the coach's account throughout.
* **Account switching**: one document per token, so the next account signing
  in takes the document over. A token is never registered to two accounts.
* **Explicit logout** (drawer, paywall) and **account deletion**:
  `onExplicitSignOut()` runs before sign-out/deletion. It cancels listeners,
  forgets a pending tap, clears GoodLift notifications from the tray, deletes
  this device's registration and the FCM token. Bounded to 3 s. Offline, the
  logout still completes and the token deletion is retried on next launch;
  the invalidated token is then removed server-side on its first failed send.
  Other devices are untouched. A transient null auth event during startup
  restoration never runs this. If account deletion fails and the person stays
  signed in, the registration is restored.
* **OS limitation**: a notification already delivered or queued by the OS
  before logout can still appear. The tray is cleared at logout, and a later
  tap does nothing unless its recipient is the signed-in account.
* **Permission**: a one-time explanation is offered on Home about 3 s after it
  settles, never over WES2, and only while the OS hasn't been asked. Continue
  shows the OS prompt; allowing it registers the token.
  * On Android 13+ Firebase reports `denied` both BEFORE the prompt and after
    a refusal, so the app keeps its own record of whether it has asked
    (`push.osPermissionRequested.v1`). That record is separate from "the
    explanation was shown" (`push.permissionPrimerShown.v1`) — see
    `resolvePushPermission`. The adapter returns the raw plugin status; only
    the service interprets it. Android 13+: `denied` + never asked = not asked
    yet (explain / "Turn on"); `denied` + asked = denied ("Open settings").
    Android 12 and earlier: `denied` means switched off in system settings
    (there is no prompt). iOS statuses are taken as reported.
  * "Not now" records only that the explanation was shown. Settings →
    Notifications still offers "Turn on", which makes the real OS request.
  * A request is recorded only once the OS has answered. A failed request
    (plugin error) leaves "Turn on" available. Concurrent requests share one
    OS prompt.
  * After a recorded denial the app never prompts automatically. Settings
    offers "Open settings", and returning from there with notifications
    allowed registers on resume.
* **Taps**: background (`onMessageOpenedApp`), cold start
  (`getInitialMessage`) and the foreground banner all go through
  `PushRouter`. It holds the tap until the recipient is signed in **and** a
  `PushReadyScope` is mounted. That scope exists only inside a
  `MembershipGate` that has let the person through (gated Home, restored WES2
  root), so a tap can't bypass the paywall. Destinations are pushed on top.
  A restored workout stays underneath, and the saved startup route is not
  changed. A tap for another account is refused with a message, and taps
  expire after 2 minutes of waiting. If the friendship ended, the DM tap falls
  back to the conversation list.
  * `Navigator.push` completes only when the route is POPPED, so the router
    never awaits it. A destination counts as opened once its push is issued,
    and a second tap opens straight away on top of a screen that is still
    open. Only the asynchronous check before a push (the DM access lookup) is
    serialized. A tap that arrives meanwhile is held and opens next; the
    latest tap wins.
  * After that lookup the router re-checks that the tap is still for the
    signed-in account, that no logout happened (logout bumps a generation),
    and that its context is mounted. A lookup that returns after logout or an
    account switch opens nothing.
  * A repeat tap for the same destination within 2 s (a double tap, or the
    same notification delivered twice) is ignored. A DM tap for the
    conversation already on screen opens nothing.
* **Foreground**: one compact tappable banner (root SnackBar), no OS
  duplicate. None while the matching conversation is the visible route and
  the app is resumed. A conversation merely mounted under another screen
  doesn't count (RouteAware in `ConversationPage`).
* Existing badges are unchanged. Counts come from Firestore state, never from
  how many pushes arrived.

## Platform configuration

**Android**: `POST_NOTIFICATIONS` permission, channels created in
`MainActivity.onCreate` (re-creating is a no-op, so a person's system settings
win), monochrome `@drawable/ic_stat_goodlift`, default icon/colour/channel
meta-data, and a `goodlift/notifications` method channel (open settings,
clear tray). `google-services.json` is unchanged (`com.goodlift.razorsedge`).

**iOS** (source/config done; not buildable or testable from Windows):
`aps-environment` added to `Runner.entitlements` (Sign in with Apple kept),
`UIBackgroundModes: remote-notification`, and the same method channel in
`AppDelegate.swift`. firebase_messaging's FlutterAppDelegate integration
forwards the APNs token, and `getToken()` waits for the APNs token first.

Outstanding Apple steps, which need a Mac, the Apple Developer account and the
Firebase console:

1. Apple Developer → Identifiers → `com.goodlift.razorsedge` → enable **Push
   Notifications**; regenerate/download the provisioning profiles.
2. Keys → create (or reuse) an **APNs Authentication Key (.p8)**. Firebase
   console → Project settings → Cloud Messaging → Apple app configuration →
   upload the key with its Key ID and Team ID. Never commit the .p8.
3. In Xcode, open `ios/Runner.xcworkspace`, then Signing & Capabilities: check
   that Push Notifications and Background Modes → Remote notifications are
   shown (the entitlement/plist entries are already committed). Run
   `pod install`, archive, and upload to TestFlight.
4. Test on a physical iPhone. The simulator and a Windows build are not
   evidence of iPhone delivery. Until step 2 is done, iOS sends fail with
   `messaging/third-party-auth-error`; the worker treats that as permanent for
   the device, without deleting the token.

## Tests

| Suite | Command | New file(s) |
|---|---|---|
| Functions unit | `cd functions; npm test` | `test/push_model.test.js` |
| Rules (emulator) | `npm run test:rules` (Java 21: Android Studio `jbr`) | `test-rules/push_rules.spec.js` |
| Delivery (emulator, FCM mocked) | `npm run test:emulator` | `test-emulator/push_delivery.spec.js` (+ updated `social_notifications.spec.js`) |
| Flutter | `flutter test` | `test/push_notifications_test.dart`, `test/push_permission_routing_test.dart` (real adapter over Android 13+ raw `denied`; real Navigator routing) |

## Deployment

Order (compatible with installed app versions, which don't register tokens):

1. `firebase deploy --only firestore:rules,firestore:indexes --project goodlift-us-storage`.
   The rules are backwards compatible with every installed build's DM writes.
   Indexes adds only the `pushOutbox.purgeAt` TTL override.
2. `firebase deploy --only functions:socialOnBuddyInviteWritten,functions:pushOnDirectMessageWritten,functions:pushOutboxOnCreated --project goodlift-us-storage`.
   All three are 2nd gen, us-central1, with Firestore trigger region `nam5`.
   No callable was added.

No backfill is performed. Triggers act only on writes after deployment, and
only on transitions.

## Rollback / disable

* **Stop all sends immediately (no deploy)**: in the Firestore console create
  `pushConfig/delivery` with `enabled: false` (boolean). Jobs are then marked
  `skipped` (`delivery-disabled`), so re-enabling does not replay a backlog.
  Delete the doc or set `enabled: true` to resume.
* **Remove the delivery worker**:
  `firebase functions:delete pushOutboxOnCreated --region us-central1 --project goodlift-us-storage`.
  Jobs still enqueue harmlessly and are purged by TTL after 7 days.
* **Remove DM enqueueing**:
  `firebase functions:delete pushOnDirectMessageWritten --region us-central1 --project goodlift-us-storage`.
* **Invite trigger**: keep it deployed. It owns the acceptance notices. To
  return it to the pre-push behaviour, redeploy it from the parent of the push
  commit. That also stops friend-request/acceptance jobs.
* Rules: the DM hardening and push blocks are additive restrictions. Reverting
  `firestore.rules` to the previous commit and redeploying restores the old
  rules, but would stop the new app's token/preference writes.

None of these affect acceptance notices, friendships or messaging.
