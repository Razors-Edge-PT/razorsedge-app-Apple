import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async'; // for Timer debounce
import 'package:flutter/services.dart'; // for TextInputFormatter
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:provider/provider.dart'; // for context.read()
import 'package:localtest222/user_context.dart'; // <-- adjust path to your actual file
import 'membership_gate.dart';
import 'demographics_cache.dart';
import 'block_repository.dart';
import 'block_planner_repository.dart';
import 'block_exercise_defaults_repository.dart';

import 'package:localtest222/login_screen.dart';
import 'periodization_model_utils.dart';

/// Formats as dd-mm-yyyy while typing. Only digits are accepted; adds '-' after 2 and 4 digits.
class DobDashFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final b = StringBuffer();
    int selIndex = newValue.selection.end;

    for (int i = 0; i < digits.length && i < 8; i++) {
      b.write(digits[i]);
      // insert dashes after 2 and 4 digits
      if (i == 1 || i == 3) {
        b.write('-');
        if (i + 1 < digits.length && newValue.selection.end == i + 1) {
          selIndex++; // keep caret intuitive after auto-dash
        }
      }
    }
    final text = b.toString();
    selIndex = selIndex.clamp(0, text.length);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: selIndex),
    );
  }
}


class CreateNewAccountScreen extends StatefulWidget {
  const CreateNewAccountScreen({super.key});

  @override
  State<CreateNewAccountScreen> createState() => _CreateNewAccountScreenState();
}

class _CreateNewAccountScreenState extends State<CreateNewAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _fullNameController = TextEditingController();
  final TextEditingController _dobController = TextEditingController(); // stores yyyy-mm-dd string
  final TextEditingController _dobDayController = TextEditingController();
  final TextEditingController _dobMonthController = TextEditingController();
  final TextEditingController _dobYearController = TextEditingController();

  final FocusNode _dobDayNode = FocusNode();
  final FocusNode _dobMonthNode = FocusNode();
  final FocusNode _dobYearNode = FocusNode();
  String? _dobInlineError; // shown under the DOB row; also blocks submit


  String? _selectedSex; // 'M' | 'F' | 'N'


  bool _isLoading = false;
  String? _errorMessage;
  bool _passwordVisible = false;
  bool _confirmPasswordVisible = false;
  bool _usernameChecking = false;
  bool? _usernameAvailableFlag; // null = unknown, true = available, false = taken
  Timer? _usernameDebounce;


  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _usernameController.dispose();
    _fullNameController.dispose();
    _dobController.dispose();
    _dobDayController.dispose();
    _dobMonthController.dispose();
    _dobYearController.dispose();
    _dobDayNode.dispose();
    _dobMonthNode.dispose();
    _dobYearNode.dispose();


    super.dispose();
  }

  Future<void> _cleanupNewUserOnFailure() async {
    try { await FirebaseAuth.instance.currentUser?.delete(); }
    catch (e, st) { print('⚠️ Cleanup failed: $e\n$st'); await FirebaseAuth.instance.signOut(); }
  }

  // Accepts "dd-mm-yyyy" or "yyyy-mm-dd"; returns normalized "yyyy-mm-dd" or null
  // Accepts "dd-mm-yyyy" or "yyyy-mm-dd"; returns normalized "dd-mm-yyyy" or null.
  String? _normalizeDob(String input) {
    final s = input.trim();
    final ddmm = RegExp(r'^(\d{2})-(\d{2})-(\d{4})$');      // dd-mm-yyyy
    final ymd  = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');      // yyyy-mm-dd

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

    // Validate date + age range
    try {
      final dt = DateTime(y, m, d);
      if (dt.year != y || dt.month != m || dt.day != d) return null; // invalid like 31/02
      final now = DateTime.now();
      final oldest = DateTime(now.year - 120, now.month, now.day);
      if (dt.isAfter(now) || dt.isBefore(oldest)) return null;
    } catch (_) {
      return null;
    }

    final dd = d.toString().padLeft(2, '0');
    final mm = m.toString().padLeft(2, '0');
    // Store/display as dd-mm-yyyy
    return '$dd-$mm-$y';
  }


  final RegExp _usernameRe = RegExp(r'^.{3,22}$'); // length only, we'll add rules in validator


  Future<bool> _isUsernameAvailable(String username) async {
    final lower = username.toLowerCase();
    final q = await FirebaseFirestore.instance
        .collection('users_public')
        .where('usernameLower', isEqualTo: lower)
        .limit(1)
        .get();

    // If there's a hit, it's taken.
    return q.docs.isEmpty;
  }

  Future<void> _ensureAnonAuthForAvailability() async {
    final auth = FirebaseAuth.instance;
    final user = auth.currentUser;
    if (user == null) {
      try {
        await auth.signInAnonymously();
        print('👤 [Signup] Signed in anonymously for availability checks.');
      } catch (e, st) {
        print('⚠️ [Signup] Anonymous sign-in failed: $e\n$st');
        // We’ll still let the form work; avail checks will fail if rules require auth.
      }
    }
  }

  void _onUsernameChanged(String raw) {
    _usernameDebounce?.cancel();
    final v = raw.trim();

    // Reset quick flags
    setState(() {
      _usernameAvailableFlag = null;
      _usernameChecking = false;
    });

    // Quick local format check (same regex you already use)
    if (!_usernameRe.hasMatch(v)) {
      return; // show validator message on submit; no remote check
    }

    _usernameDebounce = Timer(const Duration(milliseconds: 450), () async {
      setState(() => _usernameChecking = true);
      try {
        final ok = await _isUsernameAvailable(v); // now hits users_public
        setState(() => _usernameAvailableFlag = ok);
        print('🔎 [Username] "$v" → ${ok ? 'available' : 'taken'}');
      } catch (e, st) {
        print('❌ [Username] availability check failed: $e\n$st');
        // keep flag null → silent failure, validator still handles on submit
      } finally {
        if (mounted) setState(() => _usernameChecking = false);
      }
    });
  }

  void _syncDobFromParts() {
    final now = DateTime.now();
    final dd = _dobDayController.text;
    final mm = _dobMonthController.text;
    final yy = _dobYearController.text;

    // Recompose into hidden _dobController for the validator
    if (dd.length == 2 && mm.length == 2 && yy.length == 4) {
      _dobController.text = '${dd.padLeft(2, '0')}-${mm.padLeft(2, '0')}-${yy}';
    } else {
      _dobController.text = ''; // incomplete -> validator will fail
    }

    // Inline guardrails & fun messages
    String? err;
    final day  = int.tryParse(dd);
    final mon  = int.tryParse(mm);
    final year = int.tryParse(yy);

    if (year != null && yy.length == 4) {
      if (year < 1900) {
        err = 'I call BS! you are not that old.';
      } else if (year > now.year) {
        err = 'No time travelers yet 😉';
      } else {
        final oldest = now.year - 120;
        if (year < oldest) {
          err = 'I call BS! you are not that old.';
        }
      }
    }

    // We don’t fully validate “31-02” here—your form validator will catch that.
    setState(() => _dobInlineError = err);
  }



  void _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text.trim();
      final username = _usernameController.text.trim();
      final fullName = _fullNameController.text.trim();
      final dobRaw   = _dobController.text.trim();
      final sex      = _selectedSex; // 'M' | 'F' | 'N'

      // Normalize and validate DOB again (belt & braces; validator already runs)
      final dobNormalized = _normalizeDob(dobRaw);
      if (dobNormalized == null) {
        setState(() { _errorMessage = 'Please enter a valid date of birth.'; _isLoading = false; });
        return;
      }

      // Create the user
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        // displayName = username
        if (username.isNotEmpty) {
          await user.updateDisplayName(username);
        }

        // Now that we are signed in, check availability
        final ok = await _isUsernameAvailable(username);

        if (!ok) {
          await _cleanupNewUserOnFailure();
          setState(() {
            _errorMessage = 'That username is taken by your nemesis. Please choose another.';
            _isLoading = false;
          });
          return;
        }

        final payload = {
          'email': user.email,
          'username': username,
          'usernameLower': username.toLowerCase(),
          'fullName': fullName,
          'dob': dobNormalized,   // stored as yyyy-mm-dd (string)
          'sex': sex,             // 'M'|'F'|'N'
          'createdAt': FieldValue.serverTimestamp(),
        };

        // Write to users
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .set(payload, SetOptions(merge: true));

        // Mirror to users_public (same info, per your note)
        await FirebaseFirestore.instance
            .collection('users_public')
            .doc(user.uid)
            .set(payload, SetOptions(merge: true));
      }

      if (mounted) {
        Navigator.pushReplacementNamed(context, '/home');
      }

    } on FirebaseAuthException catch (e) {
      String message;
      switch (e.code) {
        case 'email-already-in-use':
          message = 'This email is already in use.';
          break;
        case 'invalid-email':
          message = 'Invalid email format.';
          break;
        case 'weak-password':
          message = 'Password is too weak.';
          break;
        default:
          message = 'Registration failed. (${e.message})';
      }
      setState(() { _errorMessage = message; });
    } catch (e, st) {
      // Debug print full error + stack trace
      print('❌ [Register] Unexpected error: $e\n$st');
      setState(() { _errorMessage = 'An unexpected error occurred.'; });
    }
    finally {
      if (mounted) {
        setState(() { _isLoading = false; });
      }
    }
  }

  void _continueToOnboarding() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text.trim();
      final username = _usernameController.text.trim();
      final fullName = _fullNameController.text.trim();
      final dobRaw   = _dobController.text.trim();
      final sex      = _selectedSex; // 'M' | 'F' | 'N'

      // Re-normalize DOB (same rules as your validator)
      final dobNormalized = _normalizeDob(dobRaw);
      if (dobNormalized == null) {
        setState(() { _errorMessage = 'Please enter a valid date of birth.'; _isLoading = false; });
        return;
      }

      // Optional: if your availability flag exists, block if it's explicitly false
      if (_usernameAvailableFlag == false) {
        setState(() { _errorMessage = 'That username is taken by your nemesis. Please choose another.'; _isLoading = false; });
        return;
      }

      // Navigate to Page 2 (no account creation yet)
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OnboardingPageTwo(
            // pass everything needed to create the account later
            email: email,
            password: password,
            username: username,
            fullName: fullName,
            dob: dobNormalized, // yyyy-mm-dd
            sex: sex,
          ),
        ),
      );
    } catch (e, st) {
      print('❌ [_continueToOnboarding] $e\n$st');
      setState(() { _errorMessage = 'Something went wrong. Please try again.'; });
    } finally {
      if (mounted) setState(() { _isLoading = false; });
    }
  }


  @override
  void initState() {
    super.initState();
    _ensureAnonAuthForAvailability();
  }



  @override
  Widget build(BuildContext context) {
    double keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background image
          Image.asset(
            'assets/login_fill.png',
            fit: BoxFit.cover,
          ),
          // Foreground content
          SafeArea(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: MediaQuery.of(context).size.height,
                ),
                child: IntrinsicHeight(
                  child: Column(
                    children: [
                      const Spacer(flex: 2),
                      AnimatedOpacity(
                        opacity: keyboardHeight > 0 ? 0.0 : 1.0,
                        duration: const Duration(milliseconds: 300),
                        child: Center(
                          child: Image.asset(
                            'assets/re_banner.png',
                            height: 100,
                          ),
                        ),
                      ),
                      const Spacer(flex: 1),
                      Card(
                        elevation: 10,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        color: Colors.white.withOpacity(0.9),
                        margin: const EdgeInsets.all(20),
                        child: Padding(
                          padding: const EdgeInsets.all(20.0),
                          child: Form(
                            key: _formKey,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  "Create Account",
                                  style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black54),
                                ),
                                const SizedBox(height: 16),

                                // Username (required)
                                TextFormField(
                                  controller: _usernameController,
                                  textInputAction: TextInputAction.next,
                                  style: const TextStyle(color: Colors.black54),
                                  decoration: InputDecoration(
                                    labelText: 'Username',
                                    labelStyle: const TextStyle(color: Colors.blueAccent),
                                    hintText: '3–22 chars. Go wild 🎉',
                                    hintStyle: TextStyle(
                                      color: Colors.blueAccent.withOpacity(0.6),
                                      fontSize: 16,
                                    ),
                                    suffixIcon: (_usernameChecking)
                                        ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: SizedBox(
                                        width: 16, height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                    )
                                        : (_usernameAvailableFlag == null
                                        ? null
                                        : Icon(
                                      _usernameAvailableFlag! ? Icons.check_circle : Icons.error,
                                      color: _usernameAvailableFlag! ? Colors.green : Colors.redAccent,
                                    )),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.blueAccent),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.lightBlue, width: 2),
                                    ),
                                    errorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.red),
                                    ),
                                    focusedErrorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.redAccent, width: 2),
                                    ),
                                  ),
                                  onChanged: _onUsernameChanged, // 👈 live availability
                                  validator: (value) {
                                    final v = (value ?? '').trim();
                                    if (v.isEmpty) return 'Please choose a username';
                                    if (!_usernameRe.hasMatch(v)) return '3–22 chars. Go wild 🎉';
                                    if (v.contains(' ')) return 'No spaces allowed';
                                    if (_usernameAvailableFlag == false) return 'That username is taken by your nemesis. Please choose another.';
                                    return null;
                                  },

                                ),

                                if (_usernameAvailableFlag == false) ...[
                                  const SizedBox(height: 6),
                                  const Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text('That username is taken by your nemesis. Please choose another.', style: TextStyle(color: Colors.redAccent)),
                                  ),
                                ] else if (_usernameAvailableFlag == true) ...[
                                  const SizedBox(height: 6),
                                  const Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text('Nice — available!', style: TextStyle(color: Colors.green)),
                                  ),
                                ],


                                const SizedBox(height: 12),

// Full Name (required)
                                TextFormField(
                                  controller: _fullNameController,
                                  textCapitalization: TextCapitalization.words,
                                  style: const TextStyle(color: Colors.black54),
                                  decoration: InputDecoration(
                                    labelText: 'Full Name',
                                    labelStyle: const TextStyle(color: Colors.blueAccent),
                                    hintText: 'Your legal/full name',
                                    hintStyle: TextStyle(
                                      color: Colors.blueAccent.withOpacity(0.6),
                                      fontSize: 16,
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.blueAccent),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.lightBlue, width: 2),
                                    ),
                                    errorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.red),
                                    ),
                                    focusedErrorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.redAccent, width: 2),
                                    ),
                                  ),
                                  validator: (value) {
                                    if (value == null || value.trim().isEmpty) return 'Please enter your full name';
                                    return null;
                                  },
                                ),

                                const SizedBox(height: 12),

                                const SizedBox(height: 12),

