import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'coach_mode/coach_mode_models.dart';
import 'coach_mode/coach_mode_role_watcher.dart';
import 'coach_mode/coach_mode_service.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'app_check_ready.dart';
import 'coach_roster.dart';
import 'coach_weekly_review_screen.dart';

String emailHash(String email) {
  final lower = email.trim().toLowerCase();
  return sha256.convert(utf8.encode(lower)).toString();
}

Future<void> upsertUserLookup() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null || user.email == null) return;

  // Sequence behind App Check activation (settles even on failure/timeout).
  await appCheckReady;

  final hash = emailHash(user.email!);
  await FirebaseFirestore.instance
      .collection('user_lookup')
      .doc(hash)
      .set({
    'uid': user.uid,
    'displayName': user.displayName ?? '', // ✅ store here
  }, SetOptions(merge: true));
  debugPrint('✅ [upsertUserLookup] Lookup saved for ${user.email}');
}


class CoachHomeScreen extends StatefulWidget {
  const CoachHomeScreen({super.key});

  @override
  State<CoachHomeScreen> createState() => _CoachHomeScreenState();
}

class _CoachHomeScreenState extends State<CoachHomeScreen>
    with CoachModeRoleWatcher<CoachHomeScreen> {
  Map<String, dynamic> _athletes = {};
  String _search = '';

  // Canonical pending invitations (coachAthleteLinks with status 'pending').
  // These are NOT roster entries — a pending invitation grants no access — so
  // they are held separately from _athletes and rendered as their own section.
  List<CoachAthleteLink> _pending = const [];
  // Athlete UIDs that come only from the LEGACY super-admin-seeded roster.
  // Removal for these goes through the removal-only seeded callable rather
  // than the canonical release path.
  Set<String> _seededOnlyUids = {};

  final CoachModeService _coachMode = CoachModeService();
  bool _busy = false;

  @override
  void dispose() {
    disposeRoleWatcher();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Binding happens in CoachModeRoleWatcher.didChangeDependencies, which
    // re-runs whenever the provided UserContext INSTANCE changes.
  }

  /// The bound context has Coach Mode — (re)load its roster.
  @override
  void onCoachModeBound(UserContext userContext) {
    _loadAthletes(userContext);
  }

  /// The bound context has NO Coach Mode: on first bind, on a rebind to a
  /// replacement context that already carries a suspension, or on a live
  /// suspension/revocation.
  @override
  void onCoachModeRevoked({required bool duringBind}) {
    // Drop any roster already on screen so no athlete data survives the frames
    // before the pop lands. build() also fails closed independently.
    if (mounted && !duringBind) {
      setState(() {
        _athletes = {};
        _pending = const [];
        _seededOnlyUids = {};
      });
    } else {
      _athletes = {};
      _pending = const [];
      _seededOnlyUids = {};
    }
    _ejectAfterFrame(duringBind
        ? 'Access denied — only coaches can open this screen.'
        : 'Coach Mode is no longer active on this account.');
  }

  /// Leaves the dashboard once the current frame is done. Navigator and
  /// ScaffoldMessenger cannot be used during didChangeDependencies/build.
  void _ejectAfterFrame(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      Navigator.of(context).maybePop();
    });
  }




  Future<void> _loadAthletes(UserContext userContext) async {
    // Roster loading lives in CoachRosterService so this screen and the Coach
    // Check-ins screens always resolve the same athletes (super-admin => all
    // users; ordinary coach => active canonical links + legacy approved and
    // super-admin-seeded assignments).
    try {
      final roster = await CoachRosterService().loadRoster(userContext);
      if (!mounted) return;
      setState(() {
        _athletes = {
          for (final a in roster) a.uid: a.toLegacyMap(),
        };
      });
      debugPrint('✅ Loaded ${roster.length} athletes for ${userContext.actorUid}');
    } catch (e) {
      debugPrint("❌ Error loading athletes: $e");
    }

    await Future.wait([
      _loadPendingInvitations(userContext.actorUid),
      _loadSeededOnlyUids(userContext.actorUid),
    ]);
  }

  /// Pending invitations this coach has sent and the athlete has not yet
  /// answered. Read-only here; every change goes through a callable.
  Future<void> _loadPendingInvitations(String coachUid) async {
    try {
      final links = await _coachMode.watchCoachLinks(coachUid).first;
      if (!mounted) return;
      setState(() => _pending = splitCoachRoster(links).pending);
    } catch (e) {
      debugPrint('⚠️ [CoachHome] pending invitations load failed: $e');
    }
  }

  /// LEGACY: which roster entries exist only because the super admin seeded
  /// them. Drives which removal callable the delete action uses.
  Future<void> _loadSeededOnlyUids(String coachUid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('coachAssignments')
          .doc(coachUid)
          .get();
      final seeded = Map<String, dynamic>.from(doc.data()?['athletes'] ?? {});
      if (!mounted) return;
      setState(() => _seededOnlyUids = seeded.keys.toSet());
    } catch (e) {
      // A coach with no seeded roster simply has none; this is not an error.
      debugPrint('ℹ️ [CoachHome] seeded roster read: $e');
    }
  }

  Future<void> _refresh() async {
    final uc = UserContext.maybeOf(context);
    if (uc != null) await _loadAthletes(uc);
  }



  Future<void> _adminSeedAthleteToCoach({
    required String coachUid,
    required String athleteEmail,
  }) async {
    try {
      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('email', isEqualTo: athleteEmail.trim().toLowerCase())
          .limit(1)
          .get();

      if (q.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No user found for $athleteEmail')),
        );
        return;
      }

      final athleteDoc = q.docs.first;
      final athleteUid = athleteDoc.id;
      final email = (athleteDoc.data()['email'] ?? athleteEmail).toString();

      await FirebaseFirestore.instance
          .collection('coachAssignments')
          .doc(coachUid)
          .set({
        'athletes': {
          athleteUid: {'email': email},
        }
      }, SetOptions(merge: true));
// ✅ Debug print to confirm assignment
      print('✅ [ADMIN SEED] Athlete "$email" ($athleteUid) assigned to coach "$coachUid"');
      if (mounted) {
        setState(() {
          if (context.read<UserContext>().actorUid == coachUid) {
            final data = athleteDoc.data();
            _athletes[athleteUid] = {
              'email'       : email,
              'username'    : (data['username'] ?? '') as String,
              'displayName' : (data['displayName'] ?? '') as String,
              'fullName'    : (data['fullName'] ?? '') as String,
            };
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added $email to coach $coachUid')),
        );
      }
    } catch (e) {
      debugPrint('❌ Admin seed failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to add athlete')),
        );
      }
    }
  }


  // ---------- Invite an athlete by exact email ----------
  // Goes through coachModeInviteAthlete: the server resolves the account,
  // enforces the coach's active entitlement, rejects self-invites and
  // duplicates, rate-limits, and creates the pending link. The client cannot
  // create a relationship itself.
  Future<void> _inviteAthleteByEmail(BuildContext context, String email) async {
    final trimmed = email.trim().toLowerCase();
    if (trimmed.isEmpty) return;

    setState(() => _busy = true);
    try {
      await _coachMode.inviteAthlete(trimmed);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invitation sent to $trimmed')),
      );
      await _refresh();
    } on CoachModeException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- Cancel a pending invitation ----------
  Future<void> _cancelInvite(CoachAthleteLink link) async {
    setState(() => _busy = true);
    try {
      await _coachMode.cancelInvite(link.athleteUid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invitation to ${link.athleteLabel} cancelled')),
      );
      await _refresh();
    } on CoachModeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- Remove an athlete from the roster ----------
  // Canonical relationships are ENDED through coachModeReleaseAthlete.
  // LEGACY super-admin-seeded entries go through the removal-only
  // coachModeRemoveSeededAthlete callable — clients can no longer write
  // coachAssignments at all, which is what closed the self-seeding hole.
  Future<void> _removeAthlete(String uid) async {
    final label = _labelFor(uid);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove athlete?'),
        content: Text(
          '$label will immediately lose their coaching link with you. You will '
          'no longer see their training, planned blocks or check-ins.\n\n'
          'They keep all of their own data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      // ONE source-aware server action. A pair can be authorised by several
      // sources at once after migration (canonical link + super-admin seed +
      // stale legacy approval); the server removes every source this coach may
      // remove and reports back what, if anything, still authorises.
      final result = await _coachMode.removeAthleteFromRoster(uid);
      if (!mounted) return;

      final stillAuthorized = result['stillAuthorized'] == true;
      final remaining = (result['remainingSources'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];

      if (stillAuthorized) {
        // Never claim success while access remains. The only source a coach
        // cannot clear themselves is a super-admin seed re-added by an admin.
        setState(() => _busy = false);
        await _refresh();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            '$label was partly removed, but you still have access via '
            '${_describeSources(remaining)}. Ask the GoodLift team to remove it.',
          ),
          duration: const Duration(seconds: 6),
        ));
        return;
      }

      setState(() {
        _athletes.remove(uid);
        _seededOnlyUids.remove(uid);
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$label removed')));
      await _refresh();
    } on CoachModeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Human wording for the authorization sources the server reported.
  static String _describeSources(List<String> sources) {
    if (sources.isEmpty) return 'another assignment';
    return sources.map((s) {
      switch (s) {
        case 'canonical':
          return 'an active coaching link';
        case 'legacy_seeded':
          return 'an assignment set up by the GoodLift team';
        case 'legacy_approved':
          return 'an older approval from the athlete';
        case 'super_admin':
          return 'super-admin access';
        default:
          return s;
      }
    }).join(' and ');
  }

  String _labelFor(String uid) {
    final a = _athletes[uid] ?? const {};
    for (final key in ['username', 'displayName', 'fullName', 'email']) {
      final v = (a[key] ?? '').toString().trim();
      if (v.isNotEmpty) return v;
    }
    return uid;
  }

  @override
  Widget build(BuildContext context) {
    final userContext = UserContext.maybeOf(context);

    if (userContext == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // FAIL CLOSED. Watched via UserContext.of(context) upstream, so a
    // suspension or revocation arriving on the CURRENT (possibly replaced)
    // context re-runs build and swaps the dashboard out immediately — no
    // athlete data is rendered for the frames before _ejectAfterFrame pops.
    if (!userContext.hasCoachMode) {
      return const _CoachAccessRevokedScreen();
    }

    // ---------- Updated: search + alphabetical sort by email ----------
    String safeLower(dynamic v) => (v ?? '').toString().trim().toLowerCase();

    final q = _search.trim().toLowerCase();

    final filteredUids = _athletes.keys.where((uid) {
      final a = _athletes[uid] ?? {};
      final email = safeLower(a['email']);
      final name  = safeLower(a['displayName']);
      final uidL  = uid.toLowerCase();
      return uidL.contains(q) || email.contains(q) || name.contains(q);
    }).toList();

// Sort by email (primary), then displayName, then uid
    filteredUids.sort((aUid, bUid) {
      final a = _athletes[aUid] ?? {};
      final b = _athletes[bUid] ?? {};

      final aEmail = safeLower(a['email']);
      final bEmail = safeLower(b['email']);
      final c1 = aEmail.compareTo(bEmail);
      if (c1 != 0) return c1;

      final aName = safeLower(a['displayName']);
      final bName = safeLower(b['displayName']);
      final c2 = aName.compareTo(bName);
      if (c2 != 0) return c2;

      return aUid.compareTo(bUid);
    });

    return Scaffold(
      appBar: AppBar(
          title: const Text("Coach Dashboard"),
          foregroundColor: Colors.white,
          elevation: 0,
          actionsIconTheme: IconThemeData(color: Theme.of(context).colorScheme.secondary),
          actions: [
            // Weekly Review / bi-weekly check-ins (coach-only screen)
            IconButton(
              tooltip: 'Weekly Review / Check-ins',
              icon: const Icon(Icons.fact_check_outlined),
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ChangeNotifierProvider<UserContext>.value(
                    value: context.read<UserContext>(),
                    child: const CoachWeeklyReviewScreen(),
                  ),
                ));
              },
            ),

            // Coach path: invite by exact email. The athlete must accept before
            // any access is granted.
            IconButton(
              tooltip: 'Invite athlete by email',
              icon: const Icon(Icons.person_add_alt),
              onPressed: _busy ? null : () async {
                final controller = TextEditingController();
                final email = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Invite athlete'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          controller: controller,
                          decoration: const InputDecoration(
                            hintText: 'athlete@email.com',
                            labelText: 'Their exact GoodLift email',
                          ),
                          autofocus: true,
                          keyboardType: TextInputType.emailAddress,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'They will be asked to accept before you can see any '
                          'of their training.',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, controller.text),
                        child: const Text('Send invitation'),
                      ),
                    ],
                  ),
                );
                if (email != null && email.trim().isNotEmpty) {
                  await _inviteAthleteByEmail(context, email);
                }
              },
            ),

            // Super-admin-only: seed any athlete to any coach
            if (userContext.isSuperAdmin)
              IconButton(
                tooltip: 'Seed athlete to coach (admin)',
                icon: const Icon(Icons.admin_panel_settings),
                onPressed: () async {
                  final coachSearchController = TextEditingController();
                  final athleteEmailController = TextEditingController();
                  String? selectedCoachUid;
                  String? selectedCoachName;
                  List<Map<String, String>> results = [];
                  bool isSearching = false;

                  Future<void> _search(String q) async {
                    final query = q.trim();
                    results = [];
                    if (query.isEmpty) return;

                    isSearching = true;
                    try {
                      final merged = <Map<String, String>>[];
                      final seen = <String>{};

                      String safe(Object? v) => (v ?? '').toString();

                      // 0) If it looks like an email, try your user_lookup first (exact match)
                      if (query.contains('@')) {
                        final lu = await FirebaseFirestore.instance
                            .collection('user_lookup')
                            .doc(query.toLowerCase())
                            .get();

                        if (lu.exists) {
                          final data = lu.data() as Map<String, dynamic>;
                          final uid = safe(data['uid']);
                          if (uid.isNotEmpty && seen.add(uid)) {
                            merged.add({
                              'uid': uid,
                              'name': safe(data['displayName']),
                              'email': safe(data['email']),
                            });
                          }
                        }
                      }

                      // 1) Name search (case-sensitive, no lowercased field required)
                      try {
                        final byName = await FirebaseFirestore.instance
                            .collection('users')
                            .orderBy('displayName')                  // no displayNameLower needed
                            .startAt([query])                        // prefix match (case sensitive)
                            .endAt(['$query\uf8ff'])
                            .limit(10)
                            .get();

                        for (final d in byName.docs) {
                          final uid = d.id;
                          if (seen.add(uid)) {
                            final data = d.data() as Map<String, dynamic>;
                            merged.add({
                              'uid': uid,
                              'name': safe(data['displayName']),
                              'email': safe(data['email']),
                            });
                          }
                        }
                      } on FirebaseException catch (e) {
                        // If you see "requires an index", create it in Firestore console.
                        debugPrint('🔎 byName search failed: ${e.message}');
                      }

                      // 2) Email prefix search (no emailLower needed)
                      try {
                        final byEmail = await FirebaseFirestore.instance
                            .collection('users')
                            .orderBy('email')
                            .startAt([query])
                            .endAt(['$query\uf8ff'])
                            .limit(10)
                            .get();

                        for (final d in byEmail.docs) {
                          final uid = d.id;
                          if (seen.add(uid)) {
                            final data = d.data() as Map<String, dynamic>;
                            merged.add({
                              'uid': uid,
                              'name': safe(data['displayName']),
                              'email': safe(data['email']),
                            });
                          }
                        }
                      } on FirebaseException catch (e) {
                        debugPrint('🔎 byEmail search failed: ${e.message}');
                      }

                      results = merged;
                      debugPrint('🔍 coach search "${query}": ${results.length} result(s)');
                    } catch (e, st) {
                      debugPrint('❌ coach search error: $e\n$st');
                      results = [];
                    } finally {
                      isSearching = false;
                    }
                  }

                  final result = await showDialog<Map<String, String>?>(
                    context: context, // ✅ pass the BuildContext you already have
                    builder: (ctx) {
                      return StatefulBuilder(
                        builder: (ctx, setLocalState) {
                          Future<void> handleSearch(String v) async {
                            await _search(v);
                            setLocalState(() {}); // refresh list
                          }

                          return AlertDialog(
                            title: const Text('Seed athlete to coach'),
                            content: SingleChildScrollView( // ✅ prevents overflow
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxHeight: 400,  // cap total dialog height
                                  minWidth: 320,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Coach search field
                                    TextField(
                                      controller: coachSearchController,
                                      decoration: const InputDecoration(
                                        labelText: 'Coach name or email',
                                        hintText: 'Type to search…',
                                      ),
                                      onChanged: (v) => handleSearch(v),
                                      autofocus: true,
                                    ),

                                    if (selectedCoachUid != null) ...[
                                      const SizedBox(height: 6),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          'Selected UID: $selectedCoachUid',
                                          style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ),
                                    ],

                                    const SizedBox(height: 8),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        '${filteredUids.length} athlete${filteredUids.length == 1 ? '' : 's'}',
                                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                                      ),
                                    ),
                                    const SizedBox(height: 8),

                                    // Results list
                                    Flexible( // ✅ results take remaining space, scroll inside
                                      child: isSearching
                                          ? const Center(child: Padding(
                                        padding: EdgeInsets.all(12),
                                        child: CircularProgressIndicator(),
                                      ))
                                          : ListView.builder(
                                        shrinkWrap: true,
                                        itemCount: results.length,
                                        itemBuilder: (_, i) {
                                          final r = results[i];
                                          final name = (r['name']?.isNotEmpty ?? false) ? r['name']! : '(no name)';
                                          final email = r['email'] ?? '';
                                          final uid = r['uid'] ?? '';
                                          return ListTile(
                                            dense: true,
                                            title: Text(name),
                                            subtitle: Text('$email\n$uid'),
                                            isThreeLine: true,
                                            onTap: () {
                                              selectedCoachUid = uid;
                                              selectedCoachName = name;
                                              coachSearchController.text = name.isNotEmpty ? name : email;
                                              setLocalState(() {});
                                            },
                                          );
                                        },
                                      ),
                                    ),

                                    const SizedBox(height: 8),

                                    TextField(
                                      controller: athleteEmailController,
                                      decoration: const InputDecoration(labelText: 'Athlete email'),
                                      keyboardType: TextInputType.emailAddress,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                              TextButton(
                                onPressed: (selectedCoachUid != null && athleteEmailController.text.trim().isNotEmpty)
                                    ? () => Navigator.pop(ctx, {
                                  'coachUid': selectedCoachUid!,
                                  'coachName': selectedCoachName ?? '',
                                  'email': athleteEmailController.text.trim(),
                                })
                                    : null,
                                child: const Text('Add'),
                              ),
                            ],
                          );

                        },
                      );
                    },
                  );

                  if (result != null) {
                    final coachUid = (result['coachUid'] ?? '').trim();
                    final athleteEmail = (result['email'] ?? '').trim();
                    if (coachUid.isNotEmpty && athleteEmail.isNotEmpty) {
                      await _adminSeedAthleteToCoach(
                        coachUid: coachUid,
                        athleteEmail: athleteEmail,
                      );
                    }
                  }
                },
              ),
          ]

      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
              children: [
                TextField(
                  decoration: InputDecoration(
                    labelText: 'Search athletes',
                    labelStyle: const TextStyle(color: Colors.white70),
                    prefixIcon: Icon(Icons.search, color: Theme.of(context).colorScheme.secondary),
                    filled: true,
                    fillColor: Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Theme.of(context).colorScheme.outline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Theme.of(context).colorScheme.secondary),
                    ),
                  ),
                  style: const TextStyle(color: Colors.white),
                  onChanged: (value) => setState(() => _search = value),
                ),

              ],
            ),
          ),

          // ── Pending invitations ────────────────────────────────────────
          // A pending invitation is NOT a roster entry and grants no access,
          // so it lives in its own clearly-labelled section above the roster.
          if (_pending.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'AWAITING ACCEPTANCE (${_pending.length})',
                  style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.bold,
                    color: Colors.white54,
                  ),
                ),
              ),
            ),
            ..._pending.map((link) => Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: Card(
                    elevation: 0,
                    color: Theme.of(context).cardTheme.color ??
                        Theme.of(context).colorScheme.surface,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    child: ListTile(
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -4),
                      leading: const Icon(Icons.hourglass_top,
                          color: Colors.amberAccent, size: 22),
                      title: Text(
                        link.athleteLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                      ),
                      subtitle: Text(
                        coachLinkStatusLabel(link.status),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                      trailing: TextButton(
                        onPressed: _busy ? null : () => _cancelInvite(link),
                        child: const Text('Cancel',
                            style: TextStyle(color: Colors.white70, fontSize: 12)),
                      ),
                    ),
                  ),
                )),
            const SizedBox(height: 6),
          ],

          if (filteredUids.isEmpty && _pending.isEmpty)
            const Expanded(child: _CoachEmptyState())
          else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              itemCount: filteredUids.length,
              separatorBuilder: (_, __) => const SizedBox(height: 3),
              itemBuilder: (context, index) {
                final uid = filteredUids[index];
                final isSelected = uid == userContext.actingAsUid;
                final a = _athletes[uid] ?? {};

                String? pick(dynamic v) {
                  final s = (v ?? '').toString().trim();
                  return s.isEmpty ? null : s;
                }

                final titleText =
                    pick(a['username']) ??
                        pick(a['displayName']) ??
                        pick(a['email']) ??
                        uid;

                final emailText = pick(a['email']);
                final usernameText = pick(a['username']);
                final subtitleText = (emailText != null && emailText != titleText)
                    ? emailText
                    : null;

                return Card(
                  elevation: 0,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary.withOpacity(0.22)
                      : Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: ListTile(
                    dense: true,
                    visualDensity: const VisualDensity(vertical: -4), // tighter row height
                    minVerticalPadding: 0, // remove default extra vertical padding
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), // tight card padding

                    title: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Line 1: EMAIL (primary)
                        Text(
                          (emailText ?? uid),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            height: 1.05, // tight line height
                          ),
                        ),
                        // Line 2: USERNAME / DISPLAYNAME (secondary)
                        Text(
                          pick(a['username']) ?? pick(a['displayName']) ?? pick(a['fullName']) ?? '(no name)',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            height: 1.05, // tight line height
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),

                    leading: Icon(
                      isSelected ? Icons.check_circle : Icons.person,
                      color: isSelected ? Theme.of(context).colorScheme.secondary : Colors.white54,
                      size: 22, // slightly smaller to match tighter rows
                    ),

                    trailing: CoachAthleteActions(
                      email: emailText,
                      username: usernameText,
                      onRemove: _busy ? null : () => _removeAthlete(uid),
                    ),

                    onTap: () {
                      userContext.switchAthlete(uid);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Switched to athlete: ${emailText ?? uid}")),
                      );
                    },
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 36),
        ],
      ),
    );
  }
}

