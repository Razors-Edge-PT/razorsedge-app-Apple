#!/usr/bin/env node
'use strict';

// ONE-TIME identity audit + repair across every GoodLift account.
//
// Establishes, for each uid seen in Auth / users / users_public /
// userSearchIndex / usernames / leaderboard entries, whether the canonical
// identity contract holds:
//
//   users/{uid}         username, usernameLower
//   users_public/{uid}  username, usernameLower, displayName (= username)
//   usernames/{sha256(usernameLower)}  { uid, username, usernameLower }
//
// and repairs ONLY accounts whose username is recoverable deterministically
// (identity/username_rules.js validation + normalisation, the reservation
// index for uniqueness). Everything else is reported, never written.
//
// Candidate precedence (spec): a reservation the uid already owns →
// users_public.username → users.username → a legacy displayName that passes
// the username rules → the Auth displayName ONLY as corroboration. Valid
// sources that disagree are a conflict. A name held by another uid, a
// contested marker, or claimed by another account is a collision. Google
// profile names, email prefixes, names with spaces and fullName are never
// promoted. No username is ever generated.
//
// Writes go through one transaction per account that re-reads everything and
// re-plans; if the fresh plan differs from the reviewed one it aborts. The
// Auth displayName is updated only after that transaction commits. Derived
// data is left to the deployed triggers (identity reconciler, search index,
// leaderboard identity refresh); historical leaderboard months get an
// identity-only field update for repaired accounts — never a rescore.
//
//   node scripts/repair_identities_once.js                 dry run (default)
//   node scripts/repair_identities_once.js --apply         backup, then repair
//   node scripts/repair_identities_once.js --report <file> write the full JSON report

const fs = require('fs');
const os = require('os');
const path = require('path');

const R = require('../identity/username_rules');

const PROJECT_ID = 'goodlift-us-storage';
const BACKUP_ROOT = path.join(os.homedir(), 'GoodLift-migration-backups');

/** Accounts that are only ever reported (test / store-review accounts). */
const REPORT_ONLY = Object.freeze({
  q7ySehVw1se41vVok94V35PnGHM2: 'store-review test account (AppleReviewer)',
});

// ── Pure planning (unit-tested) ─────────────────────────────────────────────

const str = (v) => (typeof v === 'string' && v.trim() ? v.trim() : null);

/**
 * Plans one account.
 *
 * @param {object} ev
 * @param {string} ev.uid
 * @param {object|null} ev.priv    users/{uid}
 * @param {object|null} ev.pub     users_public/{uid}
 * @param {object|null} ev.auth    { displayName, email, providers: [{providerId, displayName}] }
 * @param {Array} ev.owned         reservations whose uid is this uid: [{key, username, usernameLower}]
 * @param {(lower:string)=>object|null} ev.reservationAt   the reservation doc at a key, or null
 * @param {(lower:string)=>string[]} ev.claimants          uids whose users/users_public username normalises to lower
 * @param {string|null} [ev.reportOnly]                    reason, when the account is report-only
 * @returns {{status:'ok'|'repair'|'unresolved', reason?:string, username?:string, usernameLower?:string, repairs?:object, notes:string[]}}
 */