// Date of Birth (required; DD / MM / YYYY numeric fields → stored as dd-mm-yyyy)
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    InputDecorator(
                                      decoration: InputDecoration(
                                        labelText: 'Date of Birth',
                                        labelStyle: const TextStyle(color: Colors.blueAccent),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: const BorderSide(color: Colors.blueAccent),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: const BorderSide(color: Colors.lightBlue, width: 2),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          // DD
                                          SizedBox(
                                            width: 56,
                                            child: TextField(
                                              controller: _dobDayController,
                                              focusNode: _dobDayNode,
                                              keyboardType: TextInputType.number,
                                              textInputAction: TextInputAction.next,
                                              style: const TextStyle(color: Colors.blueAccent), // numbers typed appear light blue
                                              decoration: InputDecoration(
                                                hintText: 'DD',
                                                hintStyle: const TextStyle(color: Colors.blueAccent), // placeholder "DD" in light blue
                                                counterText: '',
                                                isDense: true,
                                                border: InputBorder.none,
                                              ),
                                              maxLength: 2,
                                              onChanged: (v) {
                                                var digits = v.replaceAll(RegExp(r'\D'), '');
                                                if (digits.length > 2) digits = digits.substring(0, 2);

                                                if (digits.length == 2) {
                                                  final iv = int.tryParse(digits) ?? 0;
                                                  if (iv > 31) digits = '31';
                                                }

                                                if (digits != v) {
                                                  _dobDayController.text = digits;
                                                  _dobDayController.selection =
                                                      TextSelection.collapsed(offset: digits.length);
                                                }

                                                if (digits.length == 2) _dobMonthNode.requestFocus();
                                                _syncDobFromParts();
                                              },
                                            ),
                                          ),

                                          const Padding(
                                            padding: EdgeInsets.symmetric(horizontal: 4),
                                            child: Text('-', style: TextStyle(color: Colors.black54)),
                                          ),

                                          // MM
                                          SizedBox(
                                            width: 56,
                                            child: TextField(
                                              controller: _dobMonthController,
                                              focusNode: _dobMonthNode,
                                              keyboardType: TextInputType.number,
                                              textInputAction: TextInputAction.next,
                                              style: const TextStyle(color: Colors.blueAccent), // numbers typed appear light blue
                                              decoration: InputDecoration(
                                                hintText: 'MM',
                                                hintStyle: const TextStyle(color: Colors.blueAccent), // placeholder "DD" in light blue
                                                counterText: '',
                                                isDense: true,
                                                border: InputBorder.none,
                                              ),
                                              maxLength: 2,
                                              onChanged: (v) {
                                                var digits = v.replaceAll(RegExp(r'\D'), '');
                                                if (digits.length > 2) digits = digits.substring(0, 2);

                                                // Cap at 12
                                                if (digits.length == 2) {
                                                  final iv = int.tryParse(digits) ?? 0;
                                                  if (iv > 12) digits = '12';
                                                }

                                                if (digits != v) {
                                                  _dobMonthController.text = digits;
                                                  _dobMonthController.selection = TextSelection.collapsed(offset: digits.length);
                                                }

                                                if (digits.length == 2) _dobYearNode.requestFocus();
                                                _syncDobFromParts();
                                              },

                                            ),
                                          ),
                                          const Padding(
                                            padding: EdgeInsets.symmetric(horizontal: 4),
                                            child: Text('-', style: TextStyle(color: Colors.black54)),
                                          ),

                                          // YYYY
                                          Expanded(
                                            child: TextField(
                                              controller: _dobYearController,
                                              focusNode: _dobYearNode,
                                              keyboardType: TextInputType.number,
                                              textInputAction: TextInputAction.next,
                                              style: const TextStyle(color: Colors.blueAccent), // numbers typed appear light blue
                                              decoration: InputDecoration(
                                                hintText: 'YYYY',
                                                hintStyle: const TextStyle(color: Colors.blueAccent), // placeholder "DD" in light blue
                                                counterText: '',
                                                isDense: true,
                                                border: InputBorder.none,
                                                suffixIcon: null,
                                              ),
                                              maxLength: 4,
                                              onChanged: (v) {
                                                var digits = v.replaceAll(RegExp(r'\D'), '');
                                                if (digits.length > 4) digits = digits.substring(0, 4);

                                                if (digits != v) {
                                                  _dobYearController.text = digits;
                                                  _dobYearController.selection = TextSelection.collapsed(offset: digits.length);
                                                }

                                                _syncDobFromParts();
                                              },

                                            ),
                                          ),

                                          // Calendar button
                                          IconButton(
                                            icon: const Icon(Icons.calendar_today, color: Colors.blueAccent),
                                            onPressed: () async {
                                              final now = DateTime.now();
                                              final firstDate = DateTime(now.year - 120, now.month, now.day);
                                              final lastDate  = DateTime(now.year, now.month, now.day);
                                              final picked = await showDatePicker(
                                                context: context,
                                                firstDate: firstDate,
                                                lastDate: lastDate,
                                                initialDate: DateTime(now.year - 25, now.month, now.day),
                                              );
                                              if (picked != null) {
                                                _dobDayController.text = picked.day.toString().padLeft(2, '0');
                                                _dobMonthController.text = picked.month.toString().padLeft(2, '0');
                                                _dobYearController.text = picked.year.toString();
                                                _syncDobFromParts();
                                                setState(() {}); // refresh any error text
                                              }
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (_dobInlineError != null) ...[
                                      const SizedBox(height: 6),
                                      Text(_dobInlineError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                                    ],


                                    // Hidden validator field that the Form uses (reads _dobController)
                                    SizedBox(
                                      height: 0, width: 0,
                                      child: TextFormField(
                                        controller: _dobController,
                                        validator: (value) {
                                          if (_dobInlineError != null) return _dobInlineError; // block with inline reason
                                          if (value == null || value.trim().isEmpty) return 'Please enter your date of birth';

                                          final normalized = _normalizeDob(value); // also checks real calendar date + 120y window
                                          if (normalized == null) return 'Enter a valid date (dd-mm-yyyy)';
                                          _dobController.text = normalized; // keep canonical
                                          return null;
                                        },

                                      ),
                                    ),
                                  ],
                                ),


                                const SizedBox(height: 12),

// Sex (required)
                                DropdownButtonFormField<String>(
                                  value: _selectedSex,
                                  style: const TextStyle(color: Colors.black87),
                                  decoration: InputDecoration(
                                    labelText: 'Sex',
                                    labelStyle: const TextStyle(color: Colors.blueAccent),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.blueAccent),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.lightBlue, width: 2),
                                    ),
                                    errorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.red),
                                    ),
                                    focusedErrorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.redAccent, width: 2),
                                    ),
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'M',
                                      child: Text('Male', style: TextStyle(color: Colors.black87)),
                                    ),
                                    DropdownMenuItem(
                                      value: 'F',
                                      child: Text('Female', style: TextStyle(color: Colors.black87)),
                                    ),
                                    DropdownMenuItem(
                                      value: 'N',
                                      child: Text('Yes.', style: TextStyle(color: Colors.black87)),
                                    ),
                                  ],
                                  onChanged: (v) => setState(() => _selectedSex = v),
                                ),
                                const SizedBox(height: 12),
                                // Email
                                TextFormField(
                                  controller: _emailController,
                                  keyboardType: TextInputType.emailAddress,
                                  style: const TextStyle(color: Colors.black54),
                                  decoration: InputDecoration(
                                    labelText: 'Email',
                                    labelStyle: const TextStyle(color: Colors.blueAccent),
                                    hintText: 'Enter your email',
                                    hintStyle: TextStyle(
                                        color: Colors.blueAccent.withOpacity(0.6),
                                        fontSize: 16),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide:
                                      const BorderSide(color: Colors.blueAccent),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(
                                          color: Colors.lightBlue, width: 2),
                                    ),
                                    errorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.red),
                                    ),
                                    focusedErrorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(
                                          color: Colors.redAccent, width: 2),
                                    ),
                                  ),
                                  validator: (value) {
                                    if (value == null || value.isEmpty)
                                      return 'Please enter your email';
                                    if (!RegExp(r'^[^@]+@[^@]+\.[^@]+')
                                        .hasMatch(value)) {
                                      return 'Enter a valid email';
                                    }
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 12),

                                // Password
                                TextFormField(
                                  controller: _passwordController,
                                  obscureText: !_passwordVisible,
                                  style: const TextStyle(color: Colors.black54),
                                  decoration: InputDecoration(
                                    labelText: 'Password',
                                    labelStyle: const TextStyle(color: Colors.blueAccent),
                                    hintText: 'Enter your password',
                                    hintStyle: TextStyle(
                                      color: Colors.blueAccent.withOpacity(0.6),
                                      fontSize: 16,
                                    ),
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                        _passwordVisible ? Icons.visibility : Icons.visibility_off,
                                        color: Colors.blueAccent,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _passwordVisible = !_passwordVisible;
                                        });
                                      },
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.blueAccent),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.lightBlue, width: 2),
                                    ),
                                    errorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.red),
                                    ),
                                    focusedErrorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.redAccent, width: 2),
                                    ),
                                  ),
                                  validator: (value) {
                                    if (value == null || value.isEmpty) return 'Please enter a password';
                                    if (value.length < 6) return 'Minimum 6 characters';
                                    return null;
                                  },
                                ),

                                const SizedBox(height: 12),

                                // Confirm Password
                                // Confirm Password
                                TextFormField(
                                  controller: _confirmPasswordController,
                                  obscureText: !_confirmPasswordVisible,
                                  style: const TextStyle(color: Colors.black54),
                                  decoration: InputDecoration(
                                    labelText: 'Confirm Password',
                                    labelStyle: const TextStyle(color: Colors.blueAccent),
                                    hintText: 'Re-enter your password',
                                    hintStyle: TextStyle(
                                      color: Colors.blueAccent.withOpacity(0.6),
                                      fontSize: 16,
                                    ),
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                        _confirmPasswordVisible ? Icons.visibility : Icons.visibility_off,
                                        color: Colors.blueAccent,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _confirmPasswordVisible = !_confirmPasswordVisible;
                                        });
                                      },
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.blueAccent),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.lightBlue, width: 2),
                                    ),
                                    errorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.red),
                                    ),
                                    focusedErrorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.redAccent, width: 2),
                                    ),
                                  ),
                                  validator: (value) {
                                    if (value != _passwordController.text) return "Passwords do not match";
                                    return null;
                                  },
                                ),


                                const SizedBox(height: 12),

                                if (_errorMessage != null)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    child: Text(
                                      _errorMessage!,
                                      style: const TextStyle(color: Colors.red),
                                    ),
                                  ),

                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                      backgroundColor: Colors.blueAccent,
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12)),
                                    ),
                                    onPressed: _isLoading ? null : _continueToOnboarding,
                                    child: _isLoading
                                        ? const CircularProgressIndicator(
                                        color: Colors.white)
                                        : const Text(
                                      'Continue',
                                      style: TextStyle(fontSize: 18),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20.0),
                        child: TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                          },
                          child: const Text(
                            "Already have an account? Log in",
                            style: TextStyle(
                              color: Colors.blueAccent,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),

                      const Spacer(flex: 3),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

}

// ─────────────────────────────────────────────────────────────────────────────
// Page 2: Onboarding (Goals, Focus, Injuries, Experience, Best Efforts)
// All fields are optional in the model; UI enforces "required" where needed.
// ─────────────────────────────────────────────────────────────────────────────

enum TrainingExperience { never, lt6mo, oneYear, twoPlus }

class BestEffort {
  final String liftKey;     // e.g. 'bench_barbell', 'bench_db', 'squat', 'leg_press', 'chinup', 'lat_pulldown', 'deadlift'
  final double? weightKg;
  final int? reps;
  const BestEffort({ this.liftKey = '', this.weightKg, this.reps });

  Map<String, dynamic> toJson() => {
    'liftKey': liftKey,
    'weightKg': weightKg,
    'reps': reps,
  };

  factory BestEffort.fromJson(Map<String, dynamic> j) => BestEffort(
    liftKey: (j['liftKey'] ?? '') as String,
    weightKg: (j['weightKg'] as num?)?.toDouble(),
    reps: (j['reps'] as num?)?.toInt(),
  );
}

class OnboardingAnswers {
  final List<String>? goalsRanked;
  final List<String>? bodyFocus;
  final Map<String, int>? painNow;
  final List<String>? injuries;
  final TrainingExperience? experience;
  final List<BestEffort>? bestEfforts;
  final int? minTrainingDaysPerWeek; // existing
  final int? trainingEffort; // 👈 NEW
  final DateTime? createdAt;
  final String? version;

  const OnboardingAnswers({
    this.goalsRanked,
    this.bodyFocus,
    this.painNow,
    this.injuries,
    this.experience,
    this.bestEfforts,
    this.minTrainingDaysPerWeek,
    this.trainingEffort, // 👈 NEW
    this.createdAt,
    this.version,
  });

  Map<String, dynamic> toJson() => {
    'goalsRanked': goalsRanked,
    'bodyFocus': bodyFocus,
    'painNow': painNow,
    'injuries': injuries,
    'experience': experience?.name,
    'bestEfforts': bestEfforts?.map((b) => b.toJson()).toList(),
    'minTrainingDaysPerWeek': minTrainingDaysPerWeek,
    'trainingEffort': trainingEffort, // 👈 NEW
    'createdAt': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
    'version': version ?? 'v1',
  };


  factory OnboardingAnswers.fromJson(Map<String, dynamic> j) => OnboardingAnswers(
    goalsRanked: (j['goalsRanked'] as List?)?.map((e) => e.toString()).toList(),
    bodyFocus: (j['bodyFocus'] as List?)?.map((e) => e.toString()).toList(),
    painNow: (j['painNow'] as Map?)?.map((k, v) => MapEntry(k.toString(), (v as num).toInt())),
    injuries: (j['injuries'] as List?)?.map((e) => e.toString()).toList(),
    experience: _expFromString(j['experience']),
    bestEfforts: (j['bestEfforts'] as List?)
        ?.map((e) => BestEffort.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    minTrainingDaysPerWeek: (j['minTrainingDaysPerWeek'] as num?)?.toInt(), // 👈 NEW
    trainingEffort: (j['trainingEffort'] as num?)?.toInt(), // 👈 add this
    createdAt: (j['createdAt'] != null) ? DateTime.tryParse(j['createdAt'].toString()) : null,
    version: j['version']?.toString(),
  );


  static TrainingExperience? _expFromString(dynamic v) {
    final s = v?.toString();
    if (s == null) return null;
    return TrainingExperience.values.firstWhere(
          (e) => e.name == s,
      orElse: () => TrainingExperience.never,
    );
  }
}

class OnboardingPageTwo extends StatefulWidget {
  final String email;
  final String password;
  final String? sex;       // 'M' | 'F' | 'N'
  final String? username;
  final String? fullName;
  final String? dob;       // yyyy-mm-dd

  const OnboardingPageTwo({
    Key? key,
    required this.email,
    required this.password,
    this.sex,
    this.username,
    this.fullName,
    this.dob,
  }) : super(key: key);

  @override
  State<OnboardingPageTwo> createState() => _OnboardingPageTwoState();
}

class _OnboardingPageTwoState extends State<OnboardingPageTwo> {
  final _formKey = GlobalKey<FormState>();

  // ── A) Goals: start with full list; user reorders to set priority.
  List<String> _goals = [
    'Get stronger',
    'Build more muscle',
    'Get fitter',
    'Powerlifting',
    'Get leaner',
    'Feel healthier / move better',
    'Tone and shape',
    'Defeat my gym nemesis',
    'Power-Building',
    'Bench Press Specialist',
  ].toList();

  List<String> _notImportantGoals = [];


  // ── B) Body focus (conditional if “muscle/toned” is relevant): simple checklist for v1
  final List<String> _bodyParts = const [
    'Chest', 'Back', 'Shoulders', 'Arms', 'Abs', 'Glutes', 'Quads', 'Hamstrings', 'Calves'
  ];
  // Order to use when "More specific" is ON
  static const List<String> _bodyPartsSpecificOrder = [
    'Chest','Abs','Hamstrings','Quads','Calves','Glutes','Back','Shoulders','Arms',
  ];

  final Set<String> _bodyFocus = <String>{};
  // 0 = off, 1 = light, 2 = medium, 3 = strong
  final Map<String, int> _bodyFocusLevel = <String, int>{};

  // Toggle to reveal child muscles
  bool _moreSpecific = false;

// Parent → child muscles
  final Map<String, List<String>> _subGroups = const {
    // Back
    'Back': ['Lats', 'Mid traps & rear delts', 'Lower back 🎄'],
    // Shoulders
    'Shoulders': ['Anterior delts', 'Lateral delts', 'Upper traps'],
    // Arms
    'Arms': ['Biceps', 'Triceps', 'Forearms'],
    // Glutes
    'Glutes': ['Glute Maximus', 'Glute Medius'],
    // (You can add more later if you want)
  };

// Child emphasis levels: parent → (child → 0..3)
  final Map<String, Map<String, int>> _childFocusLevel = {};



  // Shoulder / elbow detail flags
  bool _shoulderPainOverhead = false;
  bool _shoulderPainFront   = false;
  bool _elbowPainInside     = false;
  bool _elbowPainOutside    = false;

  // ── C) Injuries: checkboxes + per-item pain slider (1–10) when checked
  final List<String> _injuryKeys = const [
    'Lower back',
    'Mid back',
    'Upper back',
    'Knees',
    'Shoulders',
    'Elbows',
    'Neck',
    'Wrists',
    'Ankles',
  ];

  // ── Equipment / environment
  String? _env; // 'commercial' | 'powerlifting' | 'home' | 'travelling'
  final Set<String> _equipSelected = <String>{};
  int? _dbMax; // dumbbell max (e.g., 40, 50, 60)

// Label lists per environment
  static const List<String> _powerEquip = [
    'Micro Plates',
    'Power Bands',
    'Chains',
    'Leg Extension Machine',
    'Seated Leg Curl Machine',
    'Standing Leg Curl Machine',
    'lying Leg Curl Machine',
    'Leg Press',
    'Lat Pull Down',
    'Cable Stack',
    'Suspension Training system',
    '45 Degree Hip Extension',
  ];
  static const List<int> _powerDb = [40, 50, 60];

  static const List<String> _homeEquip = [
    'Squat Rack, Barbell',
    'Bench Press, Barbell',
    'Smith Machine',
    '45 Degree Hip Extension',
    'Leg Extension Machine',
    'Seated Leg Curl Machine',
    'Standing Leg Curl Machine',
    'lying Leg Curl Machine',
    'Leg Press',
    'Hack Squat',
    'Chest Press Machine',
    'Seated Row',
    'Lat Pull Down',
    'Cable Stack',
    'Suspension Training system',
    'Seated Calf Raise',
  ];
  static const List<int> _homeDb = [10, 20, 30, 40, 50, 60];

  static const List<String> _travelEquip = [
    'Suspension training system',
    'Resistance Bands',
    'Back pack you can add weight to, or similar',
  ];

  // ── Commercial gym equipment (full list shown)
  final List<String> _commercialEquip = const [
    'Seated leg curl',
    'Standing Leg Curl Machine',
    '45 Degree Hip Extension',
    'Hack Squat',
    'Triceps Dip Machine',
    'Machine Hip Thrust',
    'Suspension Training System (like TRX)',
    'Seated Calf Raise',
    // add any other commercial items you want to show here...
  ];

// ── Defaults pre-selected for commercial gyms
  final Set<String> _commercialDefaults = const {
    'Seated leg curl',
    'Standing Leg Curl Machine',
    '45 Degree Hip Extension',
    'Hack Squat',
    'Triceps Dip Machine',
    'Machine Hip Thrust',
    'Suspension Training System (like TRX)',
    'Seated Calf Raise',
  };


  int? _ptHistory; // 0..3 (null = not chosen)

  final Set<String> _injuries = <String>{};
  final Map<String, double> _painSlider = {}; // store slider as double 1..10; round to int when saving

  // ── D) Experience: radio
  TrainingExperience? _experience;

  // ── E) Optional best efforts (free text; we’ll parse “100 x 5” loosely)
  final TextEditingController _benchCtrl = TextEditingController();
  final TextEditingController _squatCtrl = TextEditingController();
  final TextEditingController _pullCtrl  = TextEditingController(); // chinup/lat pulldown
  final TextEditingController _deadCtrl  = TextEditingController();

