import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async'; // for Timer debounce
import 'package:flutter/services.dart'; // for TextInputFormatter



import 'package:localtest222/login_screen.dart';

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
                                    onPressed: _isLoading ? null : _register,
                                    child: _isLoading
                                        ? const CircularProgressIndicator(
                                        color: Colors.white)
                                        : const Text(
                                      'Sign Up',
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
