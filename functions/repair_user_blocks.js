/**
 * One-off diagnose/repair for a user stuck with no ACTIVE training block
 * (log signature: "No active block found for user <uid>").
 *
 * Usage (from /functions, needs serviceAccountKey.json like update_meghan_auth.js):
 *   node repair_user_blocks.js <uid>            # dry-run: prints state + planned fixes
 *   node repair_user_blocks.js <uid> --apply    # applies the fixes
 *
 * What it can fix (all idempotent, metadata-only — never deletes or touches
 * workouts, completed sets, weeks, or exercise settings):
 *   1. Blocks exist but none has isActive=true  → activates the date-correct one.
 *   2. Bootstrap templates with a missing/stale blockId → re-links B1→active,
 *      B2/B3→upcoming blocks (mirror of the app's TemplatesBootstrapper repair).
 *   3. templatesBootstrapped_v1 flag set but ZERO templates → clears the flag so
 *      the app's bootstrapper recreates them on next load.
 *
 * What it deliberately does NOT do: create blocks when none exist. Block
 * creation seeds exercise settings/scaffolds from production Dart code — use
 * the in-app repair instead (select the athlete → Workout Planner → "Repair
 * training setup"), which reuses that exact code path.
 */

const admin = require("firebase-admin");
const serviceAccount = require("./serviceAccountKey.json");

admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
const db = admin.firestore();

const uid = process.argv[2];
const apply = process.argv.includes("--apply");

if (!uid || uid.startsWith("--")) {
  console.error("Usage: node repair_user_blocks.js <uid> [--apply]");
  process.exit(1);
}

function toDate(v) {
  if (!v) return null;
  if (typeof v.toDate === "function") return v.toDate();
  return null;
}

function fmt(d) {
  return d ? d.toISOString().slice(0, 10) : "null";
}

// Same preference order as the app's BlockRepairService.chooseBlockToActivate:
// covering today (latest start wins) > earliest upcoming > latest past > first.
function chooseBlockToActivate(blocks, now) {
  let covering = null, upcoming = null, past = null;
  for (const b of blocks) {
    const s = b.start, e = b.end;
    if (s && e && now >= s && now <= e) {
      if (!covering || s > covering.start) covering = b;
      continue;
    }
    if (s && s > now) {
      if (!upcoming || s < upcoming.start) upcoming = b;
      continue;
    }
    if (e && e < now) {
      if (!past || e > past.end) past = b;
    }
  }
  return covering || upcoming || past || blocks[0] || null;
}