  String _benchVariant = 'Bench Press';
  String _squatVariant = 'Back Squat';
  String _pullVariant  = 'Lat Pull Down, Supinated';
  String _deadVariant  = 'Deadlift';

  // ▼ New: separate weight + reps controllers for each
  final TextEditingController _benchWeightCtrl = TextEditingController();
  final TextEditingController _benchRepsCtrl   = TextEditingController();

  final TextEditingController _squatWeightCtrl = TextEditingController();
  final TextEditingController _squatRepsCtrl   = TextEditingController();

  final TextEditingController _pullWeightCtrl  = TextEditingController();
  final TextEditingController _pullRepsCtrl    = TextEditingController();

  final TextEditingController _deadWeightCtrl  = TextEditingController();
  final TextEditingController _deadRepsCtrl    = TextEditingController();

  int? _minTrainingDays; // 2–7, chosen on this page


  bool _saving = false;

  bool get _muscleOrTonedChosen {
    // if “Build more muscle” OR “Get leaner” OR “Feel more toned” appears high, we can encourage body focus
    return _goals.contains('Build more muscle') || _goals.contains('Get leaner');
  }

  int? _trainingEffort; // 1..4, optional
  List<String> _trainingEffortLabels = const []; // built from sex + dob

  Future<void> _ensureAtLeastOneBlockExists() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final swTotal = Stopwatch()..start();

    final uid = user.uid;
    final blocksRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks');

    final existingBlocks = await blocksRef.get();

    if (existingBlocks.docs.isEmpty) {
      // ── Fetch username & sex from /users/{uid} ───────────────────────────────
      final usersRef = FirebaseFirestore.instance.collection('users').doc(uid);
      final userSnap = await usersRef.get();
      final data = userSnap.data() ?? {};

      // 🔒 Gate: wait until /users has core fields (prevents female default)
      final hasCore = userSnap.exists &&
          (data['username'] != null || data['fullName'] != null);

      if (!hasCore) {
        debugPrint('🛑 [Home] Block gate: /users/$uid incomplete → retry in 800ms');
        // tiny, non-blocking retry; won’t slow first paint
        unawaited(Future.delayed(const Duration(milliseconds: 800), () async {
          await _ensureAtLeastOneBlockExists();
        }));
        return;
      }

      print('🔎 [Home] Reading /users/$uid  exists=${userSnap.exists}');
      print('🔎 [Home] /users/$uid keys=${data.keys.toList()}');

      final usernameFromDoc = (data['username'] as String?)?.trim();
      final sexRawFromDoc   = (data['sex'] as String?)?.trim();

      // Fallbacks so we still name the block if the user doc isn't ready yet:
      final auth = FirebaseAuth.instance.currentUser!;
      final fallbackUsername = (auth.displayName?.trim().isNotEmpty == true)
          ? auth.displayName!.trim()
          : (auth.email?.split('@').first ?? '').trim();

      final username = (usernameFromDoc?.isNotEmpty == true)
          ? usernameFromDoc
          : (fallbackUsername.isNotEmpty ? fallbackUsername : null);

      final sex = (sexRawFromDoc == null || sexRawFromDoc.isEmpty)
          ? 'N'  // default → treated as female branch per your rules
          : sexRawFromDoc.toUpperCase();

      print('🧬 [Home] Using uid=$uid username="$username" sex="$sex"');

      final isFemale = sex == 'F' || sex == 'N';
      print('🧬 [Home] Template branch = ${isFemale ? 'FEMALE' : 'MALE'}');

      // Block names
      final block1Name = (username != null && username.isNotEmpty)
          ? "${username}'s First Block"
          : "1st Block";
      final block2Name = (username != null && username.isNotEmpty)
          ? "${username}'s 2nd Block"
          : "2nd Block";

      print('🆕 [Home] No blocks found — creating "$block1Name" and "$block2Name"...');

      // ── Dates: start = Monday of the current week ("Monday just gone") ──────
      final now = DateTime.now();

      // Normalize to date-only (midnight) to avoid time-of-day drift in Firestore dates
      final today = DateTime(now.year, now.month, now.day);

      // DateTime.weekday: Mon=1 ... Sun=7
      final startDate1 = today.subtract(Duration(days: today.weekday - DateTime.monday));

      // 8 weeks = 56 days total. If start is day 0, last day is start + 55.
      final endDate1 = startDate1.add(const Duration(days: 55));

      // Next blocks start the day after the previous ends
      final startDate2 = endDate1.add(const Duration(days: 1));
      final endDate2   = startDate2.add(const Duration(days: 55));

      final startDate3 = endDate2.add(const Duration(days: 1));
      final endDate3   = startDate3.add(const Duration(days: 55));

      debugPrint('📅 [Home] Block1 start=${startDate1.toIso8601String()} end=${endDate1.toIso8601String()} (today=${today.toIso8601String()})');



      // ── Base exercise IDs (shared by both sexes) ─────────────────────────────
      const baseExercises = <String>[
        'AmfUWbF1DH3I7qPAdh5k', // Bench Press, Barbell
        'kTs5fLSTKjUkUZL10iii', // Flat Bench Dumbbell Press
        'heeBViVINHO6tUScSd6y', // Back Squat, Barbell
        'y5q9OU9OBzZQMkfPzFrf', // Romanian Deadlift
        'v2XlZUvFfBUhogOdKtJ8', // Leg Press
        'lVDG90yN6Z8aPjRNV2wc', // Overhead Barbell Press
        '2yJSfLMfOnNDSeZ7DqZT', // Overhead Dumbbell Press
        '9siQpXF2KLCj7M9kCy2m', // Seated Shoulder Dumbbell Press
        '1XOIXxeLFhgmgjZS9Cyq', // Lat Pull Down, Supinated
        'Url65Q2RxZa00dkDpUdl', // Lat Pull Down, Wide Arm
        'JbthLLjMF6xRvvaUY8PU', // Lat Pull Down, Unilateral
        'ETm055bydWtUCxTMu3MR', // Seated Leg Curl
        'wIcMsf2J9cswJRs1GuYX', // Lying Leg Curl
        'QkEgE8gnIva2kkNJEfxw', // Leg Extension
        'ZKpGshMxFl2dxNmYSATj', // Leg Extension, Unilateral
        'ci3KpMTEacH4bw8ZumJW', // Standing Calf Raise
        'spGqXXReJNHMcc62YgZX', // Seated Calf Raise

        '0dZrCqZ8M7Q1sAn0zeeb', // Dumbbell Biceps Curl
        'zn5PgKNRrWo1MTE4wnCy', // Bayesian Biceps Curl
        'E6jPE8YYR0KA3xtVaKJo', // Triceps Push Down
        'QacImADmlpljltUvB0dD', // Overhead Cable Triceps Extension
        'eeEXnmSXv90q0rUgGECq', // KP Face Pull
        'KPewxxYYrhsOp84lIQr5', // Suspended High Row
        'P88Vj5pBydqmiEzFowag', // Hanging Straight Leg Raise
        'uY8uJaSFK9czKIX4TLc4', // Machine Chest Press
        'FtayDmR5BVnGS1FX1XLL', // Triceps Dip
        'OJaMXFKgMnM0X5xttBE1', // Cable Face Pull
        '6SGWrCKfe7KQLThRYXQ6', // One Arm Row, Dumbbell
        'Z1LpfaEBvHBDMsJ54pgw', // Hack Squat
        'z5gs1ilr4DpKlSZaRNG5', // Overhead Cable Triceps Extension, Unilateral
        'LVMQEQl6ZWBcgEUdk2tP', // Leg Press Calf Raise
        'ISXQqOEXLjMrPEs0xjgJ', // Bulgarian Split Squat
        'ocNWJv7xLrlinGmjG6cV', // Machine Row, Supported
        'eyh76KELuuO805rZBpMa', // 45 Degree Hip Extension
        'RdsGazgdH0xgpjek0n3u', // Overhead Dumbbell Press, Unilateral
        'xWpCQO504iGfU3LKLZlD', // Cable High Row, Unilateral
        'XM9026peNIu0R8qh7UqY', // Chin-Up


      ];

      // ── Male-specific exercises ─────────────────────────────────────────────
      const maleSpecificExercises = <String>[
        '6d9Ud7ffAHpljWsSKrFe', // Seated Face Pull
        'TBSudbow1OLdX6mSCC6S', // Machine Chest Fly
        '72HAT6Od4iJodEFxzw62', // Machine Reverse Fly
        'igNo9pSuaOFt0GVX0zBG', // Cable Lateral Raise
        'ZKrfhPhJIiC1hRuwBEw1', // Bayesian Fly
        'RcC48r0oLsNCH798d3jc', // Butterfly Dumbbell Raise
        'ewJBWuDzj1CxfQ3vI3QS', // Reverse Bayesian Fly
        '8saP9lWMoQffuh30A99K', // Lat Prayer
        '0s4yMXygBXZZJH66Yi6h', // Seated Face Pull, Unilateral
      ];

      // ── Female-specific exercises ───────────────────────────────────────────
      const femaleSpecificExercises = <String>[
        'vrSYibzR5DHzl6Gzp4ER', // Machine Shoulder Press, Pin Loaded
        '3dWgorRmtgzsV0U4qu47', // Glute Cable Kick Back
        'kxgQUX7Cr75l1kOwRaqc', // Spider-Girl Plank
        'YaQ0FCQEUAk4ALwAPhv2', // Machine Hip Thrust
        'visub8iG0LIXYYCv5Qom', // Hip Thrust, Unilateral
        'LGhFj8o0sG3X12296UAh', // Hip Thrust, Barbell
        'hCpQR1NgeEAp31lVRWLw', // Machine Hip Adduction
        '7WBffXwK7vJcMi3mtJTF', // Machine Hip Abduction
        't66qeWQqnuEtaoyZqRp0', // Triceps Dip Machine
        'zpNb7HgXjtcrzR14F3iF', // Cable One Arm Row
        '8CIXN12uS2xwF4JzVLq3', // Long Lever Plank
        'SoHQVtsCQreaHM8LUI5F', // Bicycle Crunch
        'qU2wXMth4duOhhzTUWet', // Decline Crunch
      ];

      // ── Build merged list based on sex ─────────────────────────────────────
      final seededExerciseIds = [
        ...baseExercises,
        if (isFemale) ...femaleSpecificExercises else ...maleSpecificExercises,
      ];

      // ── Block 2 exercise adjustments (sex-specific ± tweaks) ─────────────────────
// Base = all exercises from Block 1. Then apply -exclusions +additions.

      const femaleAdditionsB2 = <String>[
        // e.g., 'LGhFj8o0sG3X12296UAh', // Hip Thrust, Barbell
        // e.g., 'F76PnvlLLVF6hviuhRfH', // Seated Dumbbell Biceps Curl
      ];

      const maleAdditionsB2 = <String>[
        // e.g., '6d9Ud7ffAHpljWsSKrFe', // Seated Face Pull
      ];

      const femaleExclusionsB2 = <String>[
        // e.g., 'heeBViVINHO6tUScSd6y', // Back Squat, Barbell
      ];

      const maleExclusionsB2 = <String>[
        // e.g., 'wIcMsf2J9cswJRs1GuYX', // Lying Leg Curl
      ];

// Apply Block 2 adjustments dynamically
      final block2ExerciseIds = <String>{
        ...seededExerciseIds.where(
              (id) => !(isFemale ? femaleExclusionsB2 : maleExclusionsB2).contains(id),
        ),
        ...(isFemale ? femaleAdditionsB2 : maleAdditionsB2),
      }.toList(growable: false);


      // ── Block 3 exercise adjustments (sex-specific ± tweaks) ───────────────────────
// Use these four lists to easily fine-tune Block 3 composition.
// Base = all exercises from Block 1/2. Then apply -exclusions +additions.

      const femaleAdditions = <String>[
        'I4021icWTx3EAnAe1eHf', // Box Jump Squat
        // e.g., 'zpNb7HgXjtcrzR14F3iF', // Cable One Arm Row
      ];

      const maleAdditions = <String>[
        'EFbQl9i9NdYi13F3DqHr', // Push Up, Suspended
        'Ah9XLjbWvLJOWxb6e1H0', // Triceps Push Down, Unilateral

      ];

      const femaleExclusions = <String>[
        'uY8uJaSFK9czKIX4TLc4', // Machine Chest Press
      ];

      const maleExclusions = <String>[
        'eyh76KELuuO805rZBpMa', // 45 Degree Hip Extension
      ];

// Compute Block 3 exercises dynamically
      final block3ExerciseIds = <String>{
        ...seededExerciseIds.where(
              (id) => !(isFemale ? femaleExclusions : maleExclusions).contains(id),
        ),
        ...(isFemale ? femaleAdditions : maleAdditions),
      }.toList(growable: false);



      // Helper to build a block payload
      Map<String, dynamic> buildBlock({
        required String name,
        required bool isActive,
        required DateTime start,
        required DateTime end,
        required List<String> exerciseIds,
      }) {
        return {
          'name': name,
          'isActive': isActive,
          'createdAt': Timestamp.now(),
          'startDate': Timestamp.fromDate(start),
          'endDate': Timestamp.fromDate(end),
          'selectedDays': ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],
          'exercises': exerciseIds,
          'plannedExercises': exerciseIds,
          'plannedExerciseDetails': {
            'blockMeta': {
              'blockStartDate': start.toIso8601String(),
              'blockEndDate': end.toIso8601String(),
              'selectedDays': ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],
            }
          },
        };
      }

      // ── Create Block 1 (active) ─────────────────────────────────────────────
      final block1Payload = buildBlock(
        name: block1Name,
        isActive: true,
        start: startDate1,
        end: endDate1,
        exerciseIds: seededExerciseIds,
      );

      final swCreate1 = Stopwatch()..start();
      final block1Ref = await blocksRef.add(block1Payload);
      swCreate1.stop();
      final block1Id = block1Ref.id;
      print('✅ [Home] Block 1 created id=$block1Id (${swCreate1.elapsed.inMilliseconds} ms)');

      await BlockExerciseDefaultsRepository.seedDefaultsForBlock(
        uid: uid,
        blockId: block1Id,
        exerciseIds: seededExerciseIds,
      );


      // Pointer write to current_block → Block 1
      final swPtr = Stopwatch()..start();
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('block_planner')
          .doc('current_block')
          .set({
        'blockId': block1Id,
        'blockName': block1Name,
        'plannedExercises': seededExerciseIds,
        'plannedExerciseDetails': {
          'blockMeta': {
            'blockStartDate': startDate1.toIso8601String(),
            'blockEndDate': endDate1.toIso8601String(),
            'selectedDays': ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],
          }
        },
        'blockMeta': {
          'blockStartDate': startDate1.toIso8601String(),
          'blockEndDate': endDate1.toIso8601String(),
        },
      }, SetOptions(merge: true));
      swPtr.stop();
      print('📌 [Home] Set current_block pointer → $block1Id (${swPtr.elapsed.inMilliseconds} ms)');

      // Scaffold weeks & days for Block 1
      final swScaffold1 = Stopwatch()..start();
      {
        final batch = FirebaseFirestore.instance.batch();
        for (int week = 0; week < 8; week++) {
          final weekRef = block1Ref.collection('weeks').doc('week_$week');
          batch.set(weekRef, {'exists': true}, SetOptions(merge: true));

          final daysRef = weekRef.collection('days');
          for (int day = 0; day < 7; day++) {
            final currentDate = startDate1.add(Duration(days: week * 7 + day));
            final weekday = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][day];
            final monthName = [
              'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
            ][currentDate.month - 1];

            final dayRef = daysRef.doc('day_$day');
            batch.set(dayRef, {
              'date': Timestamp.fromDate(currentDate),
              'circuitStartIndices': [0],
              'exercises': [],
              'workoutName': '$weekday ${currentDate.day} $monthName - Week ${week + 1}',
              'exists': true,
            }, SetOptions(merge: true));
          }
        }
        batch.set(block1Ref, {'scaffoldReady': true}, SetOptions(merge: true));
        await batch.commit();
      }
      swScaffold1.stop();
      print('🧱 [Home] Block 1 scaffold ready (${swScaffold1.elapsed.inMilliseconds} ms)');

      // ── Create Block 2 (upcoming, not active) ───────────────────────────────
      final block2Payload = buildBlock(
        name: block2Name,
        isActive: false, // keep only 1 active block
        start: startDate2,
        end: endDate2,
        exerciseIds: block2ExerciseIds, // ✅ now uses sex-specific adjusted list
      );

      final swCreate2 = Stopwatch()..start();
      final block2Ref = await blocksRef.add(block2Payload);
      swCreate2.stop();
      final block2Id = block2Ref.id;
      print('✅ [Home] Block 2 created id=$block2Id (${swCreate2.elapsed.inMilliseconds} ms)');

      await BlockExerciseDefaultsRepository.seedDefaultsForBlock(
        uid: uid,
        blockId: block2Id,
        exerciseIds: block2ExerciseIds,
      );


      // Scaffold weeks & days for Block 2
      final swScaffold2 = Stopwatch()..start();
      {
        final batch = FirebaseFirestore.instance.batch();
        for (int week = 0; week < 8; week++) {
          final weekRef = block2Ref.collection('weeks').doc('week_$week');
          batch.set(weekRef, {'exists': true}, SetOptions(merge: true));

          final daysRef = weekRef.collection('days');
          for (int day = 0; day < 7; day++) {
            final currentDate = startDate2.add(Duration(days: week * 7 + day));
            final weekday = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][day];
            final monthName = [
              'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
            ][currentDate.month - 1];

            final dayRef = daysRef.doc('day_$day');
            batch.set(dayRef, {
              'date': Timestamp.fromDate(currentDate),
              'circuitStartIndices': [0],
              'exercises': [],
              'workoutName': '$weekday ${currentDate.day} $monthName - Week ${week + 1}',
              'exists': true,
            }, SetOptions(merge: true));
          }
        }
        batch.set(block2Ref, {'scaffoldReady': true}, SetOptions(merge: true));
        await batch.commit();
      }
      swScaffold2.stop();
      print('🧱 [Home] Block 2 scaffold ready (${swScaffold2.elapsed.inMilliseconds} ms)');

      debugPrint('🧪[B3 pre-add] seed=${seededExerciseIds.length} adj=${block3ExerciseIds.length} '
          'hasAdd(EFbQl9i9NdYi13F3DqHr)=${block3ExerciseIds.contains('EFbQl9i9NdYi13F3DqHr')} '
          'hasEx(eyh76KELuuO805rZBpMa)=${block3ExerciseIds.contains('eyh76KELuuO805rZBpMa')}');

      // ── Create Block 3 (upcoming, not active) ─────────────────────────────────────
      final block3Name = (username != null && username.isNotEmpty)
          ? "${username}'s 3rd Block"
          : "3rd Block";

      final block3Payload = buildBlock(
        name: block3Name,
        isActive: false, // keep only 1 active block
        start: startDate3,
        end: endDate3,
        exerciseIds: block3ExerciseIds,
      );

      final swCreate3 = Stopwatch()..start();
      final block3Ref = await blocksRef.add(block3Payload);
      final _savedB3 = await block3Ref.get();
      final _savedPlanned = List<String>.from((_savedB3.data() ?? const {})['plannedExercises'] ?? const <String>[]);
      debugPrint('🔎[B3 saved] planned=${_savedPlanned.length} '
          'hasAdd(EFbQl9i9NdYi13F3DqHr)=${_savedPlanned.contains('EFbQl9i9NdYi13F3DqHr')} '
          'hasEx(eyh76KELuuO805rZBpMa)=${_savedPlanned.contains('eyh76KELuuO805rZBpMa')}');

      swCreate3.stop();
      final block3Id = block3Ref.id;
      print('✅ [Home] Block 3 created id=$block3Id (${swCreate3.elapsed.inMilliseconds} ms)');

      await BlockExerciseDefaultsRepository.seedDefaultsForBlock(
        uid: uid,
        blockId: block3Id,
        exerciseIds: block3ExerciseIds,
      );