function planAccount(ev) {
  const notes = [];
  const unresolved = (reason) => ({ status: 'unresolved', reason, notes });
  if (!ev.priv || !ev.pub) {
    return unresolved(`missing ${!ev.priv && !ev.pub ? 'users and users_public documents' : !ev.priv ? 'users document' : 'users_public document'} (onboarding incomplete; profiles are never created here)`);
  }

  // 1–3: established sources.
  const strong = [];
  const invalidStrong = [];
  for (const r of ev.owned) {
    const name = str(r.username) || str(r.usernameLower);
    if (name && R.validateUsername(name).ok) strong.push({ src: 'reservation', name });
    else invalidStrong.push('reservation');
  }
  for (const [src, doc] of [['users_public.username', ev.pub], ['users.username', ev.priv]]) {
    const name = str(doc.username);
    if (!name) continue;
    if (R.validateUsername(name).ok) strong.push({ src, name });
    else invalidStrong.push(src);
  }
  if (invalidStrong.length) return unresolved(`invalid stored username in ${invalidStrong.join(', ')}`);

  let candidate = null;
  const lowers = new Set(strong.map((s) => R.normalizeUsername(s.name)));
  if (lowers.size > 1) {
    return unresolved(`conflicting usernames: ${strong.map((s) => `${s.src}=${s.name}`).join(', ')}`);
  }
  if (lowers.size === 1) {
    candidate = strong[0]; // precedence order preserved above
    // More than one reservation for the same name cannot exist (same key).
  } else {
    // 4: legacy displayName, only when it passes the username rules and is
    // not a name the account merely inherited from Google or its email.
    const emailPrefix = ev.auth && typeof ev.auth.email === 'string'
      ? ev.auth.email.split('@')[0].trim().toLowerCase() : null;
    const googleNames = new Set(((ev.auth && ev.auth.providers) || [])
      .filter((p) => p.providerId === 'google.com' && str(p.displayName))
      .map((p) => R.normalizeUsername(p.displayName)));
    const legacy = [];
    for (const [src, doc] of [['users_public.displayName', ev.pub], ['users.displayName', ev.priv]]) {
      const name = str(doc.displayName);
      if (!name) continue;
      const lower = R.normalizeUsername(name);
      if (!R.validateUsername(name).ok) { notes.push(`${src} "${name}" fails username rules`); continue; }
      if (name.includes('@') || (emailPrefix && lower === emailPrefix)) { notes.push(`${src} is the email prefix — not promoted`); continue; }
      if (googleNames.has(lower)) { notes.push(`${src} "${name}" is the Google profile name — not an established username`); continue; }
      legacy.push({ src, name });
    }
    const legacyLowers = new Set(legacy.map((s) => R.normalizeUsername(s.name)));
    if (legacyLowers.size > 1) {
      return unresolved(`conflicting legacy displayNames: ${legacy.map((s) => `${s.src}=${s.name}`).join(', ')}`);
    }
    if (legacyLowers.size === 1) candidate = legacy[0];
  }

  // 5: Auth displayName — corroboration only, never a source on its own.
  const authName = ev.auth ? str(ev.auth.displayName) : null;
  if (!candidate) {
    if (authName && R.validateUsername(authName).ok) {
      return unresolved(`only the Auth displayName "${authName}" — not an established username`);
    }
    return unresolved('no valid username evidence (names with spaces, fullName and email are never promoted)');
  }
  if (candidate.src.endsWith('displayName') && authName && R.validateUsername(authName).ok &&
      R.normalizeUsername(authName) !== R.normalizeUsername(candidate.name)) {
    return unresolved(`legacy displayName "${candidate.name}" disagrees with Auth displayName "${authName}"`);
  }

  if (ev.reportOnly) return unresolved(`report-only: ${ev.reportOnly} (candidate "${candidate.name}")`);

  const username = R.displayUsername(candidate.name);
  const usernameLower = R.normalizeUsername(candidate.name);

  // Uniqueness: the reservation and every other account's stored claim.
  const held = ev.reservationAt(usernameLower);
  if (held && held.uid !== ev.uid) {
    return unresolved(held.uid ? `username "${username}" is reserved by another account (${held.uid})` : `username "${username}" is a contested reservation marker`);
  }
  const others = ev.claimants(usernameLower).filter((u) => u !== ev.uid);
  if (others.length) return unresolved(`username "${username}" is also claimed by ${others.join(', ')}`);

  // Repairs: only fields that differ.
  const priv = {};
  if (ev.priv.username !== username) priv.username = username;
  if (ev.priv.usernameLower !== usernameLower) priv.usernameLower = usernameLower;
  const pub = {};
  if (ev.pub.username !== username) pub.username = username;
  if (ev.pub.usernameLower !== usernameLower) pub.usernameLower = usernameLower;
  if (ev.pub.displayName !== username) pub.displayName = username;
  let reservation = null;
  if (!held) reservation = 'create';
  else if (held.username !== username || held.usernameLower !== usernameLower) reservation = 'update';
  const release = ev.owned.filter((r) => R.normalizeUsername(r.usernameLower || r.username || '') !== usernameLower).map((r) => r.key);
  const usernameChanged = Object.keys(priv).length > 0 || 'username' in pub || 'usernameLower' in pub || reservation !== null;
  const auth = usernameChanged && ev.auth && authName !== username ? username : null;

  const repairs = { priv, pub, reservation, release, auth };
  const empty = !Object.keys(priv).length && !Object.keys(pub).length && !reservation && !release.length && !auth;
  if (candidate.src !== 'reservation' && candidate.src !== 'users_public.username') notes.push(`username from ${candidate.src}`);
  return { status: empty ? 'ok' : 'repair', username, usernameLower, source: candidate.src, repairs: empty ? null : repairs, notes };
}

