import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:localtest222/user_context.dart'; // <-- your UserContext
// import 'package:localtest222/theme.dart'; // if you have shared theme things

class UserSettingsScreen extends StatefulWidget {
  const UserSettingsScreen({super.key});

  @override
  State<UserSettingsScreen> createState() => _UserSettingsScreenState();
}

class _UserSettingsScreenState extends State<UserSettingsScreen> {
  final _formKey = GlobalKey<FormState>();

  // Selected athlete (self or coached athlete)
  String get userId => UserContext.of(context, listen: false).currentUid;

  // Controllers
  final _usernameCtrl = TextEditingController();
  final _fullNameCtrl = TextEditingController();
  final _dobCtrl      = TextEditingController(); // dd-mm-yyyy
  String? _sex; // 'M' | 'F' | 'N'

  // State
  bool _loading = true;
  bool _saving = false;
  String? _error;

  // Live username availability (emoji OK, 3–22, no spaces)
  bool _usernameChecking = false;
  bool? _usernameAvailable; // null = unknown, true = ok, false = taken
  Timer? _usernameDebounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _usernameDebounce?.cancel();
    _usernameCtrl.dispose();
    _fullNameCtrl.dispose();
    _dobCtrl.dispose();
    super.dispose();
  }

  // ------------------- Helpers -------------------

  void _insertDashAtCursor(TextEditingController c) {
    final sel = c.selection;
    final text = c.text;
    final i = sel.start;
    if (i < 0) {
      c.text = '$text-';
      c.selection = TextSelection.collapsed(offset: c.text.length);
      return;
    }
    final next = text.replaceRange(i, i, '-');
    c.text = next;
    final newOffset = (i + 1).clamp(0, next.length);
    c.selection = TextSelection.collapsed(offset: newOffset);
  }


  // Accepts dd-mm-yyyy or yyyy-mm-dd; returns dd-mm-yyyy or null
  String? _normalizeDob(String input) {
    final s = input.trim();
    final ddmm = RegExp(r'^(\d{2})-(\d{2})-(\d{4})$');
    final ymd  = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

    int y, m, d;
    if (ddmm.hasMatch(s)) {
      final m1 = ddmm.firstMatch(s)!;
      d = int.parse(m1.group(1)!);
      m = int.parse(m1.group(2)!);
      y = int.parse(m1.group(3)!);
    } else if (ymd.hasMatch(s)) {
      final m2 = ymd.firstMatch(s)!;
      y = int.parse(m2.group(1)!);
      m = int.parse(m2.group(2)!);
      d = int.parse(m2.group(3)!);
    } else {
      return null;
    }

    try {
      final dt = DateTime(y, m, d);
      if (dt.year != y || dt.month != m || dt.day != d) return null;

      final now = DateTime.now();
      final oldest = DateTime(now.year - 120, now.month, now.day);

      if (dt.isAfter(now)) {
        _error = "What are you from the future? Try again.";
        return null;
      }
// OLD:
// if (dt.isBefore(oldest)) {
// NEW (block ≤ 125y ago):
      if (!dt.isAfter(oldest)) {
        _error = "🧙 I call BS! You are not that old.";
        return null;
      }

    } catch (_) {
      return null;
    }

    final dd = d.toString().padLeft(2, '0');
    final mm = m.toString().padLeft(2, '0');
    return '$dd-$mm-$y';
  }


  bool _validUsername(String v) {
    return RegExp(r'^[^\s]{3,22}$').hasMatch(v.trim());
  }


  Future<bool> _isUsernameAvailable(String username) async {
    final lower = username.toLowerCase();
    final q = await FirebaseFirestore.instance
        .collection('users_public')
        .where('usernameLower', isEqualTo: lower)
        .limit(1)
        .get();
    if (q.docs.isEmpty) return true;
    // Allow if the only match is this same user
    return q.docs.first.id == userId;
  }

  void _onUsernameChanged(String raw) {
    _usernameDebounce?.cancel();
    final v = raw.trim();
    setState(() {
      _usernameAvailable = null;
      _usernameChecking = false;
    });
    if (!_validUsername(v)) return;
    _usernameDebounce = Timer(const Duration(milliseconds: 450), () async {
      setState(() => _usernameChecking = true);
      try {
        final ok = await _isUsernameAvailable(v);
        if (mounted) setState(() => _usernameAvailable = ok);
      } catch (_) {
        // silent fail; submit validator still runs
      } finally {
        if (mounted) setState(() => _usernameChecking = false);
      }
    });
  }

  // ------------------- Load/Save -------------------

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final usersDoc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
      final pubDoc   = await FirebaseFirestore.instance.collection('users_public').doc(userId).get();

      final d = usersDoc.data() ?? {};
      final p = pubDoc.data() ?? {};

      _usernameCtrl.text = (d['username'] ?? p['username'] ?? '') as String;
      _fullNameCtrl.text = (d['fullName'] ?? p['fullName'] ?? '') as String;
      _dobCtrl.text      = (d['dob'] ?? '') as String; // expect dd-mm-yyyy
      _sex               = (d['sex'] as String?) ?? 'N';
    } catch (e, st) {
      // print('Load settings error: $e\n$st');
      _error = 'Failed to load settings.';
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() { _saving = true; _error = null; });
    try {
      final username = _usernameCtrl.text.trim();
      final fullName = _fullNameCtrl.text.trim();
      final dobRaw   = _dobCtrl.text.trim();
      final sex      = _sex;

      final dobNorm = _normalizeDob(dobRaw);
      if (dobNorm == null) {
        setState(() { _error = 'Enter a valid date (dd-mm-yyyy).'; });
        return;
      }

      // Final check on username uniqueness
      final available = await _isUsernameAvailable(username);
      if (!available) {
        setState(() { _error = 'That username is taken. Choose another.'; });
        return;
      }

      final payloadPrivate = {
        'username': username,
        'usernameLower': username.toLowerCase(),
        'fullName': fullName,
        'dob': dobNorm,
        'sex': sex,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final payloadPublic = {
        'username': username,
        'usernameLower': username.toLowerCase(),
        'displayName': username,
        'fullName': fullName, // 👈 new
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance.collection('users').doc(userId)
          .set(payloadPrivate, SetOptions(merge: true));

      await FirebaseFirestore.instance.collection('users_public').doc(userId)
          .set(payloadPublic, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved')),
        );
      }
    } catch (e, st) {
      // print('Save settings error: $e\n$st');
      setState(() { _error = 'Failed to save settings.'; });
    } finally {
      if (mounted) setState(() { _saving = false; });
    }
  }

  // ------------------- UI -------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('User Settings'),
        backgroundColor: Colors.blueGrey, // match Home
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(16),
          child: Card(
            elevation: 8,
            color: Colors.blueGrey.shade800,

            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Profile',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,   color: Colors.white,),
                    ),
                    const SizedBox(height: 16),

                    // Username
                    TextFormField(
                      controller: _usernameCtrl,
                      decoration: InputDecoration(
                        labelText: 'Username',
                        labelStyle: const TextStyle(color: Colors.white),
                        hintText: '3–22 chars, no spaces (emoji OK)',
                        suffixIcon: (_usernameChecking)
                            ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                            : (_usernameAvailable == null
                            ? null
                            : Icon(
                          _usernameAvailable! ? Icons.check_circle : Icons.error,
                          color: _usernameAvailable! ? Colors.green : Colors.redAccent,
                        )),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white70),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white70, width: 2),
                        ),
                      ),
                      onChanged: _onUsernameChanged,
                      validator: (v) {
                        final s = (v ?? '').trim();
                        if (s.isEmpty) return 'Please choose a username';
                        if (!_validUsername(s)) return '3–22 chars, no spaces';
                        if (_usernameAvailable == false) return 'That username is taken';
                        return null;
                      },
                    ),

                    const SizedBox(height: 12),

                    // Full Name
                    TextFormField(
                      controller: _fullNameCtrl,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: 'Full Name',
                        labelStyle: const TextStyle(color: Colors.white),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white70),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white70, width: 2),
                        ),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter full name' : null,
                    ),

                    const SizedBox(height: 12),

                    // DOB
                    TextFormField(
                      controller: _dobCtrl,
                      keyboardType: TextInputType.datetime,
                      decoration: InputDecoration(
                        labelText: 'Date of Birth',
                        hintText: 'dd-mm-yyyy',
                        labelStyle: const TextStyle(color: Colors.white),
                        errorMaxLines: 3, // 👈 allow wrapping up to 3 lines
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Insert dash',
                              icon: const Icon(Icons.remove, color: Colors.white70),
                              onPressed: () => _insertDashAtCursor(_dobCtrl),
                            ),
                            IconButton(
                              tooltip: 'Pick date',
                              icon: const Icon(Icons.calendar_today, color: Colors.white70),
                              onPressed: () async {
                                // … your date picker code …
                              },
                            ),
                          ],
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white70),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white70, width: 2),
                        ),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Please enter your date of birth';
                        }
                        final norm = _normalizeDob(v);
                        if (norm == null) {
                          return _error ??
                              'Enter a valid date\nFormat must be dd-mm-yyyy\nCheck your age range too';
                        }
                        _dobCtrl.text = norm;
                        return null;
                      },
                    ),



                    const SizedBox(height: 12),

                    // Sex
                    DropdownButtonFormField<String>(
                      value: _sex,
                      items: const [
                        DropdownMenuItem(value: 'M', child: Text('Male')),
                        DropdownMenuItem(value: 'F', child: Text('Female')),
                        DropdownMenuItem(value: 'N', child: Text('Robot')),
                      ],
                      onChanged: (v) => setState(() => _sex = v),
                      decoration: InputDecoration(
                        labelText: 'Sex',
                        labelStyle: const TextStyle(color: Colors.white),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white70),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white70, width: 2),
                        ),
                      ),
                      validator: (v) => (v == null || v.isEmpty) ? 'Please select' : null,
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                    ],

                    const SizedBox(height: 16),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