/// Fail-closed replacement for the dashboard once the resolved context reports
/// no Coach Mode. Deliberately renders no athlete data of any kind.
class _CoachAccessRevokedScreen extends StatelessWidget {
  const _CoachAccessRevokedScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Coach Dashboard')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48, color: Colors.white54),
              const SizedBox(height: 16),
              const Text(
                'Coach Mode is not active',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your coach access is no longer active on this account, so the '
                'dashboard is unavailable.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.white60),
              ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Go back'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when a coach has neither athletes nor outstanding invitations.
class _CoachEmptyState extends StatelessWidget {
  const _CoachEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_outlined,
                size: 48, color: Theme.of(context).colorScheme.secondary),
            const SizedBox(height: 16),
            const Text(
              'No athletes yet',
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text(
              'Invite an athlete with the person icon above, using the exact '
              'email on their GoodLift account. They accept the invitation '
              'before you can see any of their training.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.white60, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Trailing actions for a single athlete row on the coach dashboard: an
/// overflow menu that copies the athlete's email or username, plus the
/// existing remove-athlete button.
///
/// Kept as its own widget so the shipped menu can be widget-tested directly;
/// [CoachHomeScreen] itself cannot be mounted in a test because its roster
/// load reaches Firestore, Auth and UserContext.
class CoachAthleteActions extends StatelessWidget {
  const CoachAthleteActions({
    super.key,
    required this.email,
    required this.username,
    required this.onRemove,
  });

  /// Athlete email, already trimmed by the caller; null when absent or blank.
  final String? email;

  /// Athlete username, already trimmed by the caller; null when absent or blank.
  final String? username;

  /// Null disables removal (the dashboard is busy).
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          iconSize: 22,
          icon: const Icon(Icons.more_vert, color: Colors.white70),
          tooltip: 'More actions',
          onSelected: (value) async {
            // Resolved before the await so no BuildContext crosses the gap.
            final messenger = ScaffoldMessenger.of(context);
            final email = this.email;
            final username = this.username;
            if (value == 'copy_email' && email != null) {
              await Clipboard.setData(ClipboardData(text: email));
              messenger.showSnackBar(
                const SnackBar(content: Text('Email copied')),
              );
            } else if (value == 'copy_username' && username != null) {
              await Clipboard.setData(ClipboardData(text: username));
              messenger.showSnackBar(
                const SnackBar(content: Text('Username copied')),
              );
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              value: 'copy_email',
              enabled: email != null,
              child: const Text('Copy email'),
            ),
            PopupMenuItem<String>(
              value: 'copy_username',
              enabled: username != null,
              child: const Text('Copy username'),
            ),
          ],
        ),
        IconButton(
          visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          icon: const Icon(Icons.delete_outline, color: Colors.white70, size: 22),
          onPressed: onRemove,
          tooltip: 'Remove athlete',
        ),
      ],
    );
  }
}