/** Stable JSON for the reviewed-vs-fresh plan comparison. */
function planKey(plan) {
  return JSON.stringify({ s: plan.status, u: plan.username || null, r: plan.repairs || null });
}

function toBackupJson(v) {
  if (v === null || typeof v !== 'object') return v;
  if (typeof v.toMillis === 'function') return { __timestamp: new Date(v.toMillis()).toISOString(), millis: v.toMillis() };
  if (Array.isArray(v)) return v.map(toBackupJson);
  const o = {};
  for (const k of Object.keys(v)) o[k] = toBackupJson(v[k]);
  return o;
}

// ── Firestore / Auth I/O ────────────────────────────────────────────────────

async function loadAll(admin, db, counts) {
  const col = async (name) => {
    const s = await db.collection(name).get();
    counts.reads += Math.max(1, s.size);
    return new Map(s.docs.map((d) => [d.id, d.data()]));
  };
  const auth = new Map();
  let token;
  do {
    const page = await admin.auth().listUsers(1000, token);
    counts.authReads += 1;
    for (const u of page.users) auth.set(u.uid, u);
    token = page.pageToken;
  } while (token);
  const users = await col('users');
  const pub = await col('users_public');
  const search = await col('userSearchIndex');
  const reservations = await col('usernames');
  const entries = new Map();
  const boards = await db.collection('leaderboards').get();
  counts.reads += Math.max(1, boards.size);
  for (const b of boards.docs) {
    const es = await b.ref.collection('entries').get();
    counts.reads += Math.max(1, es.size);
    for (const e of es.docs) {
      if (!entries.has(e.id)) entries.set(e.id, []);
      entries.get(e.id).push({ period: b.id, data: e.data() });
    }
  }
  return { auth, users, pub, search, reservations, entries };
}

function authEvidence(u) {
  if (!u) return null;
  return {
    displayName: u.displayName || null,
    email: u.email || null,
    disabled: !!u.disabled,
    providers: (u.providerData || []).map((p) => ({ providerId: p.providerId, displayName: p.displayName || null })),
  };
}

function buildIndex(all) {
  const byKey = all.reservations;
  const owned = new Map();
  for (const [key, r] of byKey) {
    if (!r || !r.uid) continue;
    if (!owned.has(r.uid)) owned.set(r.uid, []);
    owned.get(r.uid).push({ key, username: r.username || null, usernameLower: r.usernameLower || null });
  }
  const claims = new Map();
  const claim = (uid, name) => {
    const n = str(name);
    if (!n) return;
    const lower = R.normalizeUsername(n);
    if (!claims.has(lower)) claims.set(lower, new Set());
    claims.get(lower).add(uid);
  };
  for (const [uid, d] of all.users) claim(uid, d.username);
  for (const [uid, d] of all.pub) claim(uid, d.username);
  return {
    owned: (uid) => owned.get(uid) || [],
    reservationAt: (lower) => byKey.get(R.usernameIndexKey(lower)) || null,
    claimants: (lower) => [...(claims.get(lower) || [])],
  };
}

