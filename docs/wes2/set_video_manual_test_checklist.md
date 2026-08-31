# WES2 set video — manual device checklist

Everything below needs a **physical device**. The automated suite covers the
model, the store, the pipeline ordering, the publication gate, the reconciler
and the set-row control, but it substitutes fakes for the camera, the native
trimmer, the filesystem and the network. Nothing here has been executed against
a real camera or a real Firebase project.

Run the whole list on **one current iPhone** and **one current Android device**.

- Build: `1.7.14+84`
- Feature branch: `feature/wes2-set-video`

> **iOS note.** No Podfile configuration step remains. `permission_handler` has
> been removed: the `camera` plugin already prompts and reports the outcome, so
> there are no preprocessor macros to set and no permissions linked beyond the
> two this feature uses. The committed source is complete for a macOS/Xcode
> build. iOS has still never been compiled — that remains Mac-only work.

---

> **What changed since the first attempt.** Reconciliation, identity
> persistence, structural video-awareness and cleanup were not connected to the
> app at all in `1.7.14+84` as first built. They are now, so sections 4, 5, 6
> and 8 below are being exercised for the FIRST time on a device — treat them as
> the highest-risk part of this pass, not as a re-test.

## 1. Permissions

| # | Step | Expected |
|---|---|---|
| 1.1 | Fresh install, tap the camera icon on a set | Camera prompt, then microphone prompt |
| 1.2 | Grant both | Preview appears, rear camera selected |
| 1.3 | Deny camera | "Camera access needed" pane with **Open Settings** and **Not now**; workout logging still fully usable |
| 1.4 | Deny camera twice (iOS) | Permanently-denied wording, **Open Settings** opens the app's settings page |
| 1.4b | "Don't ask again" (Android) | Permanently-denied wording; **no** Open Settings button (Android has no such deep link) and the text says where to go |
| 1.4c | Restricted by parental controls (iOS) | Restricted wording, and **no** Open Settings button — Settings cannot help |
| 1.5 | Grant camera, deny microphone | Recording proceeds **silently**; the "records without sound" banner is shown |
| 1.6 | Revoke camera in Settings while the app is backgrounded, return | No crash; the permission pane appears on the next attempt |

## 2. Record, trim, save

| # | Step | Expected |
|---|---|---|
| 2.1 | Open capture | "Record the working set, then trim from the start of rep 1…" is legible **before** recording |
| 2.2 | Privacy line | "Set videos stay on this device…" visible on both capture and trim screens |
| 2.3 | Record ~30 s, stop | Trim screen opens **immediately**, no extra tap |
| 2.4 | Filmstrip | Thumbnails render across the timeline |
| 2.5 | Drag both handles | Duration readout tracks live; start cannot pass end |
| 2.6 | Tap the preview | Plays only the selected span, stops at the end handle |
| 2.7 | Trim to < 1 s | Save disabled, "Trim to at least one second" shown |
| 2.8 | Save an 8 s trim | Returns to WES2, "Set video saved", camera icon now filled |
| 2.9 | Check storage | Only the **trimmed** clip remains; no ~30 s raw file anywhere in app storage |
| 2.10 | Front/rear switch | Both preview correctly; disabled while recording |
| 2.11 | Rotate during preview and during recording | No stretch, no crash; recording continues |

## 3. Attached state

| # | Step | Expected |
|---|---|---|
| 3.1 | Tap a set that already has a video | **View / Replace / Delete** sheet — never a silent overwrite |
| 3.2 | View | Clip plays from local storage, offline |
| 3.3 | Replace, then save | New clip plays; old file gone; only one record for the set |
| 3.4 | Replace, then cancel at trim | Original clip still intact and playable |
| 3.5 | Delete | Confirm dialog names what is removed; then "Set video deleted" with **Undo** |
| 3.6 | Undo within the window | Clip returns, still playable |
| 3.7 | Delete, wait past the window, reopen the app | Clip and its poster are gone from disk |

## 4. Interruption and lifecycle

| # | Step | Expected |
|---|---|---|
| 4.1 | Incoming call mid-recording | Recording stops, partial clip offered to the trimmer, not discarded |
| 4.2 | Background mid-recording, return | Same as 4.1; camera re-initialises cleanly |
| 4.3 | Background while on the trim screen, return | Selection preserved |
| 4.4 | Force-quit mid-recording, relaunch | No orphaned raw file (startup sweep); no half-written `.part` |
| 4.5 | Open another camera app mid-recording | GoodLift recovers without a locked camera |
| 4.6 | Low storage | Failure is reported; no record written pointing at a missing file |