// Scaffold weeks & days for Block 3
      final swScaffold3 = Stopwatch()..start();
      {
        final batch = FirebaseFirestore.instance.batch();
        for (int week = 0; week < 8; week++) {
          final weekRef = block3Ref.collection('weeks').doc('week_$week');
          batch.set(weekRef, {'exists': true}, SetOptions(merge: true));

          final daysRef = weekRef.collection('days');
          for (int day = 0; day < 7; day++) {
            final currentDate = startDate3.add(Duration(days: week * 7 + day));
            final weekday = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][day];
            final monthName = [
              'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
            ][currentDate.month - 1];

            final dayRef = daysRef.doc('day_$day');
            batch.set(dayRef, {
              'date': Timestamp.fromDate(currentDate),
              'circuitStartIndices': [0],
              'exercises': [],
              'workoutName': '$weekday ${currentDate.day} $monthName - Week ${week + 1}',
              'exists': true,
            }, SetOptions(merge: true));
          }
        }
        batch.set(block3Ref, {'scaffoldReady': true}, SetOptions(merge: true));
        await batch.commit();
      }
      swScaffold3.stop();
      print('🧱 [Home] Block 3 scaffold ready (${swScaffold3.elapsed.inMilliseconds} ms)');

    }



    swTotal.stop();
    print('⏱️ [Home] _ensureAtLeastOneBlockExists total: ${swTotal.elapsed.inMilliseconds} ms');
  }

  bool _uiIsValid() {
    // Required: goals (we’ll require that user has at least ordered them once — always true here)
    final hasGoals = _goals.isNotEmpty;

    // Required: injuries selection is allowed to be empty, but if any checked, pain 1–10 must exist.
    final injuryPainOk = _injuries.every((i) => (_painSlider[i] ?? 0) >= 1);

    // Required: experience must be selected.
    final hasExperience = _experience != null;

    // Conditional required: if muscle/toned relevant, we require at least one body focus.
    final hasAnyFocus = _bodyFocusLevel.values.any((lvl) => lvl > 0);
    final focusOk = !_muscleOrTonedChosen || hasAnyFocus;

    final envOk = _env != null; // require user to pick an environment

    return hasGoals && injuryPainOk && hasExperience && focusOk && envOk;
  }

  @override
  void dispose() {
    _benchCtrl.dispose();
    _squatCtrl.dispose();
    _pullCtrl.dispose();
    _deadCtrl.dispose();
    _benchWeightCtrl.dispose();
    _benchRepsCtrl.dispose();
    _squatWeightCtrl.dispose();
    _squatRepsCtrl.dispose();
    _pullWeightCtrl.dispose();
    _pullRepsCtrl.dispose();
    _deadWeightCtrl.dispose();
    _deadRepsCtrl.dispose();

    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    // 🟦 Populate effort labels based on DOB + sex
    _trainingEffortLabels = _buildEffortLabels(widget.sex, widget.dob);

    // 🔹 After first frame, detect entryFrom and hydrate existing values for edit mode
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final entryFrom = (ModalRoute.of(context)?.settings.arguments as Map?)?['entryFrom']?.toString() ?? 'onboarding';
      final isEditMode = entryFrom == 'templates' || entryFrom == 'drawer';
      if (isEditMode && mounted) {
        _hydrateFromFirestoreEditMode();
      }
    });
  }



  Future<void> _finish() async {
    if (!_uiIsValid()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete the required bits first')),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      // 1) Create account now (if not already signed in)
      final auth = FirebaseAuth.instance;
      UserCredential? cred;

      if (auth.currentUser == null) {
        cred = await auth.createUserWithEmailAndPassword(
          email: widget.email,
          password: widget.password,
        );

        // displayName = username (optional)
        final user = auth.currentUser;
        final username = (widget.username ?? '').trim();
        if (user != null && username.isNotEmpty) {
          await user.updateDisplayName(username);
        }
      }

      final user = auth.currentUser;
      if (user == null) {
        throw Exception('No user after registration');
      }

      // 🔐 Ensure membership doc exists for this new account.
      // Idempotent: if Stripe/webhook already created it, we don't overwrite.
      await ensureMembershipDoc(user.uid);

      // 2) Write profile payload to users & users_public
      final username = (widget.username ?? '').trim();
      final payload = {
        'email': user.email,
        'username': username,
        'usernameLower': username.toLowerCase(),
        'fullName': widget.fullName,
        'dob': widget.dob,    // yyyy-mm-dd string
        'sex': widget.sex,    // 'M'|'F'|'N'
        'createdAt': FieldValue.serverTimestamp(),
      };

      // ✅ Cache demographics locally for offline + fast access across the app
      await DemographicsCache.save(
        uid: user.uid,
        sex: widget.sex,
        dob: widget.dob, // yyyy-mm-dd
      );


      final db = FirebaseFirestore.instance;
      await db.collection('users').doc(user.uid).set(payload, SetOptions(merge: true));
      await db.collection('users_public').doc(user.uid).set(payload, SetOptions(merge: true));

      // 3) Build & save onboarding answers
      final answers = OnboardingAnswers(
        goalsRanked: _goals.toList(),
        bodyFocus: _bodyFocus.isEmpty ? null : _bodyFocus.toList(),
        injuries: _injuries.isEmpty ? null : _injuries.toList(),
        painNow: _injuries.isEmpty
            ? null
            : Map.fromEntries(_injuries.map((k) => MapEntry(k, (_painSlider[k] ?? 1).round()))),
        experience: _experience,
        bestEfforts: _collectBestEfforts(),
        minTrainingDaysPerWeek: _minTrainingDays,
        trainingEffort: _trainingEffort,   // ✅ just add this line
        createdAt: DateTime.now(),
        version: 'v1',
      );


      final onbRef = db.collection('users').doc(user.uid)
          .collection('profile').doc('fitness_onboarding');

      // 🔄 Clear old painNow entries so deselected injuries don't linger
      await onbRef.set({
        'painNow': FieldValue.delete(),
      }, SetOptions(merge: true));

      // Now write the fresh onboarding answers (including the new painNow map)
      await onbRef.set(answers.toJson(), SetOptions(merge: true));

      // Save shoulder / elbow pain detail flags (flat keys)
      final Map<String, dynamic> painDetailFlags = {};

      if (_injuries.contains('Shoulders')) {
        painDetailFlags['shoulderPainOverhead'] = _shoulderPainOverhead;
        painDetailFlags['shoulderPainFront'] = _shoulderPainFront;
      }
      if (_injuries.contains('Elbows')) {
        painDetailFlags['elbowPainInside'] = _elbowPainInside;
        painDetailFlags['elbowPainOutside'] = _elbowPainOutside;
      }

      if (painDetailFlags.isNotEmpty) {
        await onbRef.set(painDetailFlags, SetOptions(merge: true));
      }

      await onbRef.set({
        'bodyFocusLevel': _bodyFocusLevel,
      }, SetOptions(merge: true));



      // Save child/sub-group levels (if any)
      if (_childFocusLevel.isNotEmpty) {
        final filtered = <String, Map<String, int>>{};
        _childFocusLevel.forEach((parent, kidsMap) {
          // Keep all kids, including 0
          final copy = Map<String, int>.fromEntries(
            kidsMap.entries.map((e) => MapEntry(e.key, e.value as int)),
          );
          if (copy.isNotEmpty) {
            filtered[parent] = copy;
          }
        });

        if (filtered.isNotEmpty) {
          await onbRef.set({
            'bodyFocusChildren': filtered,
          }, SetOptions(merge: true));
        }
      }





      // Persist final goals order + the "not important" bin
      await onbRef.set({
        'goalsRanked': _goals,                 // (already in answers; keep for clarity)
        'goalsNotImportant': _notImportantGoals,
      }, SetOptions(merge: true));


      // Save equipment snapshot
      final String? env = _env;
      final List<String> items = _equipSelected.toList();

      await onbRef.set({
        'environment': env, // 'commercial' | 'powerlifting' | 'home' | 'travelling'
        'equipment': {
          'items': items,         // selected checkboxes
          'dumbbellsMax': _dbMax, // nullable int (e.g., 40/50/60)
        },
      }, SetOptions(merge: true));

      // 3a) Save PT experience (if answered)
      if (_ptHistory != null) {
        // Map selection 0..3 to stable buckets + canonical text
        const buckets = ['none', 'lt3', '4to16', 'gt16'];
        const canonicalText = ['No', '<3 sessions', '4–16 sessions', '16+ sessions'];

        await onbRef.set({
          'ptHistory': {
            'index': _ptHistory,                // 0..3
            'bucket': buckets[_ptHistory!],     // 'none' | 'lt3' | '4to16' | 'gt16'
            'text': canonicalText[_ptHistory!], // canonical, UI-agnostic
            'savedAt': FieldValue.serverTimestamp(),
          },
        }, SetOptions(merge: true));
      }

      // 3b) Save weekly training frequency (explicit mirror of answers.minTrainingDaysPerWeek)
      await onbRef.set({
        'weeklyFrequency': _minTrainingDays,        // int 2..7
        'minTrainingDaysPerWeek': _minTrainingDays, // legacy/alias for backward compatibility
        'weeklyFrequencySavedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

// (Optional but handy) also surface it on the top-level users doc for fast reads
      await db.collection('users').doc(user.uid).set({
        'weeklyFrequency': _minTrainingDays,
      }, SetOptions(merge: true));

      // ─────────────────────────────────────────────────────────────
      // 4) Ensure first planned block exists, then write best-effort PRs
      //    into planned_blocks/<uid>/blocks/<blockId> under BOTH:
      //    exerciseSettings + plannedExerciseDetails
      // ─────────────────────────────────────────────────────────────

      // IMPORTANT: call your existing block seeding logic here (move the function
      // into this page, or import it). This ensures new users have Block 1 created.
      await _ensureAtLeastOneBlockExists();

      // Resolve the active/current blockId from the pointer doc
      final currentBlockSnap = await db
          .collection('users')
          .doc(user.uid)
          .collection('block_planner')
          .doc('current_block')
          .get();

      final currentBlockData = currentBlockSnap.data() ?? {};
      final String? blockIdToUse = currentBlockData['blockId'] as String?;

      if (blockIdToUse == null || blockIdToUse.trim().isEmpty) {
        debugPrint('❌ [Onboarding Finish] No current blockId found after seeding.');
      } else {
        // Map liftKey (from _collectBestEfforts) → exerciseId in Firestore
        const Map<String, String> liftKeyToExerciseId = {
          // Bench variants
          'bench_barbell': 'AmfUWbF1DH3I7qPAdh5k', // Bench Press, Barbell
          'bench_db': 'kTs5fLSTKjUkUZL10iii',      // Flat Bench Dumbbell Press
          'chest_press': 'uY8uJaSFK9czKIX4TLc4',   // Machine Chest Press

          // Squat variants
          'back_squat': 'heeBViVINHO6tUScSd6y',    // Back Squat, Barbell
          'leg_press': 'v2XlZUvFfBUhogOdKtJ8',     // Leg Press

          // Pull variants
          'lat_pulldown_supinated': '1XOIXxeLFhgmgjZS9Cyq', // Lat Pull Down, Supinated
          'lat_pulldown_wide': 'Url65Q2RxZa00dkDpUdl',      // Lat Pull Down, Wide Arm

          // Deadlift
          'deadlift': 'MsGl7e9yanDeEnYX0e4X', // Deadlift, Conventional
        };

        // Build updates
        final bestEfforts = _collectBestEfforts();

        // Helper to format weight: 150.0 -> "150", 45.5 -> "45.5"
        String _fmtWeight(double w) {
          final isInt = w % 1 == 0;
          return isInt ? w.toInt().toString() : w.toString();
        }

        final Map<String, dynamic> updates = {};

        for (final be in bestEfforts) {
          final exerciseId = liftKeyToExerciseId[be.liftKey];
          if (exerciseId == null) {
            debugPrint('⚠️ [Onboarding Finish] Unknown liftKey: ${be.liftKey}');
            continue;
          }

          final weight = be.weightKg;
          if (weight == null) continue; // per your rule: skip if weight missing

          final int reps = (be.reps == null || be.reps! <= 0) ? 1 : be.reps!;
          final manual = '${_fmtWeight(weight)} X $reps';

          final double e1rm = PeriodizationModelUtils.calculateE1RM(
            weight,
            reps.toDouble(),
            0.0, // ignore RIR, default 0
          );

          // Write into BOTH maps
          // Ensure root maps exist
          updates['exerciseSettings'] ??= <String, dynamic>{};
          updates['plannedExerciseDetails'] ??= <String, dynamic>{};

// Ensure per-exercise maps exist
          (updates['exerciseSettings'] as Map<String, dynamic>)
              .putIfAbsent(exerciseId, () => <String, dynamic>{});
          (updates['plannedExerciseDetails'] as Map<String, dynamic>)
              .putIfAbsent(exerciseId, () => <String, dynamic>{});

// Write values
          (updates['exerciseSettings'][exerciseId] as Map<String, dynamic>)['maxWeightByReps_manual'] = manual;
          (updates['exerciseSettings'][exerciseId] as Map<String, dynamic>)['e1rm'] = e1rm;

          (updates['plannedExerciseDetails'][exerciseId] as Map<String, dynamic>)['maxWeightByReps_manual'] = manual;
          (updates['plannedExerciseDetails'][exerciseId] as Map<String, dynamic>)['e1rm'] = e1rm;

        }

        if (updates.isNotEmpty) {
          await db
              .collection('planned_blocks')
              .doc(user.uid)
              .collection('blocks')
              .doc(blockIdToUse)
              .set(updates, SetOptions(merge: true));

          debugPrint('✅ [Onboarding Finish] Wrote best-efforts into block=$blockIdToUse');
        } else {
          debugPrint('ℹ️ [Onboarding Finish] No best-effort values provided; skipping block writes.');
        }
      }


      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/home');
    } catch (e, st) {
      debugPrint('❌ [Onboarding Finish] $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not finish setup. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _hydrateFromFirestoreEditMode() async {
    try {
      // one-time provider read in handlers/async code
      final actingUid = context.read<UserContext>().currentUid;
      final db = FirebaseFirestore.instance;

      final snap = await db
          .collection('users')
          .doc(actingUid)
          .collection('profile')
          .doc('fitness_onboarding')
          .get();

      if (!snap.exists) {
        debugPrint('ℹ️ [EditPrefs] No existing fitness_onboarding for $actingUid');
        return;
      }

      final j = Map<String, dynamic>.from(snap.data()!);

      // ---- Map JSON → state (cover all fields you save on finish) ----
      final loadedGoals             = (j['goalsRanked'] as List?)?.map((e) => e.toString()).toList() ?? _goals;
      final loadedNotImportant      = (j['goalsNotImportant'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];

      final loadedBodyFocusLevel    = (j['bodyFocusLevel'] as Map?)?.map((k, v) => MapEntry(k.toString(), (v as num).toInt())) ?? <String,int>{};
      final loadedBodyFocusChildren = (j['bodyFocusChildren'] as Map?)?.map((pk, pv) {
        final kids = Map<String, dynamic>.from(pv as Map);
        return MapEntry(pk.toString(), kids.map((ck, cv) => MapEntry(ck.toString(), (cv as num).toInt())));
      }) ?? <String, Map<String,int>>{};

      final loadedInjuries          = (j['injuries'] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
      final loadedPainNow           = (j['painNow'] as Map?)?.map((k, v) => MapEntry(k.toString(), (v as num).toDouble())) ?? <String,double>{};

      final loadedExperienceStr     = j['experience']?.toString();
      final loadedExperience        = OnboardingAnswers._expFromString(loadedExperienceStr);

      final loadedWeeklyFreq        = (j['weeklyFrequency'] ?? j['minTrainingDaysPerWeek']) as num?;
      final loadedTrainingEffort    = (j['trainingEffort'] as num?)?.toInt();

      final env                     = j['environment']?.toString();
      final equip                   = Map<String, dynamic>.from(j['equipment'] ?? {});
      final equipItems              = (equip['items'] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
      final dbMax                   = (equip['dumbbellsMax'] as num?)?.toInt();

      final pt                      = Map<String, dynamic>.from(j['ptHistory'] ?? {});
      final ptIndex                 = (pt['index'] as num?)?.toInt();

      // Optional best efforts → hydrate text fields if present
      final bestEfforts             = (j['bestEfforts'] as List?)?.map((e) => Map<String,dynamic>.from(e as Map)).toList() ?? const [];

      // ---- Commit to state ----
      if (!mounted) return;
      setState(() {
        _goals               = loadedGoals;
        _notImportantGoals   = loadedNotImportant;

        _bodyFocusLevel
          ..clear()
          ..addAll(loadedBodyFocusLevel);
        _childFocusLevel
          ..clear()
          ..addAll(loadedBodyFocusChildren.map((k, v) => MapEntry(k, Map<String,int>.from(v))));

        _injuries
          ..clear()
          ..addAll(loadedInjuries);

        _painSlider
          ..clear()
          ..addAll(loadedPainNow);

        _experience          = loadedExperience;
        _minTrainingDays     = loadedWeeklyFreq?.toInt();
        _trainingEffort      = loadedTrainingEffort;

        _env                 = env;
        _equipSelected
          ..clear()
          ..addAll(equipItems);
        _dbMax               = dbMax;

        _ptHistory           = ptIndex;

        // If children exist, show the "More specific" view by default
        _moreSpecific        = _childFocusLevel.isNotEmpty;

        // (Optional) seed best-effort text fields if you want them visible
        for (final be in bestEfforts) {
          final key = (be['liftKey'] ?? '').toString();
          final w   = (be['weightKg'] as num?)?.toDouble();
          final r   = (be['reps'] as num?)?.toInt();

          if (key.contains('bench')) {
            if (w != null) _benchWeightCtrl.text = w.toStringAsFixed(w % 1 == 0 ? 0 : 1);
            if (r != null) _benchRepsCtrl.text   = r.toString();
          } else if (key.contains('squat') || key.contains('leg_press')) {
            if (w != null) _squatWeightCtrl.text = w.toStringAsFixed(w % 1 == 0 ? 0 : 1);
            if (r != null) _squatRepsCtrl.text   = r.toString();
          } else if (key.contains('lat_pulldown') || key.contains('chinup')) {
            if (w != null) _pullWeightCtrl.text  = w.toStringAsFixed(w % 1 == 0 ? 0 : 1);
            if (r != null) _pullRepsCtrl.text    = r.toString();
          } else if (key.contains('deadlift')) {
            if (w != null) _deadWeightCtrl.text  = w.toStringAsFixed(w % 1 == 0 ? 0 : 1);
            if (r != null) _deadRepsCtrl.text    = r.toString();
          }
        }
      });

      debugPrint('✅ [EditPrefs] Hydrated onboarding for $actingUid');
    } catch (e, st) {
      debugPrint('❌ [EditPrefs] hydrate failed: $e\n$st');
    }
  }



  List<BestEffort> _collectBestEfforts() {
    final out = <BestEffort>[];

    // tiny helper to normalise UI text → backend-ish keys
    String _mapBench(String v) {
      switch (v) {
        case 'Bench Press':
          return 'bench_barbell';
        case 'Flat DB Press':
          return 'bench_db';
        case 'Chest Press':
          return 'chest_press';
        default:
          return v.replaceAll(' ', '_').toLowerCase();
      }
    }

    String _mapSquat(String v) {
      switch (v) {
        case 'Back Squat':
          return 'back_squat';
        case 'Leg Press':
          return 'leg_press';
        default:
          return v.replaceAll(' ', '_').toLowerCase();
      }
    }

    String _mapPull(String v) {
      switch (v) {
        case 'Lat Pull Down, Supinated':
          return 'lat_pulldown_supinated';
        case 'Lat Pull Down, Wide Arm':
          return 'lat_pulldown_wide';
        case 'Chin Up':
          return 'chinup';
        default:
          return v.replaceAll(' ', '_').toLowerCase();
      }
    }

    String _mapDead(String v) {
      // future-proofing if you add variants later
      if (v == 'Deadlift') return 'deadlift';
      return v.replaceAll(' ', '_').toLowerCase();
    }

    void addIfPresent({
      required String liftKey,
      required TextEditingController weightCtrl,
      required TextEditingController repsCtrl,
    }) {
      final w = double.tryParse(weightCtrl.text.trim());
      final r = int.tryParse(repsCtrl.text.trim());
      if (w != null) {
        out.add(BestEffort(liftKey: liftKey, weightKg: w, reps: r));
      }
    }

    // 👇 now use the ACTUAL selection instead of the generic names
    addIfPresent(
      liftKey: _mapBench(_benchVariant),
      weightCtrl: _benchWeightCtrl,
      repsCtrl: _benchRepsCtrl,
    );

    addIfPresent(
      liftKey: _mapSquat(_squatVariant),
      weightCtrl: _squatWeightCtrl,
      repsCtrl: _squatRepsCtrl,
    );

    addIfPresent(
      liftKey: _mapPull(_pullVariant),
      weightCtrl: _pullWeightCtrl,
      repsCtrl: _pullRepsCtrl,
    );

    addIfPresent(
      liftKey: _mapDead(_deadVariant),
      weightCtrl: _deadWeightCtrl,
      repsCtrl: _deadRepsCtrl,
    );

    return out;
  }

  List<String> _buildEffortLabels(String? sex, String? dob) {
    int? year;
    if (dob != null && dob.length >= 10) {
      // 👇 handles dd-mm-yyyy correctly
      final parts = dob.split('-');
      if (parts.length == 3) {
        year = int.tryParse(parts[2]); // dd-mm-yyyy → [0]=dd, [1]=mm, [2]=yyyy
      }
    }

    final isFemale = (sex ?? '').toUpperCase() == 'F';
    final born2000OrLater = (year != null && year >= 2000);

    // MALE < 1975 (block-level intensity tone)
    if (!isFemale && year != null && year < 1975) {
      return const [
        'Taking it easy to begin',
        'Steady work',
        'Let’s make it count',
        'Leave nothing behind',
      ];
    }

    if (!isFemale && !born2000OrLater) {
      // MALE < 2000
      return const [
        'Cruise control',
        'Breaking a sweat',
        'Let’s suffer a bit',
        'Full send',
      ];
    } else if (!isFemale && born2000OrLater) {
      // MALE >= 2000
      return const [
        'Chill / easy',
        'Pretty normal',
        'Let’s work',
        'Send it 🔥',
      ];
    } else if (isFemale && !born2000OrLater) {
      // FEMALE < 2000
      return const [
        'Nice and easy',
        'Steady / manageable',
        'Push me a bit',
        'Go hard',
      ];
    } else {
      // FEMALE >= 2000
      return const [
        'Cruisy',
        'Steady progress',
        'Make me work',
        'Smash it 💪',
      ];
    }
  }


  bool _isDobBefore1995Flexible(String? rawDob) {
    if (rawDob == null || rawDob.isEmpty) return false;

    // 1) try dd-mm-yyyy first (what you said you're using)
    final parts = rawDob.split('-');
    if (parts.length == 3) {
      final dd = int.tryParse(parts[0]);
      final mm = int.tryParse(parts[1]);
      final yyyy = int.tryParse(parts[2]);
      if (dd != null && mm != null && yyyy != null) {
        try {
          final dt = DateTime(yyyy, mm, dd);
          return dt.isBefore(DateTime(1995, 1, 1));
        } catch (_) {
          // fall through to ISO attempt
        }
      }
    }

    // 2) fallback: try ISO yyyy-mm-dd
    try {
      final dt = DateTime.parse(rawDob);
      return dt.isBefore(DateTime(1995, 1, 1));
    } catch (_) {
      return false;
    }
  }



  @override
  Widget build(BuildContext context) {
    final entryFrom = (ModalRoute.of(context)?.settings.arguments as Map?)?['entryFrom']?.toString() ?? 'onboarding';
    final isEditMode = entryFrom == 'templates' || entryFrom == 'drawer';
    // Ensure checkboxes/radios are visible even with different parent themes
    final localTheme = Theme.of(context).copyWith(
      // M2/M3 compatibility: some widgets still use this for the *unselected* ring
      unselectedWidgetColor: Colors.blueGrey.shade600,

      checkboxTheme: Theme.of(context).checkboxTheme.copyWith(
        // Outline color when UNSELECTED
        side: BorderSide(color: Colors.blueGrey.shade600, width: 1.4),
        // Fill when selected / keep white when not selected
        fillColor: MaterialStateProperty.resolveWith((states) {
          return states.contains(MaterialState.selected)
              ? Colors.blueAccent
              : Colors.white;
        }),
        checkColor: MaterialStateProperty.all(Colors.white),
      ),

      radioTheme: Theme.of(context).radioTheme.copyWith(
        // Ring & dot color for both selected/unselected
        fillColor: MaterialStateProperty.resolveWith((states) {
          // Use same color so the *unselected* ring is visible
          return Colors.blueGrey.shade700;
        }),
      ),
    );

    return Theme(
        data: localTheme,
        child: Scaffold(
          backgroundColor: Colors.blueGrey.shade50,
          body: Center(

          child: Card(
          elevation: 10,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          color: Colors.white.withOpacity(0.9),
          margin: const EdgeInsets.all(20),
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      "Tell us more pls!",
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: Colors.blueAccent,
                      ),
                    ),
                    const SizedBox(height: 16),

                    _SectionHeader("What do you care about most? (drag to rank)", color: Colors.blueAccent),
                    const SizedBox(height: 8),
                    _GoalsRanker(
                      items: _goals,
                      onChanged: (main, notImportant) {
                        setState(() {
                          _goals = List.from(main);
                          _notImportantGoals = List.from(notImportant);
                        });
                      },
                      sex: widget.sex,   // 👈 pass through from page one
                      dob: widget.dob,   // 👈 pass through from page one
                    ),




                    const SizedBox(height: 6),


                    // B) Body Focus (conditional)


                    // C) Injuries (checkbox + pain slider)
                    const SizedBox(height: 19),
                    _SectionHeader("Any existing niggles or injuries?", color: Colors.blueAccent),
                    const SizedBox(height: 8),

                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.blueAccent, width: 1.3),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blueAccent.withOpacity(0.06),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Column(
                        children: _injuryKeys.map((k) {
                          final checked = _injuries.contains(k);
                          final val = _painSlider[k] ?? 5.0;

                          return Column(
                            children: [
                              CheckboxListTile(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                contentPadding: EdgeInsets.zero,
                                controlAffinity: ListTileControlAffinity.leading,
                                activeColor: Colors.blueAccent,
                                checkColor: Colors.white,
                                title: Text(
                                  k,
                                  style: const TextStyle(
                                    color: Colors.black87,
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                value: checked,
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) {
                                      _injuries.add(k);
                                      _painSlider.putIfAbsent(k, () => 5.0);
                                    } else {
                                      _injuries.remove(k);
                                      _painSlider.remove(k);

                                      // reset detail flags when turning off
                                      if (k == 'Shoulders') {
                                        _shoulderPainOverhead = false;
                                        _shoulderPainFront = false;
                                      }
                                      if (k == 'Elbows') {
                                        _elbowPainInside = false;
                                        _elbowPainOutside = false;
                                      }
                                    }
                                  });
                                },
                              ),

                              if (checked) ...[
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    const Text('Pain now:',
                                        style: TextStyle(color: Colors.black54, fontSize: 13.5)),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          trackHeight: 3.5,
                                          activeTrackColor: Colors.blueAccent,
                                          inactiveTrackColor: Colors.blueAccent.withOpacity(0.25),
                                          thumbColor: Colors.lightBlue,
                                          overlayColor: Colors.lightBlue.withOpacity(0.15),
                                          valueIndicatorColor: Colors.blueAccent,
                                          valueIndicatorTextStyle:
                                          const TextStyle(color: Colors.white),
                                        ),
                                        child: Slider(
                                          min: 1,
                                          max: 10,
                                          divisions: 9,
                                          label: _painSlider[k]?.round().toString(),
                                          value: val,
                                          onChanged: (v) =>
                                              setState(() => _painSlider[k] = v),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),

                                // ── Shoulder follow-up
                                if (k == 'Shoulders') ...[
                                  const SizedBox(height: 4),
                                  const Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'Is there pain when you press up above your head, '
                                          'or when you press out in front of you, or both?',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Colors.black87,
                                      ),
                                    ),
                                  ),
                                  CheckboxListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    contentPadding: EdgeInsets.only(left: 24.0),
                                    controlAffinity: ListTileControlAffinity.leading,
                                    activeColor: Colors.blueAccent,
                                    title: const Text(
                                      'Pressing above my head',
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        color: Colors.black87,
                                      ),
                                    ),

                                    value: _shoulderPainOverhead,
                                    onChanged: (v) {
                                      setState(() {
                                        _shoulderPainOverhead = v ?? false;
                                      });
                                    },
                                  ),
                                  CheckboxListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    contentPadding: EdgeInsets.only(left: 24.0),
                                    controlAffinity: ListTileControlAffinity.leading,
                                    activeColor: Colors.blueAccent,
                                    title: const Text(
                                      'Pressing out in front of me',
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    value: _shoulderPainFront,
                                    onChanged: (v) {
                                      setState(() {
                                        _shoulderPainFront = v ?? false;
                                      });
                                    },
                                  ),
                                ],

                                // ── Elbow follow-up
                                if (k == 'Elbows') ...[
                                  const SizedBox(height: 4),
                                  const Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'Does the inside of your elbow hurt (closest to your body), '
                                          'or the outside?',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Colors.black87,
                                      ),
                                    ),
                                  ),
                                  CheckboxListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    contentPadding: EdgeInsets.only(left: 24.0),
                                    controlAffinity: ListTileControlAffinity.leading,
                                    activeColor: Colors.blueAccent,
                                    title: const Text(
                                      'The inside hurts',
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    value: _elbowPainInside,
                                    onChanged: (v) {
                                      setState(() {
                                        _elbowPainInside = v ?? false;
                                      });
                                    },
                                  ),
                                  CheckboxListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    contentPadding: EdgeInsets.only(left: 24.0),
                                    controlAffinity: ListTileControlAffinity.leading,
                                    activeColor: Colors.blueAccent,
                                    title: const Text(
                                      'The outside hurts',
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    value: _elbowPainOutside,
                                    onChanged: (v) {
                                      setState(() {
                                        _elbowPainOutside = v ?? false;
                                      });
                                    },
                                  ),
                                ],
                              ],

                              // divider between items
                              const Divider(height: 10, color: Color(0xFFE3F2FD)),
                            ],
                          );
                        }).toList(),
                      ),

                    ),


                    // D) Experience
                    const SizedBox(height: 16),
                    _SectionHeader("Weights Training experience", color: Colors.blueAccent),
                    const SizedBox(height: 6),

                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.blueAccent, width: 1.3),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blueAccent.withOpacity(0.06),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                      child: Column(
                        children: [
                          RadioListTile<TrainingExperience>(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            contentPadding: EdgeInsets.zero,
                            activeColor: Colors.blueAccent,
                            title: const Text(
                              'Never trained before',
                              style: TextStyle(color: Colors.black87, fontSize: 15.5, fontWeight: FontWeight.w600),
                            ),
                            value: TrainingExperience.never,
                            groupValue: _experience,
                            onChanged: (v) => setState(() {
                              _experience = v;
                              _moreSpecific = false; // hide/disable advanced control
                            }),

                          ),
                          const Divider(height: 6, color: Color(0xFFE3F2FD)),
                          RadioListTile<TrainingExperience>(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            contentPadding: EdgeInsets.zero,
                            activeColor: Colors.blueAccent,
                            title: const Text(
                              '< 6 months',
                              style: TextStyle(color: Colors.black87, fontSize: 15.5, fontWeight: FontWeight.w600),
                            ),
                            value: TrainingExperience.lt6mo,
                            groupValue: _experience,
                            onChanged: (v) => setState(() {
                              _experience = v;
                              _moreSpecific = false; // hide/disable advanced control
                            }),

                          ),
                          const Divider(height: 6, color: Color(0xFFE3F2FD)),
                          RadioListTile<TrainingExperience>(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            contentPadding: EdgeInsets.zero,
                            activeColor: Colors.blueAccent,
                            title: const Text(
                              '~ 1 year',
                              style: TextStyle(color: Colors.black87, fontSize: 15.5, fontWeight: FontWeight.w600),
                            ),
                            value: TrainingExperience.oneYear,
                            groupValue: _experience,
                            onChanged: (v) => setState(() => _experience = v),
                          ),
                          const Divider(height: 6, color: Color(0xFFE3F2FD)),
                          RadioListTile<TrainingExperience>(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            contentPadding: EdgeInsets.zero,
                            activeColor: Colors.blueAccent,
                            title: const Text(
                              '2+ years',
                              style: TextStyle(color: Colors.black87, fontSize: 15.5, fontWeight: FontWeight.w600),
                            ),
                            value: TrainingExperience.twoPlus,
                            groupValue: _experience,
                            onChanged: (v) => setState(() => _experience = v),
                          ),
                        ],
                      ),


                    ),

                    /// ─────────────────────────────────────────────────────────────────────────────