function evidenceFor(uid, all, idx) {
  return {
    uid,
    priv: all.users.get(uid) || null,
    pub: all.pub.get(uid) || null,
    auth: authEvidence(all.auth.get(uid)),
    owned: idx.owned(uid),
    reservationAt: idx.reservationAt,
    claimants: idx.claimants,
    reportOnly: REPORT_ONLY[uid] || null,
  };
}

function describe(uid, all, plan) {
  const u = all.users.get(uid);
  const p = all.pub.get(uid);
  const a = all.auth.get(uid);
  const s = all.search.get(uid);
  const en = all.entries.get(uid) || [];
  const at = en.find((e) => e.period === 'all_time');
  return {
    uid,
    status: plan.status,
    reason: plan.reason || null,
    username: plan.username || null,
    source: plan.source || null,
    repairs: plan.repairs || null,
    notes: plan.notes,
    auth: a ? { exists: true, disabled: !!a.disabled, displayName: a.displayName || null, providers: (a.providerData || []).map((x) => x.providerId), created: a.metadata.creationTime, lastSignIn: a.metadata.lastSignInTime } : { exists: false },
    users: u ? { username: u.username ?? null, usernameLower: u.usernameLower ?? null, displayName: u.displayName ?? null } : null,
    users_public: p ? { username: p.username ?? null, usernameLower: p.usernameLower ?? null, displayName: p.displayName ?? null, fullName: p.fullName ?? null } : null,
    searchIndex: s ? { username: s.username || null, displayName: s.displayName || null } : null,
    reservationsOwned: [...all.reservations.entries()].filter(([, r]) => r.uid === uid).map(([, r]) => r.username),
    leaderboard: { entries: en.length, allTimePoints: at ? at.data.totalPointsUnits / 10000 : null, names: [...new Set(en.map((e) => e.data.username ?? null))] },
  };
}

async function applyAccount(admin, db, uid, reviewed, counts) {
  const idx = await db.runTransaction(async (tx) => {
    const userRef = db.collection('users').doc(uid);
    const pubRef = db.collection('users_public').doc(uid);
    const [us, ps] = await Promise.all([tx.get(userRef), tx.get(pubRef)]);
    const ownedSnap = await tx.get(db.collection('usernames').where('uid', '==', uid).limit(20));
    const resRef = db.collection('usernames').doc(R.usernameIndexKey(reviewed.usernameLower));
    const rs = await tx.get(resRef);
    counts.reads += 3 + Math.max(1, ownedSnap.size);
    const fresh = planAccount({
      uid,
      priv: us.exists ? us.data() : null,
      pub: ps.exists ? ps.data() : null,
      auth: reviewed.authEvidence,
      owned: ownedSnap.docs.map((d) => ({ key: d.id, username: d.get('username') || null, usernameLower: d.get('usernameLower') || null })),
      reservationAt: (lower) => (lower === reviewed.usernameLower ? (rs.exists ? rs.data() : null) : null),
      claimants: reviewed.claimants,
      reportOnly: null,
    });
    if (planKey(fresh) !== planKey(reviewed.plan)) {
      throw new Error(`plan for ${uid} changed since the dry run — skipped`);
    }
    const r = reviewed.plan.repairs;
    const now = admin.firestore.FieldValue.serverTimestamp();
    if (r.reservation) {
      tx.set(resRef, { uid, username: reviewed.plan.username, usernameLower: reviewed.plan.usernameLower, updatedAt: now }, { merge: true });
      counts.writes += 1;
    }
    for (const key of r.release) {
      tx.delete(db.collection('usernames').doc(key));
      counts.writes += 1;
    }
    if (Object.keys(r.priv).length) { tx.set(userRef, r.priv, { merge: true }); counts.writes += 1; }
    if (Object.keys(r.pub).length) { tx.set(pubRef, r.pub, { merge: true }); counts.writes += 1; }
    return true;
  });
  let authUpdated = false;
  if (idx && reviewed.plan.repairs.auth) {
    try {
      await admin.auth().updateUser(uid, { displayName: reviewed.plan.repairs.auth });
      counts.authWrites += 1;
      authUpdated = true;
    } catch (err) {
      process.stdout.write(`  ! Auth displayName not updated for ${uid}: ${err.message}\n`);
    }
  }
  return authUpdated;
}