## 5. Set identity

| # | Step | Expected |
|---|---|---|
| 5.1 | Film set 2 of 3, then delete set 1 | The video stays on the **same performance**, now shown as set 1 |
| 5.2 | Undo that removal | Video still on its original set |
| 5.3 | Add a set after filming | New set has no video |
| 5.4 | Close and reopen the app, same date | Video still attached, **offline** |
| 5.5 | Reopen an older workout that predates the feature | No video, no crash, identity minted only when you film |
| 5.6 | Remove the exercise, undo | Video survives with its set |

## 6. Privacy — the important ones

| # | Step | Expected |
|---|---|---|
| 6.1 | Film a **non-canonical** lift (e.g. Leg Press) | **Nothing uploaded.** Check Storage and `posts` — no object, no document |
| 6.2 | Film a canonical lift that is **not** a PB | **Nothing uploaded** |
| 6.3 | Film a canonical lift that **is** a PB | After the server projection updates, the clip appears in the profile gallery **and** as proof on that lift |
| 6.4 | A set owning **both** best-E1RM and heaviest | **One** upload, one post, both record positions point at it |
| 6.5 | Film a PB, then beat it before the upload commits | Older clip stays local; not published |
| 6.6 | Delete the published PB video from the profile | Gone, and **does not come back** after backgrounding, resuming, or reconnecting |
| 6.7 | Detach from the achievement | Stays in the gallery, no longer shown as proof; wording says so |
| 6.8 | Sign out, sign in as a different account | **None** of the first account's videos are visible |

## 7. Coach mode

| # | Step | Expected |
|---|---|---|
| 7.1 | As a coach acting as an athlete, film a set on their behalf | Video stays local; **nothing** reaches the athlete's profile |
| 7.2 | Same, on a canonical lift that is a genuine PB for the athlete | Still **nothing** published |
| 7.3 | Athlete signs in themselves afterwards | Their own device governs; the coach's device publishes nothing |

## 8. Offline and upload recovery

| # | Step | Expected |
|---|---|---|
| 8.1 | Airplane mode, film a PB set | Saved locally, nothing queued that cannot be read |
| 8.2 | Restore network | Reconciliation promotes it; exactly **one** upload |
| 8.3 | Force-quit during the upload, relaunch | Resumes; no duplicate post, no duplicate Storage object |
| 8.4 | Background/resume repeatedly with a pending upload | Still exactly one post |
| 8.5 | Reconnect with several eligible clips | Each uploads once |

## 9. Size and format

| # | Step | Expected |
|---|---|---|
| 9.1 | Record a long set (2–3 min), trim tightly | Saved clip is small; raw is discarded |
| 9.2 | Record a long set and **do not** trim much | If it exceeds the 100 MB staging limit, the user is told clearly — never a silent failed upload |
| 9.3 | iPhone capture | Trimmed output is a real MP4; the Storage object's `Content-Type` is `video/mp4`; it plays on both platforms |
| 9.4 | Published proof playback | Plays the **video**, not a still — this is the 1.7.13 `thumbUrl` defect |

## 10. Accessibility and layout

| # | Step | Expected |
|---|---|---|
| 10.1 | VoiceOver / TalkBack on an empty control | "Record a video of set N" |
| 10.2 | Same on a recorded control | Announces the recorded state and the available actions |
| 10.3 | Largest system text size | Set rows still align; the camera icon is not clipped |
| 10.4 | Small phone (SE-class) | Note and camera icons both reachable, row not truncated |
| 10.5 | All three row variants — normal, timed bodyweight, timed weighted | Camera sits immediately right of the note icon in each |

---

## Known limitations to verify rather than assume

- The trim engine (`flutter_native_video_trimmer`) has **never been executed**
  in this work. Confirm on both platforms that trimming produces a playable
  clip of the expected length, and that audio is retained.
- Poster generation via `video_thumbnail` is likewise unexercised.
- Whether the camera plugin's recorded container on a given OEM Android device
  is MP4 is unverified; the pipeline preserves whatever it is, and the trimmer
  re-exports MP4.