// Personal training history (conditional on NOT 'Never trained before')
// ─────────────────────────────────────────────────────────────────────────────
                    if (_experience != null && _experience != TrainingExperience.never) ...[
                      const SizedBox(height: 14),
                      const _SectionHeader(
                        "Have you ever had personal training before?",
                        color: Colors.blueAccent, // ✅ make this one blue
                      ),
                      const SizedBox(height: 10),

                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.9),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.blueAccent, width: 1.3),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.blueAccent.withOpacity(0.06),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                        child: Builder(
                          builder: (_) {
                            // 🔹 PT labels depend ONLY on sex + age (1998 cutoff), not on training experience.
                            List<String> ptLabelsFor({
                              required String? sex,
                              required String? dob,
                            }) {
                              int? year;
                              if (dob != null && dob.isNotEmpty) {
                                final parts = dob.split('-');
                                if (parts.length == 3) {
                                  year = int.tryParse(parts[2]) ?? int.tryParse(parts[0]);
                                }
                              }

                              final isFemale = (sex ?? '').toUpperCase() == 'F';
                              final is1998Plus = (year != null && year >= 1998);

                              // FEMALE 1998+
                              if (isFemale && is1998Plus) {
                                return const [
                                  'Not yet 👀',
                                  'Just a taste (Less than 3 sessions)',
                                  'Had some help (4–16 sessions)',
                                  'Seasoned PT queen (16+ sessions)',
                                ];
                              }

                              // FEMALE <1998
                              if (isFemale && !is1998Plus) {
                                return const [
                                  'No',
                                  'Intro pack (<3)',
                                  'Short block (4–16)',
                                  'Ongoing (16+)',
                                ];
                              }

                              // MALE 1998+
                              if (!isFemale && is1998Plus) {
                                return const [
                                  'Nah',
                                  'Tried a couple (Less than 3 sessions)',
                                  'Some PT (4–16 sessions)',
                                  'Dialled in with a coach (16+ sessions)',
                                ];
                              }

                              // MALE <1998
                              return const [
                                'No',
                                'Intro (Less than 3 sessions)',
                                '4–16 sessions',
                                '16+ sessions',
                              ];
                            }

                            final labels = ptLabelsFor(
                              sex: widget.sex,
                              dob: widget.dob,
                            );

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(bottom: 6),
                                  child: Center(
                                    child: Text(
                                      'Pick one (helps us tailor your plan)',
                                      style: TextStyle(fontSize: 12, color: Colors.black45),
                                    ),
                                  ),
                                ),

                                ...List.generate(4, (i) {
                                  final selected = _ptHistory == i;
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: selected ? Colors.blueAccent : Colors.grey.shade300,
                                        width: selected ? 2 : 1,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                      color: selected
                                          ? Colors.blueAccent.withOpacity(0.08)
                                          : Colors.white.withOpacity(0.9),
                                    ),
                                    child: RadioListTile<int>(
                                      dense: true,
                                      visualDensity: VisualDensity.compact,
                                      contentPadding: EdgeInsets.zero,
                                      activeColor: Colors.blueAccent,
                                      value: i,
                                      groupValue: _ptHistory,
                                      onChanged: (v) => setState(() => _ptHistory = v),
                                      title: Text(
                                        labels[i],
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: selected ? Colors.blueAccent : Colors.black87,
                                          fontWeight:
                                          selected ? FontWeight.w600 : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            );
                          },
                        ),
                      ),
                    ],


                    if (_muscleOrTonedChosen) ...[
                      const SizedBox(height: 16),
                      _SectionHeader(
                        "Any areas you’d like to especially focus on?"
                            "\nTap once, twice or thrice for extra emphasis",

                      ),


                      const SizedBox(height: 8),
                      Builder(
                        builder: (_) {
                          // ✅ Hoisted so BOTH the row and the chips below can see it
                          final bodyPartsToShow =
                          _moreSpecific ? _bodyPartsSpecificOrder : _bodyParts;

                          return Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              // ▼ Row: Select all / Clear all + More specific toggle
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8.0),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.start,
                                  children: [
                                    // Select ALL / Clear all
                                    Builder(builder: (_) {
                                      final anySelected =
                                      _bodyFocusLevel.values.any((lvl) => lvl > 0);

                                      return ChoiceChip(
                                        showCheckmark: false,
                                        label: Text(
                                          anySelected ? 'Clear all' : 'Select ALL',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black,
                                          ),
                                        ),
                                        selected: anySelected,
                                        selectedColor: Colors.lightBlue.shade100,
                                        backgroundColor: Colors.white,
                                        shape: StadiumBorder(
                                          side: BorderSide(
                                            color:
                                            anySelected ? Colors.lightBlue : Colors.blueAccent,
                                            width: 1.2,
                                          ),
                                        ),
                                        onSelected: (_) {
                                          setState(() {
                                            if (anySelected) {
                                              // Clear parents + children
                                              _bodyFocusLevel.clear();
                                              _childFocusLevel.clear();
                                            } else {
                                              // Select all parents at level 1
                                              _bodyFocusLevel
                                                ..clear()
                                                ..addEntries(
                                                  bodyPartsToShow.map((p) => MapEntry(p, 1)),
                                                );

                                              // If more-specific view is ON, seed all children to 1
                                              if (_moreSpecific) {
                                                for (final parent in _subGroups.keys) {
                                                  final kids = _subGroups[parent]!;
                                                  _childFocusLevel[parent] = {
                                                    for (final k in kids) k: 1,
                                                  };
                                                }
                                              }
                                            }
                                          });
                                        },
                                      );
                                    }),

                                    const SizedBox(width: 10),

                                    // Show the advanced toggle only for ~1 year or 2+ years experience
                                    if (_experience == TrainingExperience.oneYear || _experience == TrainingExperience.twoPlus)
                                      ChoiceChip(
                                        showCheckmark: false,
                                        label: Text(
                                          _moreSpecific ? 'Less specific' : 'More specific',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black,
                                          ),
                                        ),
                                        selected: _moreSpecific,
                                        selectedColor: Colors.lightBlue.shade100, // highlighted when ON
                                        backgroundColor: Colors.white,            // de-highlighted when OFF
                                        shape: StadiumBorder(
                                          side: BorderSide(
                                            color: _moreSpecific ? Colors.lightBlue : Colors.blueAccent,
                                            width: 1.2,
                                          ),
                                        ),
                                        onSelected: (_) {
                                          setState(() {
                                            _moreSpecific = !_moreSpecific;

                                            // When turning ON, seed children for any already-selected parents
                                            if (_moreSpecific) {
                                              for (final parent in _subGroups.keys) {
                                                final pLvl = _bodyFocusLevel[parent] ?? 0;
                                                if (pLvl > 0) {
                                                  final kids = _subGroups[parent]!;
                                                  _childFocusLevel[parent] ??= {};
                                                  for (final k in kids) {
                                                    _childFocusLevel[parent]![k] ??= pLvl;
                                                  }
                                                }
                                              }
                                            }
                                            // When turning OFF, keep _childFocusLevel in memory (no change)
                                          });
                                        },
                                      ),

                                  ],
                                ),
                              ),

                              // ▼ Tri-state emphasis chips (tap cycles 0→1→2→3→0)
                              ...bodyPartsToShow.map((p) {
                                final lvl = _bodyFocusLevel[p] ?? 0; // 0,1,2,3

                                // Visuals per level (unchanged)
                                late final Color borderColor;
                                late final Color labelColor;
                                late final Color bgColor;
                                late final double borderW;
                                late final FontWeight fw;

                                switch (lvl) {
                                  case 1:
                                    borderColor = Colors.lightBlue;
                                    labelColor = Colors.blue.shade700;
                                    bgColor = Colors.lightBlue.shade50;
                                    borderW = 1;
                                    fw = FontWeight.w700;
                                    break;
                                  case 2:
                                    borderColor = Colors.blueAccent.shade100;
                                    labelColor = Colors.blue.shade700;
                                    bgColor = Colors.lightBlue.shade200;
                                    borderW = 1.2;
                                    fw = FontWeight.w800;
                                    break;
                                  case 3:
                                    borderColor = Colors.blueAccent.shade100;
                                    labelColor = Colors.blue.shade700;
                                    bgColor = Colors.lightBlue.shade400;
                                    borderW = 1.2;
                                    fw = FontWeight.w800;
                                    break;
                                  default:
                                    borderColor = Colors.blueAccent;
                                    labelColor = Colors.black54;
                                    bgColor = Colors.white;
                                    borderW = 1;
                                    fw = FontWeight.w600;
                                }

                                return _ParentWithChildrenChip(
                                  parent: p,
                                  parentLevel: lvl,
                                  onParentCycle: () {
                                    final next = (lvl + 1) % 4; // 0→1→2→3→0
                                    setState(() {
                                      // ✅ Always store the value, even when it's 0
                                      _bodyFocusLevel[p] = next;

                                      // ✅ Keep children in sync when "More specific" is ON
                                      if (_moreSpecific && _subGroups.containsKey(p)) {
                                        final kids = _subGroups[p]!;
                                        _childFocusLevel[p] ??= {};
                                        for (final k in kids) {
                                          _childFocusLevel[p]![k] = next; // children follow parent, including 0
                                        }
                                      }
                                    });
                                  },

                                  moreSpecific: _moreSpecific,
                                  subGroups: _subGroups[p] ?? const [],
                                  getChildLevel: (child) => _childFocusLevel[p]?[child] ?? 0,
                                  onChildCycle: (child, current) {
                                    final next = (current + 1) % 4; // 0→1→2→3→0
                                    setState(() {
                                      _childFocusLevel[p] ??= {};
                                      _childFocusLevel[p]![child] = next;

                                      // Parent = max(children) or 0 if all 0
                                      final maxLvl = _childFocusLevel[p]!.values
                                          .fold<int>(0, (m, v) => v > m ? v : m);
                                      if (maxLvl == 0) {
                                        _bodyFocusLevel.remove(p);
                                      } else {
                                        _bodyFocusLevel[p] = maxLvl;
                                      }
                                    });
                                  },
                                );
                              }).toList(),
                            ],
                          );
                        },
                      ),

                      // ▼ Body-focus feedback / fun messages
                      Builder(
                        builder: (_) {
                          final hasAny = _bodyFocusLevel.values.any((lvl) => lvl > 0);

                          // 1) If nothing picked → same as before
                          if (!hasAny) {
                            return const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text(
                                'Pick at least one pls',
                                style: TextStyle(color: Colors.redAccent, fontSize: 12),
                              ),
                            );
                          }

                          // ----- if something IS picked, we can get cheeky ↓ -----

                          // convenience lookups
                          int levelOf(String key) => _bodyFocusLevel[key] ?? 0;

                          final glutesLvl     = levelOf('Glutes');
                          final chestLvl      = levelOf('Chest');
                          final backLvl       = levelOf('Back');
                          final shouldersLvl  = levelOf('Shoulders');
                          final armsLvl       = levelOf('Arms');
                          final quadsLvl      = levelOf('Quads');
                          final hammiesLvl    = levelOf('Hamstrings');
                          final calvesLvl     = levelOf('Calves');
                          final absLvl = levelOf('Abs'); // If your key is 'Core', change to levelOf('Core')

                          // what user is
                          final sex = (widget.sex ?? '').toUpperCase();
                          final isMale = sex == 'M';
                          final isOldEnoughForBrah = isMale && _isDobBefore1995Flexible(widget.dob);

                          // Compute the "whole body" condition first (this will be row #1 if true)
                          final allBodyPartsSelected = _bodyParts.every(
                                (p) => (_bodyFocusLevel[p] ?? 0) > 0,
                          );

                          // Now compute ONE secondary message (row #2) based on your priority rules

                          // --- Resolve secondary messages, then prefer based on sex ---
// Assumes: sex, glutesLvl, chestLvl, backLvl, shouldersLvl, armsLvl,
//          quadsLvl, hammiesLvl, calvesLvl, allUpperSelected are already defined.

                          Widget? bootyCandidate;
                          Widget? otherCandidate;
                          Widget? priorityCandidate; // 👈 all-max message goes here (highest priority)


// 2) Glutes emphasis → booty message (tier 2+)
                          if (glutesLvl >= 2) {
                            // Parse birth year safely (dd-mm-yyyy or yyyy-mm-dd)
                            int? birthYear;
                            if (widget.dob != null && widget.dob!.isNotEmpty) {
                              final parts = widget.dob!.split('-');
                              if (parts.length == 3) {
                                final first = int.tryParse(parts[0]);
                                if (first != null && first > 31) {
                                  birthYear = first;                 // yyyy-mm-dd
                                } else {
                                  birthYear = int.tryParse(parts[2]); // dd-mm-yyyy
                                }
                              }
                            }

                            final isYounger = (birthYear ?? 2000) >= 2000;
                            final bootyMsg = isYounger
                                ? 'Certified cake architect 🍑🏗️'
                                : 'Those jeans won’t know what hit ’em 🍑💥';

                            bootyCandidate = Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                bootyMsg,
                                style: const TextStyle(color: Colors.green, fontSize: 12),
                              ),
                            );
                          }

