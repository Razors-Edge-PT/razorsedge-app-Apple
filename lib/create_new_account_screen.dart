import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async'; // for Timer debounce
import 'package:flutter/services.dart'; // for TextInputFormatter
import 'package:flutter/services.dart' show HapticFeedback;
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
                                    DropdownMenuItem(value: 'M', child: Text('Male')),
                                    DropdownMenuItem(value: 'F', child: Text('Female')),
                                    DropdownMenuItem(value: 'N', child: Text('Human, probably')),
                                  ],
                                  onChanged: (v) => setState(() => _selectedSex = v),
                                  validator: (v) => (v == null || v.isEmpty) ? 'Please select your sex' : null,
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
    'Get leaner',
    'Feel healthier / move better',
    'Tone and shape',
    'Defeat my gym nemesis',
  ].toList();

  List<String> _notImportantGoals = [];

  // ── B) Body focus (conditional if “muscle/toned” is relevant): simple checklist for v1
  final List<String> _bodyParts = const [
    'Chest', 'Back', 'Shoulders', 'Arms', 'Abs', 'Glutes', 'Quads', 'Hamstrings', 'Calves'
  ];
  final Set<String> _bodyFocus = <String>{};
  // 0 = off, 1 = light, 2 = medium, 3 = strong
  final Map<String, int> _bodyFocusLevel = <String, int>{};


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
  ];
  static const List<int> _powerDb = [40, 50, 60];

  static const List<String> _homeEquip = [
    'Squat Rack, Barbell',
    'Bench Press, Barbell',
    'Smith Machine',
    'Leg Extension Machine',
    'Seated Leg Curl Machine',
    'Standing Leg Curl Machine',
    'lying Leg Curl Machine',
    'Leg Press',
    'Chest Press Machine',
    'Seated Row',
    'Lat Pull Down',
    'Cable Stack',
    'Suspension Training system',
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
    '45 Degree Hip Extension',
    'Hack Squat',
    'Triceps Dip Machine',
    'Hip Thrust Machine',
    'Suspension Training System (like TRX)',
    // add any other commercial items you want to show here...
  ];

// ── Defaults pre-selected for commercial gyms
  final Set<String> _commercialDefaults = const {
    'Seated leg curl',
    '45 Degree Hip Extension',
    'Hack Squat',
    'Triceps Dip Machine',
    'Hip Thrust Machine',
    'Suspension Training System (like TRX)',
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
      await onbRef.set(answers.toJson(), SetOptions(merge: true));

      await onbRef.set({
        'bodyFocusLevel': _bodyFocusLevel,
      }, SetOptions(merge: true));


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
    return Scaffold(
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
                    if (_muscleOrTonedChosen) ...[
                      const SizedBox(height: 16),
                      _SectionHeader(
                        "Any areas you’d like to especially focus on?"
                            "\nTap once, twice or thrice for extra emphasis",

                      ),


                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8, runSpacing: 8,
                        children: [
                          // ▼ Row: Select all / Clear all on its own line
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.start,
                              children: [
                                Builder(builder: (_) {
                                  final anySelected = _bodyFocusLevel.values.any((lvl) => lvl > 0);
                                  return ChoiceChip(
                                    showCheckmark: false, // 👈 disables the default tick entirely
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
                                        color: anySelected ? Colors.lightBlue : Colors.blueAccent,
                                        width: 1.2,
                                      ),
                                    ),
                                    onSelected: (_) {
                                      setState(() {
                                        if (anySelected) {
                                          _bodyFocusLevel.clear();
                                        } else {
                                          _bodyFocusLevel
                                            ..clear()
                                            ..addEntries(_bodyParts.map((p) => MapEntry(p, 1)));
                                        }
                                      });
                                    },
                                  );
                                }),

                              ],
                            ),
                          ),


// ▼ Tri-state emphasis chips (tap cycles Off → Light → Strong → Off)
                          ..._bodyParts.map((p) {
                            final lvl = _bodyFocusLevel[p] ?? 0; // 0,1,2,3

                            // Visuals per level
                            late final Color borderColor;
                            late final Color labelColor;
                            late final Color bgColor;
                            late final double borderW;
                            late final FontWeight fw;

                            switch (lvl) {
                              case 1: // emphasised1 (light)
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

                              case 3: // emphasised3 (strong)
                                borderColor = Colors.blueAccent.shade100;
                                labelColor  = Colors.blue.shade700;
                                bgColor     = Colors.lightBlue.shade400;
                                borderW     = 1.2;
                                fw          = FontWeight.w800;
                                break;
                              default: // 0 off
                                borderColor = Colors.blueAccent;
                                labelColor  = Colors.black54;
                                bgColor     = Colors.white;
                                borderW     = 1;
                                fw          = FontWeight.w600;
                            }

                            return ChoiceChip(
                              label: Text(
                                p,
                                style: TextStyle(
                                  fontWeight: fw,
                                  color: labelColor,
                                  fontSize: 14.5,
                                ),
                              ),
                              selected: lvl > 0,
                              showCheckmark: false,                 // 👈 hide tick mark
                              selectedColor: bgColor,               // when selected, use our bg per level
                              backgroundColor: Colors.white,        // base
                              shape: StadiumBorder(
                                side: BorderSide(color: borderColor, width: borderW),
                              ),
                              onSelected: (_) {
                                setState(() {
                                  final next = (lvl + 1) % 4;       // 0→1→2→3→0
                                  if (next == 0) {
                                    _bodyFocusLevel.remove(p);
                                  } else {
                                    _bodyFocusLevel[p] = next;
                                  }
                                });
                              },
                            );
                          }).toList(),
                        ],
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
                                          valueIndicatorTextStyle: const TextStyle(color: Colors.white),
                                        ),
                                        child: Slider(
                                          min: 1,
                                          max: 10,
                                          divisions: 9,
                                          label: _painSlider[k]?.round().toString(),
                                          value: val,
                                          onChanged: (v) => setState(() => _painSlider[k] = v),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
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
                            onChanged: (v) => setState(() => _experience = v),
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
                            onChanged: (v) => setState(() => _experience = v),
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
                          ['Travelling', 'travelling'],
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

                          // radio row/column
                          Column(
                            children: [2, 3, 4, 5, 6, 7].map((d) {
                              return RadioListTile<int>(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                value: d,
                                groupValue: _minTrainingDays,
                                activeColor: Colors.blueAccent,
                                onChanged: (v) {
                                  setState(() {
                                    _minTrainingDays = v;
                                  });
                                },
                                title: Text(
                                  '$d ${d == 1 ? '' : ''} X week',
                                  style: const TextStyle(fontSize: 13.5),
                                ),
                              );
                            }).toList(),
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
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: const BorderSide(color: Colors.blueAccent),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          foregroundColor: Colors.blueAccent,
                        ),
                        child: const Text('Back', style: TextStyle(fontSize: 16)),
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
                            : const Text('Finish', style: TextStyle(fontSize: 18)),
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
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
          child: SizedBox(
            height: 470,
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
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
          margin: const EdgeInsets.symmetric(vertical: 4),
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


