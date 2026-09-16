# Resume point

**Stage 1 (hints) is implemented and green. Stage 2 (durable Undo / offline
saving) is not started.**

* Worktree: `C:\Projects\RE-wes2-cascade`, branch `fix/wes2-live-hint-cascade`,
  based on `origin/main` `abdaa477` (1.7.31+101).
* Stage 1 commit: see `git log` — one commit, hints only, existing persistence
  architecture untouched.
* Review checkpoint for the implementation: **a456c075**, pushed to
  `origin/fix/wes2-live-hint-cascade`. Follow-up commit **0005959d**
  adds the acceptance-coverage map, the saved-structure-across-reload fix and
  its tests.
* Full `flutter test`: **2205 passing, 0 failing.** New suites:
  `wes2_accepted_hint_view_test` (all-model gate), `wes2_cascade_contract_test`,
  `wes2_setn_centre_test`, `wes2_display_agreement_test`,
  `wes2_field_entry_widget_test`, `wes2_hint_load_runner_test`,
  `wes2_timed_cascade_test`, `wes2_hint_structure_and_provenance_test`.
* Acceptance coverage map: PLAN.md §S1-5 (complete vs deferred, per
  requirement).
* **Release blocker:** the real `Wes2Screen` integration test — PLAN.md
  "Release". It may land with Stage 2's wiring changes.
* Two existing suites were updated with reasons recorded in PLAN.md §S1-6.
* `flutter pub get` rewrites `windows/flutter/generated_plugin*`; those are not
  part of the change and must not be committed.
* Do not touch `C:\Projects\RE-test` dirty files (`.docx`, lock file,
  `android/build/`) — not ours. A temporary `C:\Projects\RE-baseline` worktree
  was used for the analyzer baseline; remove it when done.

**Next step — Stage 2**, kept separately reviewable. Scope is limited to the
reproduced failures in PROBES.md, each with a named regression:

1. `R-UNDO` — deletion Undo is not durable (server reload still shows the set
   removed).
2. `probe5` — an edit to a later set is lost when an earlier set is removed
   (`[50,70]` instead of `[50,100]`).
3. `P6a` — two removals at the same compacted index: neither reaches the
   server.
4. `P6b` — a removal waiting out a backoff is overtaken by a later edit.
5. `P6c` — an old in-flight acknowledgement deletes a newer queued value.
6. `R-SEQ` — removal ids repeat across screen visits, so one removal is lost.
7. `R-MEDIA` — a zero-window video deletion purges footage whose structural
   Undo is still offered.
8. `R-SETID` — `saveSetId` ignores its injected Firestore instance.

The v6.1 persistence protocol in PLAN.md §8–§12 is **not approved for
implementation as written**: use it as background only, take the smallest
repair per failure above, and record any scenario whose minimal fix is not yet
worked out for review rather than inventing mechanism.