// 3) Male, 90s kid, ALL upper-body, ZERO lower-body → bro callout
                          final noLegs =
                              quadsLvl == 0 && hammiesLvl == 0 && glutesLvl == 0 && calvesLvl == 0;
                          final allUpperSelectedLocal =
                              chestLvl > 0 && backLvl > 0 && shouldersLvl > 0 && armsLvl > 0;

                          if (isOldEnoughForBrah && noLegs && allUpperSelectedLocal) {
                            otherCandidate ??= const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text(
                                'No leg days? Do you even lift brah? 😂',
                                style: TextStyle(color: Colors.blueAccent, fontSize: 14),
                              ),
                            );
                          }

// 4) Typical upper-body emphasis (chest/shoulders/arms)
// Show only if ALL upper-body parts selected AND ≥2 of them are tier 2+
                          final twoOrMoreAtLeastTier2 = [
                            chestLvl >= 2,
                            backLvl >= 2,
                            shouldersLvl >= 2,
                            armsLvl >= 2,
                          ].where((x) => x).length;

                          if (allUpperSelectedLocal && twoOrMoreAtLeastTier2 >= 2) {
                            final isFemale = (sex == 'F');
                            final line = isFemale
                                ? 'That upper-body glow-up is official 🌸'
                                : 'Upper-body arc unlocked ✅';

                            otherCandidate ??= Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                line,
                                style: const TextStyle(color: Colors.green, fontSize: 12),
                              ),
                            );
                          }



                          // 5) All muscle groups selected AND all at tier 3 (max)
// This should override other candidates (highest priority).
                          final allSelectedAllTier3 = _bodyParts.isNotEmpty &&
                              _bodyParts.every((p) => (_bodyFocusLevel[p] ?? 0) >= 3);

                          if (allSelectedAllTier3) {
                            final isFemaleLocal = (sex == 'F');
                            final line = isFemaleLocal
                                ? 'Heroine era initializing 🎞️⚡'
                                : 'Boss-fight physique loading ⚔️💪';

                            priorityCandidate = Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                line,
                                style: const TextStyle(color: Colors.green, fontSize: 12),
                              ),
                            );
                          }



                          // 4b) Female-focused: ≥2 of (Glutes, Hamstrings, Quads, Abs) are tier 2+
// Typical lower-body/core goals
                          final lowerOrCoreTwoPlus = [
                            glutesLvl >= 2,
                            hammiesLvl >= 2,
                            quadsLvl >= 2,
                            absLvl >= 2,
                          ].where((x) => x).length;

                          if (sex == 'F' && lowerOrCoreTwoPlus >= 2) {
                            otherCandidate ??= const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text(
                                'Lower half about to trend 📈🩷',
                                style: TextStyle(color: Colors.green, fontSize: 12),
                              ),
                            );
                          }
                          // 4c) Male-focused: ≥2 of (Glutes, Hamstrings, Quads, Abs) are tier 2+
// Lower-body/core emphasis
                          if (sex == 'M' && lowerOrCoreTwoPlus >= 2) {
                            otherCandidate ??= const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text(
                                'Leg day loyalty detected 🦵🔥',
                                style: TextStyle(color: Colors.green, fontSize: 12),
                              ),
                            );
                          }



// --- Preference resolution ---
// Females: prefer booty → then other
// Males:   prefer other → then booty
                          // --- Preference resolution ---
                          Widget? secondaryMsg;
                          final isFemale = (sex == 'F');

                          if (priorityCandidate != null) {
                            // All-max wins (shows regardless of sex)
                            secondaryMsg = priorityCandidate;
                          } else {
                            // Otherwise: Females prefer booty; males prefer other
                            secondaryMsg = isFemale ? (bootyCandidate ?? otherCandidate)
                                : (otherCandidate ?? bootyCandidate);
                          }


