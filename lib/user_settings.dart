import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'demographics_cache.dart';
import 'package:localtest222/user_context.dart'; // <-- your UserContext
import 'themes_screen.dart';
import 'account_deletion_screen.dart';
import 'app_theme.dart';

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
  final _dobCtrl = TextEditingController(); // dd-mm-yyyy
  String? _sex; // 'M' | 'F' | 'N'

  // State
  bool _loading = true;
  bool _saving = false;
  String? _error;

  // True when the signed-in user already has email/password as a provider.
  bool get _hasPasswordProvider =>
      FirebaseAuth.instance.currentUser?.providerData
          .any((p) => p.providerId == 'password') ??
      false;

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
    final ymd = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final usersDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final pubDoc = await FirebaseFirestore.instance
          .collection('users_public')
          .doc(userId)
          .get();

      final d = usersDoc.data() ?? {};
      final p = pubDoc.data() ?? {};

      _usernameCtrl.text = (d['username'] ?? p['username'] ?? '') as String;
      _fullNameCtrl.text = (d['fullName'] ?? p['fullName'] ?? '') as String;
      _dobCtrl.text = (d['dob'] ?? '') as String; // expect dd-mm-yyyy
      _sex = (d['sex'] as String?) ?? 'N';
    } catch (e, st) {
      // print('Load settings error: $e\n$st');
      _error = 'Failed to load settings.';
    } finally {
      if (mounted)
        setState(() {
          _loading = false;
        });
    }
  }

  Future<void> _save() async {
    print('🧪 [UserSettings] _save() START');

    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final username = _usernameCtrl.text.trim();
      final fullName = _fullNameCtrl.text.trim();
      final dobRaw = _dobCtrl.text.trim();
      final sex = _sex;

      final dobNorm = _normalizeDob(dobRaw);
      if (dobNorm == null) {
        setState(() {
          _error = 'Enter a valid date (dd-mm-yyyy).';
        });
        return;
      }

      // Final check on username uniqueness
      final available = await _isUsernameAvailable(username);
      if (!available) {
        setState(() {
          _error = 'That username is taken. Choose another.';
        });
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

      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .set(payloadPrivate, SetOptions(merge: true));

      await FirebaseFirestore.instance
          .collection('users_public')
          .doc(userId)
          .set(payloadPublic, SetOptions(merge: true));
      // ✅ Keep local demographics cache in sync (offline + no extra reads elsewhere)
      await DemographicsCache.save(
        uid: userId,
        sex: sex,
        dob: dobNorm, // normalized string
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved')),
        );
      }
    } catch (e, st) {
      // print('Save settings error: $e\n$st');
      setState(() {
        _error = 'Failed to save settings.';
      });
    } finally {
      if (mounted)
        setState(() {
          _saving = false;
        });
    }
  }

  Future<void> _showChangePasswordDialog() async {
    final currentUser = FirebaseAuth.instance.currentUser;

    // Only allow if we have an email/password user
    if (currentUser == null || currentUser.email == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('You need an email/password account to change password.'),
        ),
      );
      return;
    }

    final currentPasswordCtrl = TextEditingController();
    final newPasswordCtrl = TextEditingController();
    final confirmPasswordCtrl = TextEditingController();

    String? localError;
    bool localSaving = false;

    // 👁️ visibility toggles
    bool showCurrent = false;
    bool showNew = false;
    bool showConfirm = false;

    // ✅ passwords match flag (for green confirm styling)
    bool passwordsMatch = false;

    // ✅ current password check state
    bool currentPasswordChecking = false;
    bool? currentPasswordValid; // null = unknown, true = ok, false = wrong

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            final baseTheme = Theme.of(ctx);
            final baseSelection = baseTheme.textSelectionTheme;

            void _updateMatch() {
              final newPass = newPasswordCtrl.text.trim();
              final confirm = confirmPasswordCtrl.text.trim();
              setStateDialog(() {
                passwordsMatch = newPass.isNotEmpty && newPass == confirm;
              });
            }

            Future<void> _checkCurrentPassword() async {
              final current = currentPasswordCtrl.text.trim();
              if (current.isEmpty) {
                setStateDialog(() {
                  currentPasswordValid = null;
                });
                return;
              }

              setStateDialog(() {
                currentPasswordChecking = true;
                currentPasswordValid = null;
              });

              try {
                final cred = EmailAuthProvider.credential(
                  email: currentUser.email!,
                  password: current,
                );

                // Just reauthenticate to verify password
                await currentUser.reauthenticateWithCredential(cred);

                setStateDialog(() {
                  currentPasswordChecking = false;
                  currentPasswordValid = true;
                });
              } on FirebaseAuthException catch (e) {
                setStateDialog(() {
                  currentPasswordChecking = false;
                  if (e.code == 'wrong-password') {
                    currentPasswordValid = false;
                  } else {
                    // treat other auth errors as "unknown" for this UX
                    currentPasswordValid = false;
                  }
                });
              } catch (_) {
                setStateDialog(() {
                  currentPasswordChecking = false;
                  currentPasswordValid = false;
                });
              }
            }

            Future<void> handleSave() async {
              final current = currentPasswordCtrl.text.trim();
              final newPass = newPasswordCtrl.text.trim();
              final confirm = confirmPasswordCtrl.text.trim();

              if (current.isEmpty || newPass.isEmpty || confirm.isEmpty) {
                setStateDialog(() {
                  localError = 'Please fill in all fields.';
                });
                return;
              }
              if (newPass.length < 6) {
                setStateDialog(() {
                  localError = 'New password must be at least 6 characters.';
                });
                return;
              }
              if (newPass != confirm) {
                setStateDialog(() {
                  localError = 'New password and confirmation do not match.';
                  passwordsMatch = false;
                });
                return;
              }

              setStateDialog(() {
                localSaving = true;
                localError = null;
              });

              try {
                final cred = EmailAuthProvider.credential(
                  email: currentUser.email!,
                  password: current,
                );

                // Re-authenticate
                await currentUser.reauthenticateWithCredential(cred);

                // Update password
                await currentUser.updatePassword(newPass);

                if (mounted) {
                  Navigator.of(dialogCtx).pop(); // close dialog
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Password updated successfully.')),
                  );
                }
              } on FirebaseAuthException catch (e) {
                setStateDialog(() {
                  localSaving = false;
                  if (e.code == 'wrong-password') {
                    localError = 'Current password is incorrect.';
                    currentPasswordValid = false;
                  } else {
                    localError = e.message ?? 'Failed to update password.';
                  }
                });
              } catch (_) {
                setStateDialog(() {
                  localSaving = false;
                  localError = 'Failed to update password.';
                });
              }
            }

            return AlertDialog(
              title: const Text('Change password'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ✅ Conditional label above current password
                    if (currentPasswordChecking) ...[
                      const Text('Checking current password...'),
                      const SizedBox(height: 4),
                    ] else if (currentPasswordValid != null) ...[
                      if (currentPasswordValid == true)
                        const Text(
                          '✅',
                          style: TextStyle(fontSize: 18),
                        )
                      else
                        const Text(
                          'bro that ain’t your password 💀',
                          style: TextStyle(color: Colors.red),
                        ),
                      const SizedBox(height: 4),
                    ],

                    // Current password field with focus-based check
                    Focus(
                      onFocusChange: (hasFocus) {
                        if (!hasFocus) {
                          _checkCurrentPassword();
                        }
                      },
                      child: TextField(
                        controller: currentPasswordCtrl,
                        obscureText: !showCurrent,
                        decoration: InputDecoration(
                          labelText: 'Current password',
                          suffixIcon: IconButton(
                            icon: Icon(
                              showCurrent
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                            onPressed: () {
                              setStateDialog(() {
                                showCurrent = !showCurrent;
                              });
                            },
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 8),

                    TextField(
                      controller: newPasswordCtrl,
                      obscureText: !showNew,
                      onChanged: (_) => _updateMatch(),
                      decoration: InputDecoration(
                        labelText: 'New password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            showNew ? Icons.visibility_off : Icons.visibility,
                          ),
                          onPressed: () {
                            setStateDialog(() {
                              showNew = !showNew;
                            });
                          },
                        ),
                      ),
                    ),

                    const SizedBox(height: 8),

                    // ✅ Confirm field with green label & selection when matching
                    Theme(
                      data: baseTheme.copyWith(
                        textSelectionTheme: TextSelectionThemeData(
                          selectionColor: passwordsMatch
                              ? Colors.green.withOpacity(0.4)
                              : baseSelection.selectionColor,
                          cursorColor: passwordsMatch
                              ? Colors.green
                              : baseSelection.cursorColor,
                          selectionHandleColor: passwordsMatch
                              ? Colors.green
                              : baseSelection.selectionHandleColor,
                        ),
                      ),
                      child: TextField(
                        controller: confirmPasswordCtrl,
                        obscureText: !showConfirm,
                        onChanged: (_) => _updateMatch(),
                        decoration: InputDecoration(
                          labelText: 'Confirm new password',
                          labelStyle: TextStyle(
                            color:
                                passwordsMatch ? Colors.green : Colors.black54,
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(
                              showConfirm
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: passwordsMatch ? Colors.green : null,
                            ),
                            onPressed: () {
                              setStateDialog(() {
                                showConfirm = !showConfirm;
                              });
                            },
                          ),
                        ),
                      ),
                    ),

                    if (localError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        localError!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: localSaving
                      ? null
                      : () {
                          Navigator.of(dialogCtx).pop();
                        },
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: localSaving ? null : handleSave,
                  child: localSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showAddPasswordLoginDialog() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final emailCtrl = TextEditingController(text: currentUser.email ?? '');
    final passwordCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();

    String? localError;
    bool localSaving = false;
    bool showPassword = false;
    bool showConfirm = false;
    bool passwordsMatch = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDlg) {
            void updateMatch() {
              final pw = passwordCtrl.text.trim();
              final cf = confirmCtrl.text.trim();
              setDlg(() => passwordsMatch = pw.isNotEmpty && pw == cf);
            }

            Future<void> handleSave() async {
              final email = emailCtrl.text.trim();
              final pw = passwordCtrl.text.trim();
              final cf = confirmCtrl.text.trim();

              if (email.isEmpty || pw.isEmpty || cf.isEmpty) {
                setDlg(() => localError = 'Please fill in all fields.');
                return;
              }
              if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
                setDlg(
                    () => localError = 'Please enter a valid email address.');
                return;
              }
              if (pw.length < 6) {
                setDlg(() =>
                    localError = 'Password must be at least 6 characters.');
                return;
              }
              if (pw != cf) {
                setDlg(() {
                  localError = 'Passwords do not match.';
                  passwordsMatch = false;
                });
                return;
              }

              setDlg(() {
                localSaving = true;
                localError = null;
              });

              try {
                final credential = EmailAuthProvider.credential(
                  email: email,
                  password: pw,
                );
                await currentUser.linkWithCredential(credential);
                // Reload so FirebaseAuth.instance.currentUser.providerData
                // reflects the newly linked password provider before setState.
                await FirebaseAuth.instance.currentUser?.reload();

                if (mounted) {
                  Navigator.of(dialogCtx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Password login added successfully.')),
                  );
                  // Rebuild: _hasPasswordProvider now reads refreshed providerData.
                  setState(() {});
                }
              } on FirebaseAuthException catch (e) {
                setDlg(() {
                  localSaving = false;
                  if (e.code == 'provider-already-linked') {
                    localError =
                        'Password login is already enabled for this account.';
                  } else if (e.code == 'credential-already-in-use' ||
                      e.code == 'email-already-in-use') {
                    localError =
                        'That email is already linked to another account.';
                  } else if (e.code == 'requires-recent-login') {
                    localError = 'Please sign out and back in, then try again.';
                  } else {
                    localError = e.message ?? 'Failed to add password login.';
                  }
                });
              } catch (_) {
                setDlg(() {
                  localSaving = false;
                  localError = 'Failed to add password login.';
                });
              }
            }

            return AlertDialog(
              title: const Text('Add password login'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: passwordCtrl,
                      obscureText: !showPassword,
                      onChanged: (_) => updateMatch(),
                      decoration: InputDecoration(
                        labelText: 'New password',
                        suffixIcon: IconButton(
                          icon: Icon(showPassword
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () =>
                              setDlg(() => showPassword = !showPassword),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: confirmCtrl,
                      obscureText: !showConfirm,
                      onChanged: (_) => updateMatch(),
                      decoration: InputDecoration(
                        labelText: 'Confirm password',
                        labelStyle: TextStyle(
                          color: passwordsMatch ? Colors.green : null,
                        ),
                        suffixIcon: IconButton(
                          icon: Icon(
                            showConfirm
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: passwordsMatch ? Colors.green : null,
                          ),
                          onPressed: () =>
                              setDlg(() => showConfirm = !showConfirm),
                        ),
                      ),
                    ),
                    if (localError != null) ...[
                      const SizedBox(height: 8),
                      Text(localError!,
                          style: const TextStyle(color: Colors.red)),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      localSaving ? null : () => Navigator.of(dialogCtx).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: localSaving ? null : handleSave,
                  child: localSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    emailCtrl.dispose();
    passwordCtrl.dispose();
    confirmCtrl.dispose();
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
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(16),
          child: Card(
            elevation: 8,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Profile',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
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
                                child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)),
                              )
                            : (_usernameAvailable == null
                                ? null
                                : Icon(
                                    _usernameAvailable!
                                        ? Icons.check_circle
                                        : Icons.error,
                                    color: _usernameAvailable!
                                        ? Colors.green
                                        : Colors.redAccent,
                                  )),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white70),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide:
                              const BorderSide(color: Colors.white70, width: 2),
                        ),
                      ),
                      onChanged: _onUsernameChanged,
                      validator: (v) {
                        final s = (v ?? '').trim();
                        if (s.isEmpty) return 'Please choose a username';
                        if (!_validUsername(s)) return '3–22 chars, no spaces';
                        if (_usernameAvailable == false)
                          return 'That username is taken';
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
                          borderSide:
                              const BorderSide(color: Colors.white70, width: 2),
                        ),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Please enter full name'
                          : null,
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
                              icon: Icon(Icons.remove,
                                  color:
                                      Theme.of(context).colorScheme.tertiary),
                              onPressed: () => _insertDashAtCursor(_dobCtrl),
                            ),
                            IconButton(
                              tooltip: 'Pick date',
                              icon: Icon(Icons.calendar_today,
                                  color:
                                      Theme.of(context).colorScheme.tertiary),
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
                          borderSide:
                              const BorderSide(color: Colors.white70, width: 2),
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
                          borderSide:
                              const BorderSide(color: Colors.white70, width: 2),
                        ),
                      ),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'Please select' : null,
                    ),

                    const SizedBox(height: 12),

                    if (_hasPasswordProvider)
                      InkWell(
                        onTap: _showChangePasswordDialog,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            children: [
                              Icon(
                                Icons.lock_reset,
                                color: Theme.of(context).colorScheme.tertiary,
                                size: 20,
                              ),
                              SizedBox(width: 12),
                              Text(
                                'Change password',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Spacer(),
                              Icon(Icons.chevron_right,
                                  color: Theme.of(context).colorScheme.tertiary,
                                  size: 20),
                            ],
                          ),
                        ),
                      )
                    else
                      InkWell(
                        onTap: _showAddPasswordLoginDialog,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            children: [
                              Icon(Icons.lock_outline,
                                  color: Theme.of(context).colorScheme.tertiary,
                                  size: 20),
                              const SizedBox(width: 12),
                              const Text(
                                'Add password login',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const Spacer(),
                              Icon(Icons.chevron_right,
                                  color: Theme.of(context).colorScheme.tertiary,
                                  size: 20),
                            ],
                          ),
                        ),
                      ),

                    InkWell(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ThemesScreen()),
                      ),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            Icon(Icons.palette,
                                color: Theme.of(context).colorScheme.tertiary,
                                size: 20),
                            const SizedBox(width: 12),
                            const Text(
                              'Themes',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const Spacer(),
                            Icon(Icons.chevron_right,
                                color: Theme.of(context).colorScheme.tertiary,
                                size: 20),
                          ],
                        ),
                      ),
                    ),

                    const Divider(height: 24, color: Colors.white24),

                    InkWell(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const AccountDeletionScreen()),
                      ),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: const [
                            Icon(Icons.delete_forever,
                                color: Colors.grey, size: 20),
                            SizedBox(width: 12),
                            Text(
                              'Delete Account',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Spacer(),
                            Icon(Icons.chevron_right,
                                color: Colors.white38, size: 20),
                          ],
                        ),
                      ),
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
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              Theme.of(context).colorScheme.secondary,
                          foregroundColor:
                              Theme.of(context).colorScheme.onSecondary,
                        ),
                        child: _saving
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color:
                                      Theme.of(context).colorScheme.onSecondary,
                                ),
                              )
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