async function run() {
  console.log(`\n=== Repair diagnosis for uid=${uid} (${apply ? "APPLY" : "DRY-RUN"}) ===\n`);

  // ── 1. User doc ────────────────────────────────────────────────────────────
  const userRef = db.collection("users").doc(uid);
  const userSnap = await userRef.get();
  const u = userSnap.data() || {};
  console.log(`users/${uid} exists=${userSnap.exists}`);
  console.log(`  username=${u.username ?? "null"} fullName=${u.fullName ?? "null"}`);
  console.log(`  sex=${u.sex ?? "null"} dob=${u.dob ?? "null"} email=${u.email ?? "null"}`);
  console.log(`  templatesBootstrapped_v1=${u.templatesBootstrapped_v1 === true}`);
  console.log(`  templatesBranch=${u.templatesBranch ?? "null"}\n`);

  // ── 2. Blocks ──────────────────────────────────────────────────────────────
  const blocksCol = db.collection("users").doc(uid).collection("planned_blocks");
  const blocksSnap = await blocksCol.get();
  const blocks = blocksSnap.docs.map((d) => ({
    id: d.id,
    ref: d.ref,
    name: d.data().name,
    isActive: d.data().isActive === true,
    start: toDate(d.data().startDate),
    end: toDate(d.data().endDate),
  }));
  console.log(`users/${uid}/planned_blocks: ${blocks.length} doc(s)`);
  for (const b of blocks) {
    console.log(`  ${b.id} active=${b.isActive} start=${fmt(b.start)} end=${fmt(b.end)} name="${b.name}"`);
  }

  const activeBlocks = blocks.filter((b) => b.isActive);
  let activeId = activeBlocks[0] ? activeBlocks[0].id : null;

  // ── 3. Templates ───────────────────────────────────────────────────────────
  const templatesCol = userRef.collection("templates");
  const tSnap = await templatesCol.get();
  console.log(`\nusers/${uid}/templates: ${tSnap.size} doc(s)`);
  for (const d of tSnap.docs) {
    const t = d.data();
    console.log(`  ${d.id} name="${t.name}" blockAssignment=${t.blockAssignment ?? "null"} blockId=${t.blockId ?? "null"}`);
  }

  // ── 4. Fix 1: activate a block if none is active ───────────────────────────
  const fixes = [];
  if (blocks.length === 0) {
    console.log("\n⚠️  NO BLOCKS EXIST. This script will not create them.");
    console.log("    → In the app: select this athlete → Workout Planner → 'Repair training setup'.");
  } else if (!activeId) {
    const chosen = chooseBlockToActivate(blocks, new Date());
    fixes.push({
      desc: `Set isActive=true on block ${chosen.id} ("${chosen.name}", ${fmt(chosen.start)} → ${fmt(chosen.end)})`,
      run: () => chosen.ref.update({ isActive: true }),
    });
    activeId = chosen.id;
  } else if (activeBlocks.length > 1) {
    console.log(`\n⚠️  ${activeBlocks.length} blocks are active — inspect manually (script won't guess which to keep).`);
  } else {
    console.log(`\n✅ Active block already set: ${activeId}`);
  }

  // ── 5. Fix 2: re-link bootstrap templates with missing/stale blockId ──────
  if (activeId && tSnap.size > 0) {
    const upcoming = blocks
      .filter((b) => b.id !== activeId)
      .sort((a, b) => (a.start && b.start ? a.start - b.start : a.start ? -1 : 1));
    const assignToId = { B1: activeId };
    upcoming.forEach((b, i) => { assignToId[`B${i + 2}`] = b.id; });
    const validIds = new Set(blocks.map((b) => b.id));

    for (const d of tSnap.docs) {
      const t = d.data();
      const assign = (t.blockAssignment || "").trim();
      if (!assign || !assignToId[assign]) continue; // not a bootstrap template
      const existing = (t.blockId || "").trim();
      if (existing && validIds.has(existing)) continue; // already valid
      fixes.push({
        desc: `Template "${t.name}" (${assign}): blockId "${existing || "null"}" → ${assignToId[assign]}`,
        run: () => d.ref.update({ blockId: assignToId[assign] }),
      });
    }
  }

  // ── 6. Fix 3: flag set but zero templates → clear flag so app recreates ───
  if (tSnap.size === 0 && u.templatesBootstrapped_v1 === true) {
    fixes.push({
      desc: "Clear templatesBootstrapped_v1 (flag set but 0 templates) so the app recreates them",
      run: () => userRef.set(
        { templatesBootstrapped_v1: admin.firestore.FieldValue.delete() },
        { merge: true }
      ),
    });
  }

  // ── 7. Apply / report ──────────────────────────────────────────────────────
  console.log(`\n=== Planned fixes: ${fixes.length} ===`);
  fixes.forEach((f, i) => console.log(`  ${i + 1}. ${f.desc}`));

  if (!apply) {
    console.log("\nDry-run only. Re-run with --apply to execute.");
    return;
  }
  for (const f of fixes) {
    await f.run();
    console.log(`✅ Applied: ${f.desc}`);
  }
  console.log("\nDone. Have the user (or coach acting as the user) reopen the app;");
  console.log("templates are (re)created by the flag-guarded in-app bootstrapper.");
}

run().catch((e) => {
  console.error("Repair failed:", e);
  process.exit(1);
});