// Use `secondaryMsg` below as before.


                          // Build the two-row output:
                          // Row 1: whole-body (if applicable)
                          // Row 2: whichever secondary applied (if any)
                          final children = <Widget>[];

                          if (allBodyPartsSelected) {
                            children.add(const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text(
                                'We love whole body training 🔥',
                                style: TextStyle(color: Colors.green, fontSize: 12),
                              ),
                            ));
                          }

                          if (secondaryMsg != null) {
                            // If whole-body row is shown above, tighten spacing a bit
                            children.add(Padding(
                              padding: EdgeInsets.only(top: allBodyPartsSelected ? 4 : 6),
                              child: (secondaryMsg as Padding).child, // reuse inner Text with its style
                            ));
                          }

                          if (children.isEmpty) {
                            return const SizedBox.shrink();
                          }

                          return Center(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: children,
                            ),
                          );

                        },
                      )


                    ],


                    // ── Equipment / Environment (REQUIRED)
                    const SizedBox(height: 10),
                    _SectionHeader("What kind of training equipment do you have available?", color: Colors.black),
                    const SizedBox(height: 8),

// Environment picker (compact chips)

                    Wrap(
                      spacing: 8, runSpacing: 8,
                      children: [
                        for (final entry in const [
                          ['Typical gym in NZ', 'commercial'],
                          ['Powerlifting gym', 'powerlifting'],
                          ['Home gym', 'home'],
                         // ['Travelling', 'travelling'],
                        ])
                          ChoiceChip(
                            label: Text(
                              entry[0],
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: _env == entry[1] ? Colors.blueAccent : Colors.black54,
                                fontSize: 14,
                              ),
                            ),
                            selected: _env == entry[1],
                            selectedColor: Colors.lightBlue.shade50,
                            backgroundColor: Colors.white,
                            shape: StadiumBorder(
                              side: BorderSide(
                                color: _env == entry[1] ? Colors.lightBlue : Colors.blueAccent,
                                width: 1,
                              ),
                            ),
                            onSelected: (_) {
                              setState(() {
                                _env = entry[1];
                                _equipSelected.clear();
                                _dbMax = null;

                                // 👇 Prefill defaults if commercial; otherwise leave empty
                                if (_env == 'commercial') {
                                  _equipSelected.addAll(_commercialEquip); // ✅ select all machines by default
                                }

                              });

                            },
                          ),

                      ],
                    ),

                    if (_env == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          'Pick one (required).',
                          style: TextStyle(color: Colors.redAccent, fontSize: 12),
                        ),
                      ),

// Details per environment
                    if (_env == 'powerlifting' || _env == 'home' || _env == 'travelling') ...[
                      const SizedBox(height: 13),
                      const _SectionHeader("Do you have access to the following? (tick those that apply)"),
                      const SizedBox(height: 8),

                      // Equipment checklist (single column, checkbox on the left)
                      Builder(builder: (_) {
                        final items = _env == 'powerlifting'
                            ? _powerEquip
                            : _env == 'home'
                            ? _homeEquip
                            : _travelEquip;

                        return ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,                // 👈 remove outer padding
                          itemCount: items.length,
                          separatorBuilder: (_, __) => Divider(height: 1, color: Colors.blueGrey.shade100),
                          itemBuilder: (_, i) {
                            final label = items[i];
                            final sel = _equipSelected.contains(label);
                            return CheckboxListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              activeColor: Colors.blueAccent,      // <- blue tick
                              checkColor: Colors.white,
                              title: Text(
                                label,
                                style: const TextStyle(
                                  color: Colors.black54,
                                  fontSize: 15.5,  // 👈 change this number (e.g. 13–17) to your taste
                                  fontWeight: FontWeight.w500, // optional: make it stand out a bit more
                                ),
                              ),
                              value: sel,
                              onChanged: (v) {
                                setState(() {
                                  if (v == true) { _equipSelected.add(label); } else { _equipSelected.remove(label); }
                                });
                              },
                            );

                          },
                        );
                      }),
                      const SizedBox(height: 4),

                      // Dumbbells picker (only for powerlifting/home)
                      if (_env == 'powerlifting' || _env == 'home') ...[
                        const SizedBox(height: 0),
                        const _SectionHeader("Dumbbells… (pick one, if any)"),
                        const SizedBox(height: 6),
                        Column(
                          children: [
                            for (final n in (_env == 'powerlifting' ? _powerDb : _homeDb))
                              RadioListTile<int>(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                contentPadding: EdgeInsets.zero,
                                activeColor: Colors.blueAccent,
                                title: Text(
                                  'up to $n',
                                  style: const TextStyle(
                                    color: Colors.black54,
                                    fontSize: 15.5,       // 👈 same size as checklist
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                value: n,
                                groupValue: _dbMax,
                                onChanged: (v) => setState(() => _dbMax = v),
                              ),


                            // ▼ Add explicit "None" option
                            RadioListTile<int>(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              contentPadding: EdgeInsets.zero,
                              activeColor: Colors.blueAccent,
                              title: const Text(
                                'None',
                                style: TextStyle(
                                  color: Colors.black54,
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              value: -1,
                              groupValue: _dbMax,
                              onChanged: (_) => setState(() => _dbMax = -1),
                            ),
                          ],
                        ),
                      ],
                    ],

                    // Details for COMMERCIAL (24 hr / commercial gym)
                    if (_env == 'commercial') ...[
                      const SizedBox(height: 13),
                      const _SectionHeader("Deselect any you do not have access to"),
                      const SizedBox(height: 8),

                      Builder(builder: (_) {
                        final items = _commercialEquip;

                        return ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,
                          itemCount: items.length,
                          separatorBuilder: (_, __) => Divider(height: 1, color: Colors.blueGrey.shade100),
                          itemBuilder: (_, i) {
                            final label = items[i];
                            final sel = _equipSelected.contains(label);
                            return CheckboxListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              activeColor: Colors.blueAccent,
                              checkColor: Colors.white,
                              title: Text(
                                label,
                                style: const TextStyle(
                                  color: Colors.black54,
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              value: sel,
                              onChanged: (v) {
                                setState(() {
                                  if (v == true) {
                                    _equipSelected.add(label);
                                  } else {
                                    _equipSelected.remove(label);
                                  }
                                });
                              },
                            );
                          },
                        );
                      }),
                      const SizedBox(height: 4),
                    ],


                    // New: intended training frequency
                    const SizedBox(height: 18),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.8),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.blueAccent, width: 1.1),
                      ),
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Minimum number of days you can commit to training each week?",
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            "Don’t worry, you can change this later.",
                            style: TextStyle(fontSize: 12.5, color: Colors.black45),
                          ),
                          const SizedBox(height: 8),

                          // radio row/column (force a fresh, stable theme for this section)
                          Theme(
                            data: ThemeData.light().copyWith(
                              useMaterial3: false, // ← hard lock to M2 rendering for clear radio rings
                              unselectedWidgetColor: Colors.blueGrey.shade700, // ring color when not selected
                              radioTheme: RadioThemeData(
                                fillColor: MaterialStateProperty.resolveWith((states) {
                                  return states.contains(MaterialState.selected)
                                      ? Colors.blueAccent // selected dot/ring
                                      : Colors.blueGrey.shade700; // unselected ring
                                }),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              listTileTheme: const ListTileThemeData(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            child: Column(
                              children: [2, 3, 4, 5, 6, 7].map((d) {
                                return RadioListTile<int>(
                                  value: d,
                                  groupValue: _minTrainingDays,
                                  // Let the Theme control colors; don't set activeColor here
                                  onChanged: (v) => setState(() => _minTrainingDays = v),
                                  title: Text(
                                    '$d ${d == 1 ? '' : ''} X week',
                                    style: const TextStyle(fontSize: 13.5),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),

                        ],
                      ),
                    ),


                    // E) Optional best efforts
                    const SizedBox(height: 19),
                    _SectionHeader("OPTIONAL Bits:", color: Colors.black),

                    const SizedBox(height: 6),
                    // 🟦 How hard would you like to train?
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "How much do you want to be pushed?",
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),

                          // Styled radio options
                          ...List.generate(_trainingEffortLabels.length, (index) {
                            final label = _trainingEffortLabels[index];
                            final value = index + 1; // 1..4
                            return Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: _trainingEffort == value
                                      ? Colors.blueAccent
                                      : Colors.grey.shade300,
                                  width: _trainingEffort == value ? 2 : 1,
                                ),
                                borderRadius: BorderRadius.circular(12),
                                color: _trainingEffort == value
                                    ? Colors.blueAccent.withOpacity(0.08)
                                    : Colors.white.withOpacity(0.9),
                              ),
                              child: RadioListTile<int>(
                                dense: true,
                                activeColor: Colors.blueAccent, // 👈 matches rest of UI
                                contentPadding:
                                const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                                value: value,
                                groupValue: _trainingEffort,
                                onChanged: (val) {
                                  setState(() => _trainingEffort = val);
                                },
                                title: Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: _trainingEffort == value
                                        ? Colors.blueAccent
                                        : Colors.black87,
                                    fontWeight: _trainingEffort == value
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                            );
                          }),

                          const SizedBox(height: 6),
                          const Text(
                            "Totally optional — you can change this later.",
                            style: TextStyle(fontSize: 11, color: Colors.black45),
                          ),
                        ],
                      ),
                    ),




                    const SizedBox(height: 6),
                    const Text(
                      "To customise your starting strength level, add your best lift for any you remember, using Kgs"
                          " 🇳🇿\n"
                          "No worries if you can't remember right now — it’ll figure it out as you use the app.",
                      style: TextStyle(
                        color: Colors.black87,
                        fontSize: 15,
                        height: 1.35,
                      ),
                      textAlign: TextAlign.left,
                    ),

                    const SizedBox(height: 8),
                    // Bench / DB
                    _BestEffortRow(
                      variants: const ['Bench Press', 'Flat DB Press', 'Chest Press'],
                      selected: _benchVariant,
                      onVariantChanged: (v) => setState(() => _benchVariant = v),
                      weightCtrl: _benchWeightCtrl,
                      repsCtrl: _benchRepsCtrl,
                    ),
                    const SizedBox(height: 8),

// Squat / Leg Press
                    _BestEffortRow(
                      variants: const ['Back Squat', 'Leg Press'],
                      selected: _squatVariant,
                      onVariantChanged: (v) => setState(() => _squatVariant = v),
                      weightCtrl: _squatWeightCtrl,
                      repsCtrl: _squatRepsCtrl,
                    ),
                    const SizedBox(height: 8),

// Chin-up / Lat Pulldown
                    _BestEffortRow(
                      variants: const [
                        'Lat Pull Down, Supinated',
                        'Lat Pull Down, Wide Arm',
                      ],
                      selected: _pullVariant,
                      onVariantChanged: (v) => setState(() => _pullVariant = v),
                      weightCtrl: _pullWeightCtrl,
                      repsCtrl: _pullRepsCtrl,
                    ),


                    const SizedBox(height: 8),

// Deadlift (single option still supported)
                    _BestEffortRow(
                      variants: const ['Deadlift'],
                      selected: _deadVariant,
                      onVariantChanged: (v) => setState(() => _deadVariant = v),
                      weightCtrl: _deadWeightCtrl,
                      repsCtrl: _deadRepsCtrl,
                    ),



                    const SizedBox(height: 20),

                    // Back (smaller, same family, sits above Finish)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () {
                          if (isEditMode) {
                            // If navigated from Templates → go back there
                            if (entryFrom == 'templates') {
                              Navigator.pushReplacementNamed(context, '/templates');
                            }
                            // If navigated from Drawer → go back home
                            else if (entryFrom == 'drawer') {
                              Navigator.pushReplacementNamed(context, '/home');
                            }
                          } else {
                            // Default behavior during onboarding
                            Navigator.pop(context);
                          }
                        },
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: const BorderSide(color: Colors.blueAccent),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          foregroundColor: Colors.blueAccent,
                        ),
                        child: Text(
                          isEditMode ? 'Back to ${entryFrom == 'templates' ? 'Templates' : 'Home'}'
                              : 'Back',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                    ),

                    const SizedBox(height: 10),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _saving ? null : (_uiIsValid() ? _finish : null),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          backgroundColor: Colors.blueAccent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: _saving
                            ? const CircularProgressIndicator(color: Colors.white)
                            : Text(isEditMode ? 'Save Changes' : 'Finish', style: const TextStyle(fontSize: 18)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    )
    );

  }
}

// ── Small UI helpers (match your Page 1 look)
class _SectionHeader extends StatelessWidget {
  final String text;
  final Color color;
  final TextAlign textAlign;
  const _SectionHeader(this.text, {this.color = Colors.black54,this.textAlign = TextAlign.left, super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        textAlign: textAlign, // 👈 Add this
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,     // stronger header
          color: color,                    // default black54
        ),
      ),
    );
  }
}


class _LabeledField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  const _LabeledField({required this.controller, required this.label, required this.hint});
  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      style: const TextStyle(color: Colors.black54),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.blueAccent),
        hintText: hint,
        hintStyle: TextStyle(color: Colors.blueAccent.withOpacity(0.6), fontSize: 16),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.blueAccent)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.lightBlue, width: 2)),
      ),
    );
  }
}

// Drag-to-rank goals (kept lightweight)
class _GoalsRanker extends StatefulWidget {
  final List<String> items;
  final void Function(List<String> main, List<String> notImportant) onChanged;

  // 👇 Add these two fields to the widget
  final String? sex;
  final String? dob;

  const _GoalsRanker({
    required this.items,
    required this.onChanged,
    this.sex,
    this.dob, // 👈 make sure both are optional but accepted
    Key? key,
  }) : super(key: key);

  @override
  State<_GoalsRanker> createState() => _GoalsRankerState();
}

class _GoalsRankerState extends State<_GoalsRanker> {
  late List<String> mainGoals;
  late List<String> notImportantGoals;

  @override
  void initState() {
    super.initState();
    mainGoals = List.from(widget.items);
    notImportantGoals = [];

  }

  // (Old ReorderableListView callback no longer used)
  void _onReorder(int oldIndex, int newIndex) {
    // kept for compatibility; not used in the custom drag layout
  }