async function main() {
  const args = process.argv.slice(2);
  const applyMode = args.includes('--apply');
  const reportIdx = args.indexOf('--report');
  const reportPath = reportIdx >= 0 ? args[reportIdx + 1] : null;
  for (const a of args) if (!['--apply', '--report', reportPath].includes(a)) throw new Error(`Unknown argument: ${a}`);

  const admin = require('firebase-admin');
  admin.initializeApp({ projectId: PROJECT_ID });
  const db = admin.firestore();
  const counts = { reads: 0, writes: 0, authReads: 0, authWrites: 0 };
  const all = await loadAll(admin, db, counts);
  const idx = buildIndex(all);
  const uids = new Set([...all.auth.keys(), ...all.users.keys(), ...all.pub.keys(), ...all.search.keys(), ...all.entries.keys()]);
  for (const r of all.reservations.values()) if (r && r.uid) uids.add(r.uid);

  const results = [];
  for (const uid of [...uids].sort()) {
    const ev = evidenceFor(uid, all, idx);
    const plan = planAccount(ev);
    results.push({ uid, plan, ev, row: describe(uid, all, plan) });
  }
  const w = (s) => process.stdout.write(`${s}\n`);
  const by = (st) => results.filter((r) => r.plan.status === st);
  const onlyIn = results.filter((r) => {
    const n = [all.auth.has(r.uid), all.users.has(r.uid), all.pub.has(r.uid)].filter(Boolean).length;
    return n < 3;
  });
  w(`Identity audit — mode: ${applyMode ? 'APPLY' : 'dry-run'}`);
  w(`Accounts audited: ${results.length} (Auth ${all.auth.size}, users ${all.users.size}, users_public ${all.pub.size}, userSearchIndex ${all.search.size}, usernames ${all.reservations.size}, leaderboard uids ${all.entries.size})`);
  w(`Consistent: ${by('ok').length}   To repair: ${by('repair').length}   Unresolved: ${by('unresolved').length}`);
  w(`Present in fewer than all of Auth/users/users_public: ${onlyIn.length}`);
  w('\nREPAIRS');
  for (const r of by('repair')) {
    const rp = r.plan.repairs;
    const parts = [];
    if (Object.keys(rp.priv).length) parts.push(`users{${Object.keys(rp.priv).join(',')}}`);
    if (Object.keys(rp.pub).length) parts.push(`users_public{${Object.keys(rp.pub).join(',')}}`);
    if (rp.reservation) parts.push(`reservation ${rp.reservation}`);
    if (rp.release.length) parts.push(`release ${rp.release.length} stale`);
    if (rp.auth) parts.push('Auth displayName');
    w(`  ${r.uid}  → "${r.plan.username}" (from ${r.plan.source}): ${parts.join('; ')}`);
  }
  w('\nUNRESOLVED');
  for (const r of by('unresolved')) {
    const lb = r.row.leaderboard.entries ? ` [leaderboard ${r.row.leaderboard.entries} entries, all-time ${r.row.leaderboard.allTimePoints}]` : '';
    w(`  ${r.uid}${lb}: ${r.plan.reason}`);
  }
  if (reportPath) {
    fs.writeFileSync(reportPath, JSON.stringify({ at: new Date().toISOString(), mode: applyMode ? 'apply' : 'dry-run', counts, accounts: results.map((r) => r.row) }, null, 2));
    w(`\nFull report: ${reportPath}`);
  }
  if (!applyMode) {
    w(`\nReads: Firestore ${counts.reads}, Auth list pages ${counts.authReads}. Dry run — nothing written.`);
    return;
  }

  // Backup every document a repair touches, BEFORE any write.
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const dir = path.join(BACKUP_ROOT, `${stamp}_identity-repair`);
  fs.mkdirSync(dir, { recursive: true });
  const backup = [];
  for (const r of by('repair')) {
    const rp = r.plan.repairs;
    backup.push({ path: `users/${r.uid}`, data: toBackupJson(all.users.get(r.uid) || null) });
    backup.push({ path: `users_public/${r.uid}`, data: toBackupJson(all.pub.get(r.uid) || null) });
    const key = R.usernameIndexKey(r.plan.usernameLower);
    backup.push({ path: `usernames/${key}`, data: toBackupJson(all.reservations.get(key) || null) });
    for (const k of rp.release) backup.push({ path: `usernames/${k}`, data: toBackupJson(all.reservations.get(k) || null) });
    backup.push({ path: `auth/${r.uid}#displayName`, data: all.auth.get(r.uid) ? all.auth.get(r.uid).displayName || null : null });
    for (const e of all.entries.get(r.uid) || []) backup.push({ path: `leaderboards/${e.period}/entries/${r.uid}`, data: toBackupJson(e.data) });
  }
  fs.writeFileSync(path.join(dir, 'documents.json'), JSON.stringify(backup, null, 2));
  fs.writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify({
    createdAt: new Date().toISOString(), project: PROJECT_ID, script: 'functions/scripts/repair_identities_once.js',
    repairs: by('repair').map((r) => ({ uid: r.uid, username: r.plan.username, source: r.plan.source, repairs: r.plan.repairs })),
    unresolved: by('unresolved').map((r) => ({ uid: r.uid, reason: r.plan.reason })),
    documents: backup.map((b) => b.path),
  }, null, 2));
  if (JSON.parse(fs.readFileSync(path.join(dir, 'documents.json'), 'utf8')).length !== backup.length) throw new Error('backup verification failed');
  w(`\nBackup written: ${dir}`);

  const repaired = [];
  for (const r of by('repair')) {
    try {
      const authUpdated = await applyAccount(admin, db, r.uid, {
        plan: r.plan, usernameLower: r.plan.usernameLower, authEvidence: r.ev.auth, claimants: idx.claimants,
      }, counts);
      repaired.push(r.uid);
      w(`  repaired ${r.uid} → "${r.plan.username}"${authUpdated ? ' (+Auth)' : ''}`);
    } catch (err) {
      w(`  ! ${r.uid}: ${err.message}`);
    }
  }
  // Identity-only refresh of EVERY leaderboard entry of a repaired account
  // (the deployed trigger covers the current month and all-time; closed
  // months are refreshed here). Only username/photoURL — never points.
  const { identityOf } = require('../leaderboard/reducer');
  let entriesRefreshed = 0;
  for (const uid of repaired) {
    const pubSnap = await db.collection('users_public').doc(uid).get();
    counts.reads += 1;
    const id = identityOf(pubSnap.exists ? pubSnap.data() : null);
    for (const e of all.entries.get(uid) || []) {
      const ref = db.collection('leaderboards').doc(e.period).collection('entries').doc(uid);
      const cur = await ref.get();
      counts.reads += 1;
      if (!cur.exists) continue;
      if (cur.get('username') === id.username && (cur.get('photoURL') ?? null) === id.photoURL) continue;
      await ref.update({ username: id.username, photoURL: id.photoURL });
      counts.writes += 1;
      entriesRefreshed += 1;
    }
  }
  w(`Leaderboard entries identity-refreshed: ${entriesRefreshed}`);
  fs.writeFileSync(path.join(dir, 'applied.json'), JSON.stringify({ at: new Date().toISOString(), repaired, entriesRefreshed, counts }, null, 2));
  w(`\nApplied ${repaired.length}/${by('repair').length}. Firestore reads ${counts.reads}, writes ${counts.writes}; Auth list pages ${counts.authReads}, Auth writes ${counts.authWrites}.`);
}

if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(`${err && err.stack ? err.stack : err}\n`);
    process.exit(1);
  });
}

module.exports = { planAccount, planKey, REPORT_ONLY, toBackupJson };
