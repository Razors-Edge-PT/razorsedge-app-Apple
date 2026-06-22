import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_debug.dart';
import 'create_new_account_screen.dart';
import 'template_generator.dart';



class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  Future<void> _upsertUserDoc(User? user) async {
    if (user == null) return;

    final ref = FirebaseFirestore.instance.collection('users').doc(user.uid);

    await ref.set({
      'email': user.email,
      'displayName': user.displayName,
      'photoURL': user.photoURL,
      'providerIds': user.providerData.map((p) => p.providerId).toList(),
      'createdAt': user.metadata.creationTime?.toUtc(),
      'lastLogin': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> signInWithEmailAndPassword() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Clear the explicit-logout flag BEFORE sign-in. AppRoot's
      // authStateChanges handler gates valid-user routing on this flag, so it
      // must already be false when the sign-in fires the auth event — otherwise
      // a prior logout would be treated as still in effect.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('goodlift_explicit_logout', false);
      await prefs.setString('goodlift_last_login_provider', 'password');

      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      await _upsertUserDoc(cred.user);
      await writeAuthBreadcrumb('AUTHLOGIN provider=password uid=${cred.user?.uid}');
      debugPrint('[AUTHLOGIN] email sign-in uid=${cred.user?.uid} — AppRoot will route');
      // No navigation here. AppRoot is the single auth-state authority: its
      // authStateChanges handler creates UserContext, mounts the authenticated
      // Navigator under ChangeNotifierProvider<UserContext>, and selects the
      // startup route. Pushing '/home' here would mount it in the
      // unauthenticated Navigator (no UserContext) → ProviderNotFound.
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      // Guard: a successful sign-in disposes LoginScreen (AppRoot rebuilds)
      // before this runs — never setState after dispose.
      if (mounted) setState(() => _isLoading = false);
    }
  }




  Future<void> signInWithGoogle() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final googleSignIn = GoogleSignIn();
      await googleSignIn.signOut(); // clears cached selection → forces account picker every time
      final googleUser = await googleSignIn.signIn();
      if (googleUser == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // Clear the explicit-logout flag BEFORE the Firebase credential sign-in
      // (see signInWithEmailAndPassword for the rationale).
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('goodlift_explicit_logout', false);
      await prefs.setString('goodlift_last_login_provider', 'google');

      final cred = await FirebaseAuth.instance.signInWithCredential(credential);

      await _upsertUserDoc(cred.user);
      await writeAuthBreadcrumb('AUTHLOGIN provider=google uid=${cred.user?.uid}');
      debugPrint('[AUTHLOGIN] Google sign-in uid=${cred.user?.uid} — AppRoot will route');
      // No navigation here — AppRoot routes on authStateChanges (see email method).
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> signInWithApple() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final appleProvider = AppleAuthProvider()
        ..addScope('email')
        ..addScope('name');

      // Clear the explicit-logout flag BEFORE sign-in (see email method).
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('goodlift_explicit_logout', false);
      await prefs.setString('goodlift_last_login_provider', 'apple');

      final cred = await FirebaseAuth.instance.signInWithProvider(appleProvider);
      await _upsertUserDoc(cred.user);
      await writeAuthBreadcrumb('AUTHLOGIN provider=apple uid=${cred.user?.uid}');
      debugPrint('[AUTHLOGIN] Apple sign-in uid=${cred.user?.uid} — AppRoot will route');
      // No navigation here — AppRoot routes on authStateChanges (see email method).
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } catch (_) {
      // user cancelled Apple sheet — loading state reset by finally
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
          // Foreground content in a scrollable view
          SafeArea(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: MediaQuery.of(context).size.height,
                ),
                child: IntrinsicHeight(
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      AnimatedOpacity(
                        opacity: keyboardHeight > 0 ? 0.0 : 1.0,
                        duration: const Duration(milliseconds: 300),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Image.asset(
                            'assets/icon/goodlift_logo_log_in.png',
                            width: MediaQuery.of(context).size.width,
                            height: 135,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
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
                                  "Welcome Back",
                                  style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black54),
                                ),
                                const SizedBox(height: 16),
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
                                        .hasMatch(value))
                                      return 'Enter a valid email';
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 12),
                                TextFormField(
                                  controller: _passwordController,
                                  obscureText: _obscurePassword,
                                  style: const TextStyle(color: Colors.black54),
                                  decoration: InputDecoration(
                                    labelText: 'Password',
                                    labelStyle:
                                    const TextStyle(color: Colors.blueAccent),
                                    hintText: 'Enter your password',
                                    hintStyle: TextStyle(
                                        color: Colors.blueAccent.withOpacity(0.6),
                                        fontSize: 16),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
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
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                        _obscurePassword
                                            ? Icons.visibility
                                            : Icons.visibility_off,
                                        color: Colors.blueAccent,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _obscurePassword = !_obscurePassword;
                                        });
                                      },
                                    ),
                                  ),
                                  validator: (value) {
                                    if (value == null || value.isEmpty)
                                      return 'Please enter your password';
                                    if (value.length < 6)
                                      return 'Password must be at least 6 characters';
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
                                          borderRadius:
                                          BorderRadius.circular(12)),
                                    ),
                                    onPressed: _isLoading
                                        ? null
                                        : signInWithEmailAndPassword,
                                    child: _isLoading
                                        ? const CircularProgressIndicator(
                                        color: Colors.white)
                                        : const Text(
                                      'Login',
                                      style: TextStyle(fontSize: 18),
                                    ),
                                  ),
                                ),
                                if (!Platform.isIOS) ...[
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: GestureDetector(
                                      onTap: _isLoading ? null : signInWithGoogle,
                                      child: Image.asset(
                                        'assets/google_sign_in.png',
                                        height: 50,
                                      ),
                                    ),
                                  ),
                                ],
                                // Apple Sign-In removed for App Review compliance (Guideline 4.8)
                                /* const SizedBox(height: 12),
                                if (Platform.isIOS) ...[
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(vertical: 14),
                                        backgroundColor: Colors.black,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                      onPressed: _isLoading ? null : signInWithApple,
                                      child: const Text(
                                        'Sign in with Apple',
                                        style: TextStyle(fontSize: 18),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                ], */

                               /* TextButton(
                                  onPressed: () async {
                                    await TemplateGenerator.debugPrintExerciseAsset();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Exercise JSON test: see console')),
                                    );
                                  },
                                  child: const Text(
                                    "Test Exercise JSON",
                                    style: TextStyle(color: Colors.green, fontSize: 16),
                                  ),
                                ),
*/

                                TextButton(
                                  onPressed: () {
                                    // TODO: Navigate to Forgot Password Screen
                                  },
                                  child: const Text(
                                    "Forgot Password?",
                                    style: TextStyle(
                                        color: Colors.blueAccent, fontSize: 16),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Create Account option
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20.0),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              backgroundColor: Colors.blueAccent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const CreateNewAccountScreen(),
                                ),
                              );
                            },
                            child: const Text(
                              'New here? Create your account',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 24),
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