  // 👇 The dynamic header based on sex
  String get _unimportantHeader {
    final s = (widget.sex ?? '').toUpperCase();

    if (s == 'M') {
      return "Couldn’t care less tbh";
    } else {
      return "Low-priority stuff 💅";
    }
  }



  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // --- Main "Important" Area (custom drag + insert slots) ---
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.9),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.blueAccent, width: 1.3),
            boxShadow: [
              BoxShadow(
                color: Colors.blueAccent.withOpacity(0.08),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(4, 4, 2, 6),
          child: SizedBox(
            height: 598,
            child: Column(
              children: [
                // Top insert slot (drop here to put item at index 0)
                _MainInsertSlot(
                  onAccept: (item) {
                    setState(() {
                      notImportantGoals.remove(item);
                      mainGoals.remove(item);
                      mainGoals.insert(0, item);
                      widget.onChanged(mainGoals, notImportantGoals);
                    });
                  },
                ),

                // For each goal: draggable tile + insert slot after it
                for (int i = 0; i < mainGoals.length; i++) ...[
                  LongPressDraggable<String>(
                    data: mainGoals[i],
                    feedback: Material(
                      color: Colors.transparent,
                      child: Card(
                        elevation: 6,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(color: Colors.blueGrey.shade200),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                          child: Text(
                            mainGoals[i],
                            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                    childWhenDragging: Opacity(
                      opacity: 0.4,
                      child: _GoalTile(label: mainGoals[i]),
                    ),
                    child: _GoalTile(label: mainGoals[i]),
                  ),

                  // Insert slot after this item (drop here to place at i+1)
                  _MainInsertSlot(
                    onAccept: (item) {
                      setState(() {
                        notImportantGoals.remove(item);
                        mainGoals.remove(item);
                        final insertAt = (i + 1).clamp(0, mainGoals.length);
                        mainGoals.insert(insertAt, item);
                        widget.onChanged(mainGoals, notImportantGoals);
                      });
                    },
                  ),
                ],
              ],
            ),
          ),

        ),

        const SizedBox(height: 11),

        // --- Not Important Drop Area ---
        DragTarget<String>(
          onAccept: (item) {
            setState(() {
              if (mainGoals.remove(item) && !notImportantGoals.contains(item)) {
                notImportantGoals.add(item);
                widget.onChanged(mainGoals, notImportantGoals);
              }
            });
          },
          builder: (context, candidateData, rejectedData) {
            final hovering = candidateData.isNotEmpty;
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: hovering ? Colors.grey.shade200 : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blueAccent, width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _unimportantHeader,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),

                  const SizedBox(height: 6),
                  if (notImportantGoals.isEmpty)
                    const Text(
                      '🦉 Drag and drop any goals here you don’t give two hoots about.',
                      style: TextStyle(color: Colors.black54, fontSize: 13),
                    ),
                  for (final item in notImportantGoals)
                    LongPressDraggable<String>(
                      data: item,
                      feedback: Material(
                        color: Colors.transparent,
                        child: Card(
                          elevation: 4,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            child: Text(item, style: const TextStyle(fontSize: 14)),
                          ),
                        ),
                      ),
                      childWhenDragging: Opacity(
                        opacity: 0.5,
                        child: ListTile(
                          dense: true,
                          title: Text(item),
                          leading: const Icon(Icons.remove_circle_outline, color: Colors.grey),
                        ),
                      ),
                      child: ListTile(
                        dense: true,
                        title: Text(item),
                        leading: const Icon(Icons.remove_circle_outline, color: Colors.grey),
                        // quick tap to move back up (adds to end of main list)
                        onTap: () {
                          setState(() {
                            notImportantGoals.remove(item);
                            if (!mainGoals.contains(item)) mainGoals.add(item);
                            widget.onChanged(mainGoals, notImportantGoals);
                          });
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}


class _GoalTile extends StatelessWidget {
  final String label;
  const _GoalTile({required this.label});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: 0, vertical: -2), // 👈 tighter vertical layout
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0), // 👈 less inner padding
      tileColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.blueGrey.shade100),
      ),
      leading: const Icon(Icons.drag_indicator, color: Colors.black45),
      title: Text(
        label,
        style: const TextStyle(fontSize: 15.5, color: Colors.black87, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _MainInsertSlot extends StatelessWidget {
  final void Function(String item) onAccept;
  const _MainInsertSlot({required this.onAccept});

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAccept: (d) => d != null,
      onAccept: onAccept,
      builder: (context, candidate, rejected) {
        final isHover = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(vertical: 2),
          height: 12,
          decoration: BoxDecoration(
            color: isHover ? Colors.lightBlue.withOpacity(0.25) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
        );
      },
    );
  }
}



class _BestEffortRow extends StatelessWidget {
  final List<String> variants;
  final String selected;
  final ValueChanged<String> onVariantChanged;
  final TextEditingController weightCtrl;
  final TextEditingController repsCtrl;

  const _BestEffortRow({
    Key? key,
    required this.variants,
    required this.selected,
    required this.onVariantChanged,
    required this.weightCtrl,
    required this.repsCtrl,
  }) : super(key: key);

  double? _calcE1RM(String wTxt, String rTxt) {
    final w = double.tryParse(wTxt.trim());
    final r = double.tryParse(rTxt.trim());
    if (w == null || r == null) return null;
    final val = PeriodizationModelUtils.calculateE1RM(w, r, null);
    return double.parse(val.toStringAsFixed(1));
  }

  @override
  Widget build(BuildContext context) {
    final hasDropdown = variants.length > 1;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          final dropdownW = totalWidth * 0.28;
          final fieldW = totalWidth * 0.14;
          final chipW = totalWidth * 0.20;

          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                // ▼ Dropdown (compact)
                SizedBox(
                  width: dropdownW.clamp(100, 200),
                  child: hasDropdown
                      ? Builder(
                    builder: (_) {
                      final effectiveSelected =
                      variants.contains(selected) ? selected : variants.first;

                      return DropdownButtonHideUnderline(
                        child: DropdownButtonFormField<String>(
                          value: effectiveSelected,
                          isExpanded: true,
                          menuMaxHeight: 300,
                          items: variants
                              .map(
                                (v) => DropdownMenuItem(
                              value: v,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minWidth: 240, // widen popup menu
                                ),
                                child: Text(
                                  v,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black87,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          )
                              .toList(),
                          onChanged: (v) {
                            if (v != null) onVariantChanged(v);
                          },
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding:
                            const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: const BorderSide(color: Colors.blueAccent),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: const BorderSide(color: Colors.blueAccent),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide:
                              const BorderSide(color: Colors.lightBlue, width: 2),
                            ),
                            filled: true,
                            fillColor: Colors.white.withOpacity(0.9),
                          ),
                          dropdownColor: Colors.white,
                        ),
                      );
                    },
                  )
                      : InputDecorator(
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Colors.blueAccent),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Colors.blueAccent),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide:
                        const BorderSide(color: Colors.lightBlue, width: 2),
                      ),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.9),
                    ),
                    child: Text(
                      variants.first,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black87,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),

                // ▼ Weight
                SizedBox(
                  width: fieldW.clamp(60, 120),
                  child: TextFormField(
                    controller: weightCtrl,
                    keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                    ],
                    style: const TextStyle(color: Colors.black87),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'kg',
                      hintStyle: TextStyle(color: Colors.black54.withOpacity(0.7)),
                      contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Colors.blueAccent),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Colors.blueAccent),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide:
                        const BorderSide(color: Colors.lightBlue, width: 2),
                      ),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.9),
                    ),
                  ),
                ),
                const SizedBox(width: 2),

                // ▼ Reps
                SizedBox(
                  width: fieldW.clamp(28, 100),
                  child: TextFormField(
                    controller: repsCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(color: Colors.black87),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'reps',
                      hintStyle: TextStyle(color: Colors.black54.withOpacity(0.7)),
                      contentPadding:
                      const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Colors.blueAccent),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Colors.blueAccent),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide:
                        const BorderSide(color: Colors.lightBlue, width: 2),
                      ),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.9),
                    ),
                  ),
                ),
                const SizedBox(width: 2),

                // ▼ e1RM chip (auto updates)
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: weightCtrl,
                  builder: (_, __, ___) {
                    return ValueListenableBuilder<TextEditingValue>(
                      valueListenable: repsCtrl,
                      builder: (_, __, ___) {
                        final e1 = _calcE1RM(weightCtrl.text, repsCtrl.text);
                        return Container(
                          width: chipW.clamp(80, 120),
                          padding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.blueAccent, width: 1.3),
                            color: Colors.white.withOpacity(0.9),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.blueAccent.withOpacity(0.08),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Text(
                            e1 == null ? 'E1RM' : e1.toStringAsFixed(1),
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: e1 == null
                                  ? Colors.black54
                                  : Colors.black87,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}



//body part visual picker
class BodyFocusPickerPng extends StatefulWidget {
  final String? sex; // 'M'|'F'|'N' (N defaults to M)
  final Set<String> initialSelection;
  final ValueChanged<Set<String>> onChanged;

  /// Assumption: PNG shows FRONT on the LEFT half, BACK on the RIGHT half.
  /// If yours is reversed, flip [frontOnLeft] to false.
  final bool frontOnLeft;

  const BodyFocusPickerPng({
    super.key,
    required this.onChanged,
    this.sex,
    this.initialSelection = const {},
    this.frontOnLeft = true,
  });

  @override
  State<BodyFocusPickerPng> createState() => _BodyFocusPickerPngState();
}

class _BodyFocusPickerPngState extends State<BodyFocusPickerPng> {
  bool _front = true;
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.initialSelection};
  }

  String get _sex => (widget.sex == 'F') ? 'F' : 'M';

  String get _assetPath {
    return _sex == 'F'
        ? 'assets/branding/anatomy/female_anatomy.png'
        : 'assets/branding/anatomy/male_anatomy.png';
  }

  // Rects are 0..1 relative to the HALF we display (not the full image).
  Map<String, List<Rect>> get _zones {
    if (_front) {
      return {
        'Shoulders': [Rect.fromLTWH(0.28, 0.10, 0.12, 0.08), Rect.fromLTWH(0.60, 0.10, 0.12, 0.08)],
        'Chest':     [Rect.fromLTWH(0.38, 0.18, 0.24, 0.10)],
        'Arms':      [Rect.fromLTWH(0.20, 0.20, 0.08, 0.28), Rect.fromLTWH(0.72, 0.20, 0.08, 0.28)],
        'Abs':       [Rect.fromLTWH(0.42, 0.30, 0.16, 0.16)],
        'Quads':     [Rect.fromLTWH(0.38, 0.50, 0.10, 0.20), Rect.fromLTWH(0.52, 0.50, 0.10, 0.20)],
        'Calves':    [Rect.fromLTWH(0.40, 0.76, 0.08, 0.16), Rect.fromLTWH(0.52, 0.76, 0.08, 0.16)],
      };
    } else {
      return {
        'Back':       [Rect.fromLTWH(0.36, 0.20, 0.28, 0.14)],
        'Shoulders':  [Rect.fromLTWH(0.28, 0.10, 0.12, 0.08), Rect.fromLTWH(0.60, 0.10, 0.12, 0.08)],
        'Arms':       [Rect.fromLTWH(0.20, 0.20, 0.08, 0.28), Rect.fromLTWH(0.72, 0.20, 0.08, 0.28)],
        'Glutes':     [Rect.fromLTWH(0.40, 0.44, 0.20, 0.10)],
        'Hamstrings': [Rect.fromLTWH(0.38, 0.54, 0.10, 0.18), Rect.fromLTWH(0.52, 0.54, 0.10, 0.18)],
        'Calves':     [Rect.fromLTWH(0.40, 0.76, 0.08, 0.16), Rect.fromLTWH(0.52, 0.76, 0.08, 0.16)],
      };
    }
  }

  void _toggle(String part) {
    setState(() {
      if (_selected.contains(part)) {
        _selected.remove(part);
      } else {
        _selected.add(part);
        HapticFeedback.selectionClick();
      }
    });
    widget.onChanged(_selected);
  }

  @override
  Widget build(BuildContext context) {
    // Which half of the image should we show?
    // If your PNG has front on RIGHT, set frontOnLeft=false in the constructor.
    final showLeftHalf = widget.frontOnLeft ? _front : !_front;

    return Column(
      children: [
        // Front/Back toggle
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.blueGrey.shade50,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _segButton(label: 'Front', active: _front, onTap: () => setState(() => _front = true)),
              const SizedBox(width: 8),
              _segButton(label: 'Back',  active: !_front, onTap: () => setState(() => _front = false)),
            ],
          ),
        ),
        const SizedBox(height: 12),

        AspectRatio(
          aspectRatio: 3 / 5, // tweak to your image proportions if needed
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final h = constraints.maxHeight;

              return Stack(
                children: [
                  // Show only half of the image
                  Positioned.fill(
                    child: ClipRect(
                      child: Align(
                        alignment: showLeftHalf ? Alignment.centerLeft : Alignment.centerRight,
                        widthFactor: 0.5, // show half
                        child: Image.asset(_assetPath, fit: BoxFit.contain),
                      ),
                    ),
                  ),

                  // Glow overlays for selected zones
                  ..._zones.entries.expand((entry) {
                    final name = entry.key;
                    final rects = entry.value;
                    final selected = _selected.contains(name);
                    return rects.map((r) {
                      final rr = Rect.fromLTWH(r.left * w, r.top * h, r.width * w, r.height * h);
                      return AnimatedOpacity(
                        key: ValueKey('glow_$name${rr.topLeft}'),
                        duration: const Duration(milliseconds: 160),
                        opacity: selected ? 0.23 : 0.0,
                        child: Positioned.fromRect(
                          rect: rr,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.cyanAccent,
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: selected
                                  ? [BoxShadow(color: Colors.cyanAccent.withOpacity(0.35), blurRadius: 12)]
                                  : [],
                            ),
                          ),
                        ),
                      );
                    });
                  }).toList(),

                  // Tap hitboxes
                  ..._zones.entries.expand((entry) {
                    final name = entry.key;
                    final rects = entry.value;
                    return rects.map((r) {
                      final rr = Rect.fromLTWH(r.left * w, r.top * h, r.width * w, r.height * h);
                      return Positioned.fromRect(
                        key: ValueKey('tap_$name${rr.topLeft}'),
                        rect: rr,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _toggle(name),
                            splashColor: Colors.cyanAccent.withOpacity(0.2),
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: IgnorePointer(
                                  child: AnimatedOpacity(
                                    duration: const Duration(milliseconds: 160),
                                    opacity: _selected.contains(name) ? 1 : 0.0,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.black87,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        name,
                                        style: const TextStyle(color: Colors.white, fontSize: 10),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    });
                  }).toList(),
                ],
              );
            },
          ),
        ),

        const SizedBox(height: 12),

        // Selected chips
        Wrap(
          spacing: 8, runSpacing: 8,
          children: _selected.map((p) => Chip(
            label: Text(p),
            deleteIcon: const Icon(Icons.close, size: 16),
            onDeleted: () => _toggle(p),
          )).toList(),
        ),
      ],
    );
  }

  Widget _segButton({required String label, required bool active, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.blueAccent : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? Colors.lightBlue : Colors.blueGrey.shade200),
          boxShadow: active ? [BoxShadow(color: Colors.lightBlue.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 2))] : [],
        ),
        child: Text(
          label,
          style: TextStyle(color: active ? Colors.white : Colors.black54, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
class _ParentWithChildrenChip extends StatelessWidget {
  final String parent;
  final int parentLevel; // 0..3
  final VoidCallback onParentCycle;

  final bool moreSpecific;
  final List<String> subGroups;
  final int Function(String child) getChildLevel;
  final void Function(String child, int current) onChildCycle;

  const _ParentWithChildrenChip({
    super.key,
    required this.parent,
    required this.parentLevel,
    required this.onParentCycle,
    required this.moreSpecific,
    required this.subGroups,
    required this.getChildLevel,
    required this.onChildCycle,
  });

  @override
  Widget build(BuildContext context) {
    // Parent visuals (same as your switch)
    final pv = _chipVisuals(parentLevel);

    // Compact child chip visuals builder (same palette, smaller)
    Widget _childChip(String child, int lvl) {
      late final Color borderColor;
      late final Color labelColor;
      late final Color bgColor;
      late final double borderW;
      late final FontWeight fw;

      switch (lvl) {
        case 1:
          borderColor = Colors.lightBlue;
          labelColor  = Colors.blue.shade700;
          bgColor     = Colors.lightBlue.shade50;
          borderW     = 1;
          fw          = FontWeight.w600;
          break;
        case 2:
          borderColor = Colors.blueAccent.shade100;
          labelColor  = Colors.blue.shade700;
          bgColor     = Colors.lightBlue.shade200;
          borderW     = 1.2;
          fw          = FontWeight.w700;
          break;
        case 3:
          borderColor = Colors.blueAccent.shade100;
          labelColor  = Colors.blue.shade700;
          bgColor     = Colors.lightBlue.shade400;
          borderW     = 1.2;
          fw          = FontWeight.w800;
          break;
        default:
          borderColor = Colors.blueAccent;
          labelColor  = Colors.black54;
          bgColor     = Colors.white;
          borderW     = 1;
          fw          = FontWeight.w500;
      }

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1), // ✅ tighter vertical spacing
        child: Transform.scale(
          scale: 0.9, // ✅ reduce overall height/size by ~10%
          alignment: Alignment.centerLeft,
          child: ChoiceChip(
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, // ✅ reduce tap height
            label: Text(
              child,
              style: TextStyle(
                fontWeight: fw,
                color: labelColor,
                fontSize: 13, // ✅ smaller font
                height: 1.0,  // ✅ tighter line height
              ),
            ),
            selected: lvl > 0,
            showCheckmark: false,
            selectedColor: bgColor,
            backgroundColor: Colors.white,
            shape: StadiumBorder(side: BorderSide(color: borderColor, width: borderW)),
            onSelected: (_) => onChildCycle(child, lvl),
          ),
        ),
      );
    }


    // Parent chip
    final parentChip = ChoiceChip(
      label: Text(
        parent,
        style: TextStyle(fontWeight: pv.fw, color: pv.labelColor, fontSize: 14.5),
      ),
      showCheckmark: false,
      selected: parentLevel > 0,
      selectedColor: pv.bgColor,
      backgroundColor: Colors.white,
      shape: StadiumBorder(side: BorderSide(color: pv.borderColor, width: pv.borderW)),
      onSelected: (_) => onParentCycle(),
    );

    if (!moreSpecific || subGroups.isEmpty) {
      // Default: just the parent chip
      return parentChip;
    }

    // Inline cluster: Parent chip + short connectors + compact child chips
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        parentChip,
        const SizedBox(width: 8),
        // Child column, each with a short (possibly diagonal) connector
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: subGroups.asMap().entries.map((entry) {
            final i = entry.key;
            final child = entry.value;
            final lvl = getChildLevel(child);

            // Decide connector angle based on position in the list:
            // - top items tilt downward (positive angle)
            // - bottom items tilt upward (negative angle)
            // - middle item stays horizontal (0)
            final mid = (subGroups.length - 1) / 2.0;
            double rel = subGroups.length > 1 ? (i - mid) / mid : 0.0; // -1..0..+1
            if (rel.isNaN || rel.isInfinite) rel = 0.0;
            // Scale + clamp to a nice subtle tilt (≈ ±22°)
            final angle = (rel.clamp(-1.0, 1.0) as double) * 0.45; // radians (~22° max)

            final connectorColor = Colors.blueAccent.withOpacity(0.6);

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Diagonal segment
                  Transform.rotate(
                    angle: angle,
                    alignment: Alignment.centerLeft,
                    child: Container(width: 18, height: 2, color: connectorColor),
                  ),
                  const SizedBox(width: 6),
                  _childChip(child, lvl),

                ],
              ),
            );
          }).toList(),
        ),

      ],
    );
  }

  // Visual pack identical to your switch cases
  _Vis _chipVisuals(int lvl) {
    late final Color borderColor;
    late final Color labelColor;
    late final Color bgColor;
    late final double borderW;
    late final FontWeight fw;

    switch (lvl) {
      case 1:
        borderColor = Colors.lightBlue;
        labelColor  = Colors.blue.shade700;
        bgColor     = Colors.lightBlue.shade50;
        borderW     = 1;
        fw          = FontWeight.w700;
        break;
      case 2:
        borderColor = Colors.blueAccent.shade100;
        labelColor  = Colors.blue.shade700;
        bgColor     = Colors.lightBlue.shade200;
        borderW     = 1.2;
        fw          = FontWeight.w800;
        break;
      case 3:
        borderColor = Colors.blueAccent.shade100;
        labelColor  = Colors.blue.shade700;
        bgColor     = Colors.lightBlue.shade400;
        borderW     = 1.2;
        fw          = FontWeight.w800;
        break;
      default:
        borderColor = Colors.blueAccent;
        labelColor  = Colors.black54;
        bgColor     = Colors.white;
        borderW     = 1;
        fw          = FontWeight.w600;
    }
    return _Vis(borderColor, labelColor, bgColor, borderW, fw);
  }
}

class _Vis {
  final Color borderColor, labelColor, bgColor;
  final double borderW;
  final FontWeight fw;
  _Vis(this.borderColor, this.labelColor, this.bgColor, this.borderW, this.fw);
}


