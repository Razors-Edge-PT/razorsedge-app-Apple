import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show listEquals;
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
import 'block_creation_helper.dart';

import 'package:localtest222/login_screen.dart';
import 'signup_validation.dart';
import 'onboarding_identity_payload.dart';
import 'sex_options.dart';
import 'periodization_model_utils.dart';
import 'signup/first_block_seeder.dart';
import 'signup/onboarding_models.dart';
import 'signup/onboarding_writer.dart';
import 'signup/signup_coordinator.dart';
import 'signup/signup_errors.dart';

export 'signup/onboarding_models.dart'
    show TrainingExperience, BestEffort, OnboardingAnswers;

// There is deliberately no pre-account username availability read here any
// more. `users_public` and `usernames` are readable only by a signed-in
// caller, and a logged-out device cannot be one (anonymous sign-in is not
// enabled on the project), so the old Finish-time `users_public` query was
// permission-denied for every new member and blocked signup with "check your
// connection". Uniqueness is decided by the profileChangeUsername callable's
// transaction after the account exists — see signup/signup_coordinator.dart.

class CreateNewAccountScreen extends StatefulWidget {
  const CreateNewAccountScreen({super.key, this.coordinator});

  /// Injected in tests; the app uses [SignupCoordinator.instance].
  final SignupCoordinator? coordinator;

  @override
  State<CreateNewAccountScreen> createState() => _CreateNewAccountScreenState();
}

class _CreateNewAccountScreenState extends State<CreateNewAccountScreen> {
  late final SignupCoordinator _coordinator =
      widget.coordinator ?? SignupCoordinator.instance;

  /// This signup attempt. Owns the draft for both pages, so nothing the member
  /// enters depends on either route staying alive.
  late final SignupAttempt _attempt;

  final _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _fullNameController = TextEditingController();
  /// Canonical DOB carrier. Holds the PERSISTED representation, `dd-mm-yyyy`
  /// (not `yyyy-mm-dd`, as an earlier comment here wrongly claimed).
  final TextEditingController _dobController = TextEditingController();

  /// The picked date. The wheel picker can only produce real calendar dates,
  /// so impossible dates such as 31 February are unreachable by construction.
  DateTime? _dobDate;


  String? _selectedSex; // 'M' | 'F' | 'N'


  bool _isLoading = false;
  String? _errorMessage;
  bool _passwordVisible = false;
  bool _confirmPasswordVisible = false;
  bool _usernameChecking = false;
  bool? _usernameAvailableFlag; // null = unknown, true = available, false = taken
  Timer? _usernameDebounce;

  /// Bumped for every new username value. An availability answer is applied
  /// only if its token is still current AND the field still holds the exact
  /// value it was asked about, so a slow response for "alex" can never mark
  /// "alexa" taken or available.
  int _usernameCheckSeq = 0;

  /// The exact (trimmed) value [_usernameAvailableFlag] describes.
  String? _usernameFlagFor;

  /// Field errors reported by the server at Finish (duplicate email, weak
  /// password, invalid username). Cleared as soon as the field changes.
  final Map<String, String> _serverFieldErrors = <String, String>{};

  final FocusNode _emailFocusNode = FocusNode();
  final FocusNode _usernameFocusNode = FocusNode();
  final FocusNode _fullNameFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();
  final FocusNode _confirmPasswordFocusNode = FocusNode();

  /// Fields the user has actually interacted with. Nothing is marked invalid
  /// on a freshly opened, untouched page — errors only appear once a field has
  /// been touched and left, or once Continue has been pressed.
  final Set<String> _touched = <String>{};

  /// Current inline error per field. This is the single source of truth for
  /// what the user sees: each field renders it via `errorText` AND returns it
  /// from its `validator`, so a message can never be shown twice.
  final Map<String, String?> _fieldErrors = <String, String?>{};

  /// Anchors used to scroll to the first invalid field when Continue fails.
  final Map<String, GlobalKey> _fieldKeys = {
    SignupField.username: GlobalKey(),
    SignupField.fullName: GlobalKey(),
    SignupField.dob: GlobalKey(),
    SignupField.sex: GlobalKey(),
    SignupField.email: GlobalKey(),
    SignupField.password: GlobalKey(),
    SignupField.confirmPassword: GlobalKey(),
  };

  /// Order used both for "first invalid field" and for scroll targeting.
  static const List<String> _fieldOrder = [
    SignupField.username,
    SignupField.fullName,
    SignupField.dob,
    SignupField.sex,
    SignupField.email,
    SignupField.password,
    SignupField.confirmPassword,
  ];


  @override
  void dispose() {
    // The debounce fires 450ms after the last keystroke; without this, leaving
    // the screen mid-type would call setState() on a disposed State.
    _usernameDebounce?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _usernameController.dispose();
    _fullNameController.dispose();
    _dobController.dispose();
    _emailFocusNode.dispose();
    _usernameFocusNode.dispose();
    _fullNameFocusNode.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();

    // Leaving Page 1 (back to Login) is a genuine cancellation: the draft is
    // wiped. A completed attempt is merely released.
    unawaited(_coordinator.cancelAttempt(_attempt));

    super.dispose();
  }

  /// Mirrors every Page 1 field into the attempt's draft as it changes, so
  /// the coordinator always submits exactly what is on screen.
  void _bindDraft() {
    final d = _attempt.draft.identity;
    void bind(TextEditingController c, void Function(String) write) {
      c.addListener(() => write(c.text));
    }

    bind(_usernameController, (v) => d.username = v);
    bind(_fullNameController, (v) => d.fullName = v);
    bind(_emailController, (v) => d.email = v);
    bind(_passwordController, (v) => d.password = v);
    bind(_confirmPasswordController, (v) => d.confirmPassword = v);
  }

  void _onUsernameChanged(String raw) {
    _usernameDebounce?.cancel();
    final v = raw.trim();
    final token = ++_usernameCheckSeq;
    _serverFieldErrors.remove(SignupField.username);

    // Reset quick flags
    setState(() {
      _usernameAvailableFlag = null;
      _usernameFlagFor = null;
      _usernameChecking = false;
    });

    // Keep the inline error live while the user corrects it.
    _revalidate(SignupField.username);

    // Quick local format check — no point asking the server about a username
    // that cannot be valid anyway.
    if (validateUsername(v) != null) {
      return;
    }

    _usernameDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      _checkUsername(v, token);
    });
  }

  /// Advisory availability for [value]. Applied only while [token] is current
  /// and the field still holds [value]; otherwise silently discarded.
  Future<void> _checkUsername(String value, int token) async {
    setState(() => _usernameChecking = true);
    final bool? ok = await _coordinator.usernameHint(value);
    if (!mounted) return;
    final stillCurrent = token == _usernameCheckSeq &&
        _usernameController.text.trim() == value;
    if (!stillCurrent) return;
    setState(() {
      _usernameChecking = false;
      _usernameAvailableFlag = ok; // null = unknown: never blocks Continue
      _usernameFlagFor = ok == null ? null : value;
    });
    _revalidate(SignupField.username);
  }

  /// Completes the username availability check immediately rather than waiting
  /// for the debounce — used when the user leaves the field, and again as a
  /// safety net when Continue is pressed.
  Future<void> _resolveUsernameAvailability() async {
    _usernameDebounce?.cancel();
    final v = _usernameController.text.trim();

    // Format problems are reported by the validator; no remote call needed.
    if (validateUsername(v) != null) {
      if (mounted) setState(() => _usernameChecking = false);
      return;
    }
    // Already resolved for this exact value.
    if (_usernameAvailableFlag != null && _usernameFlagFor == v) return;

    // Advisory only. An unknown result leaves Continue allowed; the account
    // is never completed without the server reservation on Finish.
    await _checkUsername(v, ++_usernameCheckSeq);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Per-field validation
  //
  // Nothing is shown on an untouched page. A field becomes "touched" when the
  // user leaves it (or picks a value), and from then on its error is kept live
  // as they correct it. Continue force-touches everything as a final safety net.
  // ───────────────────────────────────────────────────────────────────────────

  /// Computes the current error for [field] from scratch. Pure rules live in
  /// signup_validation.dart; only availability state is local.
  String? _computeFieldError(String field) {
    switch (field) {
      case SignupField.username:
        return validateUsername(_usernameController.text) ??
            _serverFieldErrors[SignupField.username] ??
            usernameAvailabilityError(
                _usernameFlagFor == _usernameController.text.trim()
                    ? _usernameAvailableFlag
                    : null);
      case SignupField.fullName:
        return validateFullName(_fullNameController.text);
      case SignupField.dob:
        return validateDob(_dobDate);
      case SignupField.sex:
        return validateSex(_selectedSex);
      case SignupField.email:
        return validateEmail(_emailController.text) ??
            _serverFieldErrors[SignupField.email];
      case SignupField.password:
        return validatePassword(_passwordController.text) ??
            _serverFieldErrors[SignupField.password];
      case SignupField.confirmPassword:
        return validateConfirmPassword(
            _confirmPasswordController.text, _passwordController.text);
      default:
        return null;
    }
  }

  /// Re-evaluates [field], but only once it has been touched, so a pristine
  /// page never turns red.
  void _revalidate(String field) {
    if (!mounted) return;
    if (!_touched.contains(field)) return;
    final next = _computeFieldError(field);
    if (_fieldErrors[field] == next) return;
    setState(() => _fieldErrors[field] = next);
  }

  /// Marks [field] touched and validates it immediately — used on unfocus.
  void _touchAndValidate(String field) {
    _touched.add(field);
    final next = _computeFieldError(field);
    if (!mounted) return;
    setState(() => _fieldErrors[field] = next);
  }

  /// Wires "validate when the user leaves this field" onto [node].
  void _validateOnUnfocus(FocusNode node, String field) {
    node.addListener(() {
      if (!node.hasFocus) _touchAndValidate(field);
    });
  }

  /// Full-form validation. Touches every field so all problems become visible,
  /// then returns the first invalid field id (in visual order), or null.
  String? _validateAllFields() {
    _touched.addAll(_fieldOrder);
    final errors = <String, String?>{};
    for (final f in _fieldOrder) {
      errors[f] = _computeFieldError(f);
    }
    if (mounted) setState(() => _fieldErrors.addAll(errors));
    for (final f in _fieldOrder) {
      if (errors[f] != null) return f;
    }
    return null;
  }

  /// Brings the first invalid field into view and focuses it when it is a text
  /// field, so Continue never fails silently off-screen.
  Future<void> _revealField(String field) async {
    final ctx = _fieldKeys[field]?.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        alignment: 0.15,
      );
    }
    if (!mounted) return;
    final node = switch (field) {
      SignupField.username => _usernameFocusNode,
      SignupField.fullName => _fullNameFocusNode,
      SignupField.email => _emailFocusNode,
      SignupField.password => _passwordFocusNode,
      SignupField.confirmPassword => _confirmPasswordFocusNode,
      _ => null,
    };
    if (node != null) FocusScope.of(context).requestFocus(node);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Date of birth — wheel picker
  // ───────────────────────────────────────────────────────────────────────────

  /// Applies a date chosen in the picker and keeps the persisted `dd-mm-yyyy`
  /// carrier in sync.
  void _applyPickedDob(DateTime picked) {
    // Normalise to a plain calendar day (no time component).
    final day = DateTime(picked.year, picked.month, picked.day);
    _dobDate = day;
    _attempt.draft.identity.dob = day;
    _dobController.text = formatDobForStorage(day);
    // Choosing a date counts as interacting with the field.
    _touchAndValidate(SignupField.dob);
  }

  /// Opens a premium wheel-style date picker in a rounded modal sheet.
  ///
  /// Uses [CupertinoDatePicker] in date mode with day-first ordering for NZ
  /// users. The wheel can only ever produce real calendar dates, so an
  /// impossible date such as 31 February cannot be selected at all.
  Future<void> _openDobPicker() async {
    // Dismiss any keyboard so the sheet opens against a settled layout.
    FocusScope.of(context).unfocus();

    final now = DateTime.now();
    final lastDate = DateTime(now.year, now.month, now.day);
    final firstDate =
        DateTime(now.year - kMaxPlausibleAgeYears, now.month, now.day);
    // Land the wheel on a sensible adult age so most users spin only a little.
    var temp = _dobDate ?? DateTime(now.year - 25, now.month, now.day);
    if (temp.isAfter(lastDate)) temp = lastDate;
    if (temp.isBefore(firstDate)) temp = firstDate;

    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        var working = temp;
        return SafeArea(
          top: false,
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Grab handle — matches the app's understated sheet language.
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(color: Colors.black54, fontSize: 16),
                        ),
                      ),
                      const Text(
                        'Date of Birth',
                        style: TextStyle(
                          color: Colors.black87,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            Navigator.of(sheetContext).pop(working),
                        child: const Text(
                          'Done',
                          style: TextStyle(
                            color: Colors.blueAccent,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                SizedBox(
                  height: 216,
                  child: CupertinoTheme(
                    data: const CupertinoThemeData(
                      brightness: Brightness.light,
                      textTheme: CupertinoTextThemeData(
                        dateTimePickerTextStyle: TextStyle(
                          color: Colors.black87,
                          fontSize: 20,
                        ),
                      ),
                    ),
                    child: CupertinoDatePicker(
                      mode: CupertinoDatePickerMode.date,
                      dateOrder: DatePickerDateOrder.dmy, // NZ ordering
                      initialDateTime: temp,
                      minimumDate: firstDate,
                      maximumDate: lastDate,
                      onDateTimeChanged: (d) => working = d,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (picked != null) {
      HapticFeedback.selectionClick();
      _applyPickedDob(picked);
    }
  }

  // NOTE — deliberate absence of an email duplicate preflight.
  //
  // `fetchSignInMethodsForEmail` was removed in firebase_auth 6.x, so the old
  // `_checkEmailAvailability()` had become a no-op that only ever drove a
  // spinner and a tick that could never appear. It has been removed rather
  // than left as misleading UI.
  //
  // The remaining ways to detect an already-registered email from the client
  // are all account-enumeration primitives: querying `users_public` by email,
  // or probing Firebase Auth. Either would let anyone check whether a given
  // address has a GoodLift account, which is a privacy/security regression we
  // are not willing to make for a UX nicety. Firebase itself is therefore the
  // authority: the duplicate is caught at account-creation time on Page 2 and
  // reported there with a specific, actionable message.
  //
  // Email FORMAT validation stays immediate and inline, on unfocus.

  void _continueToOnboarding() async {
    // Final safety net: make sure a still-running username check has finished
    // before deciding, so Continue is never blocked by an in-flight result the
    // user cannot see.
    if (_usernameChecking || _usernameAvailableFlag == null) {
      setState(() => _isLoading = true);
      await _resolveUsernameAvailability();
      if (!mounted) return;
      setState(() => _isLoading = false);
    }

    // Validate everything and surface the problem on the field that owns it.
    final firstInvalid = _validateAllFields();
    if (firstInvalid != null) {
      await _revealField(firstInvalid);
      return;
    }
    // Keep the Form in agreement with our own validation.
    _formKey.currentState?.validate();

    // The draft already mirrors every field; sex and DOB are set from their
    // own pickers. Page 2 reads identity and credentials from it at Finish.
    final identity = _attempt.draft.identity
      ..sex = _selectedSex
      ..dob = _dobDate;

    setState(() => _errorMessage = null);

    // A fresh Page 2 route binds to the SAME draft, so returning here and
    // coming back restores every answer.
    final Object? result = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder: (_) => OnboardingPageTwo(
          signup: _attempt,
          email: identity.email.trim(),
          password: identity.password,
          username: identity.username.trim(),
          fullName: identity.fullName.trim(),
          dob: identity.dobStorage, // dd-mm-yyyy
          sex: identity.sex,
        ),
      ),
    );
    if (!mounted || result is! SignupFailure) return;
    await _showFailureOnPageOne(result);
  }

  /// A Finish failure that only Page 1 can fix: put it on the field that owns
  /// it and take the member there. Page 2's answers stay in the draft.
  Future<void> _showFailureOnPageOne(SignupFailure failure) async {
    final String field;
    switch (failure.kind) {
      case SignupFailureKind.usernameTaken:
        field = SignupField.username;
        _usernameCheckSeq++; // discard any in-flight advisory answer
        setState(() {
          _usernameAvailableFlag = false;
          _usernameFlagFor = _usernameController.text.trim();
        });
        break;
      case SignupFailureKind.usernameInvalid:
        field = SignupField.username;
        _serverFieldErrors[field] = failure.message;
        break;
      case SignupFailureKind.emailInUse:
      case SignupFailureKind.invalidEmail:
        field = SignupField.email;
        _serverFieldErrors[field] = failure.message;
        break;
      case SignupFailureKind.weakPassword:
        field = SignupField.password;
        _serverFieldErrors[field] = failure.message;
        break;
      default:
        setState(() => _errorMessage = failure.message);
        return;
    }
    _touchAndValidate(field);
    await _revealField(field);
  }


  @override
  void initState() {
    super.initState();
    _attempt = _coordinator.beginAttempt();
    _bindDraft();

    // Server-reported errors belong to the value they were reported for.
    _emailController.addListener(() {
      if (_serverFieldErrors.remove(SignupField.email) != null) {
        _revalidate(SignupField.email);
      }
    });
    _passwordController.addListener(() {
      if (_serverFieldErrors.remove(SignupField.password) != null) {
        _revalidate(SignupField.password);
      }
    });

    // Validate each field the moment the user leaves it. Nothing is validated
    // before it has been touched, so an untouched page opens clean.
    _validateOnUnfocus(_fullNameFocusNode, SignupField.fullName);
    _validateOnUnfocus(_emailFocusNode, SignupField.email);
    _validateOnUnfocus(_passwordFocusNode, SignupField.password);
    _validateOnUnfocus(_confirmPasswordFocusNode, SignupField.confirmPassword);

    // Username additionally forces its availability check to complete on
    // unfocus rather than relying on the 450ms debounce.
    _usernameFocusNode.addListener(() async {
      if (_usernameFocusNode.hasFocus) return;
      _touched.add(SignupField.username);
      await _resolveUsernameAvailability();
      if (mounted) _touchAndValidate(SignupField.username);
    });
  }

  /// Once this attempt has created the account, its email and password are
  /// fixed: a retry must resume that same account, never start a second one.
  bool get _credentialsLocked => _attempt.accountCreated;



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
                      const SizedBox(height: 20),
                      AnimatedOpacity(
                        opacity: keyboardHeight > 0 ? 0.0 : 1.0,
                        duration: const Duration(milliseconds: 300),
                        child: Center(
                          child: Image.asset(
                            'assets/icon/good_lift_logo2.png',
                            height: 64,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
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
                                  'Build your training profile',
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF1A237E),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  'GoodLift uses this to set up your starting plan.',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    color: Colors.black54,
                                  ),
                                ),
                                const SizedBox(height: 16),

                                // Username (required)
                                TextFormField(
                                  key: _fieldKeys[SignupField.username],
                                  controller: _usernameController,
                                  textInputAction: TextInputAction.next,
                                  style: const TextStyle(color: Colors.black54),
                                  focusNode: _usernameFocusNode,
                                  decoration: InputDecoration(
                                    labelText: 'Username',
                                    labelStyle: const TextStyle(color: Colors.blueAccent),
                                    errorText: _fieldErrors[SignupField.username],
                                    errorStyle: const TextStyle(fontSize: 12),
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
                                  validator: (_) => _fieldErrors[SignupField.username],
                                ),

                                // Only the positive state is rendered here. The
                                // "taken" message is shown by the field's own
                                // errorText, so it is never duplicated.
                                if (_usernameAvailableFlag == true &&
                                    _fieldErrors[SignupField.username] == null) ...[
                                  const SizedBox(height: 6),
                                  const Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'Nice — available!',
                                      style: TextStyle(
                                        color: Colors.green,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],


                                const SizedBox(height: 12),

// Full Name (required)
                                TextFormField(
                                  key: _fieldKeys[SignupField.fullName],
                                  controller: _fullNameController,
                                  focusNode: _fullNameFocusNode,
                                  textCapitalization: TextCapitalization.words,
                                  style: const TextStyle(color: Colors.black54),
                                  onChanged: (_) => _revalidate(SignupField.fullName),
                                  decoration: InputDecoration(
                                    labelText: 'Full Name',
                                    labelStyle: const TextStyle(color: Colors.blueAccent),
                                    errorText: _fieldErrors[SignupField.fullName],
                                    errorStyle: const TextStyle(fontSize: 12),
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
                                  validator: (_) => _fieldErrors[SignupField.fullName],
                                ),

                                const SizedBox(height: 12),

                                const SizedBox(height: 12),

// Date of Birth (required). Tap to open a wheel picker; no manual typing,
// so only real calendar dates are possible. Persisted as dd-mm-yyyy.
                                Semantics(
                                  button: true,
                                  label: 'Date of birth',
                                  value: _dobDate == null
                                      ? 'Not set'
                                      : formatDobForDisplay(_dobDate!),
                                  child: InkWell(
                                    key: _fieldKeys[SignupField.dob],
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: _openDobPicker,
                                    child: InputDecorator(
                                      isEmpty: false,
                                      decoration: InputDecoration(
                                        labelText: 'Date of Birth',
                                        labelStyle:
                                            const TextStyle(color: Colors.blueAccent),
                                        errorText: _fieldErrors[SignupField.dob],
                                        errorStyle: const TextStyle(fontSize: 12),
                                        suffixIcon: const Icon(
                                          Icons.calendar_today,
                                          color: Colors.blueAccent,
                                          size: 20,
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: const BorderSide(
                                              color: Colors.blueAccent),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: const BorderSide(
                                              color: Colors.lightBlue, width: 2),
                                        ),
                                        errorBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide:
                                              const BorderSide(color: Colors.red),
                                        ),
                                        focusedErrorBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: const BorderSide(
                                              color: Colors.redAccent, width: 2),
                                        ),
                                      ),
                                      child: Text(
                                        _dobDate == null
                                            ? 'Select your date of birth'
                                            : formatDobForDisplay(_dobDate!),
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: _dobDate == null
                                              ? Colors.blueAccent.withOpacity(0.6)
                                              : Colors.black54,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),

                                // Invisible Form participant so Form.validate()
                                // still gates on DOB. It mirrors the same
                                // message the field above already shows, so the
                                // error can never appear twice. A FormField
                                // (not a TextFormField) is used deliberately:
                                // it paints nothing and cannot be reached by
                                // focus traversal.
                                FormField<DateTime>(
                                  initialValue: _dobDate,
                                  validator: (_) => _fieldErrors[SignupField.dob],
                                  builder: (_) => const SizedBox.shrink(),
                                ),

                                const SizedBox(height: 12),

// Sex (required)
                                DropdownButtonFormField<String>(
                                  key: _fieldKeys[SignupField.sex],
                                  value: _selectedSex,
                                  style: const TextStyle(color: Colors.black87),
                                  dropdownColor: Colors.white,
                                  validator: (_) => _fieldErrors[SignupField.sex],
                                  decoration: InputDecoration(
                                    labelText: 'Sex',
                                    labelStyle: const TextStyle(color: Colors.blueAccent),
                                    errorText: _fieldErrors[SignupField.sex],
                                    errorStyle: const TextStyle(fontSize: 12),
                                    filled: true,
                                    fillColor: Colors.white,
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
                                  items: [
                                    for (final option in kSexOptionLabels.entries)
                                      DropdownMenuItem(
                                        value: option.key,
                                        child: Text(option.value, style: const TextStyle(color: Colors.black87)),
                                      ),
                                  ],
                                  // Choosing an option counts as interaction,
                                  // so a skipped Sex turns red rather than
                                  // silently blocking Continue.
                                  onChanged: (v) {
                                    setState(() => _selectedSex = v);
                                    _attempt.draft.identity.sex = v;
                                    _touchAndValidate(SignupField.sex);
                                  },
                                ),
                                const SizedBox(height: 12),
                                // Email
                                TextFormField(
                                  key: _fieldKeys[SignupField.email],
                                  controller: _emailController,
                                  enabled: !_credentialsLocked,
                                  focusNode: _emailFocusNode,
                                  keyboardType: TextInputType.emailAddress,
                                  style: const TextStyle(color: Colors.black54),
                                  onChanged: (_) => _revalidate(SignupField.email),
                                  decoration: InputDecoration(
                                    labelText: 'Email',
                                    labelStyle: const TextStyle(color: Colors.blueAccent),
                                    helperText: _credentialsLocked
                                        ? 'Your account was created with this email.'
                                        : null,
                                    errorText: _fieldErrors[SignupField.email],
                                    errorStyle: const TextStyle(fontSize: 12),
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
                                  validator: (_) => _fieldErrors[SignupField.email],
                                ),
                                const SizedBox(height: 12),

                                // Password
                                TextFormField(
                                  key: _fieldKeys[SignupField.password],
                                  controller: _passwordController,
                                  enabled: !_credentialsLocked,
                                  focusNode: _passwordFocusNode,
                                  obscureText: !_passwordVisible,
                                  style: const TextStyle(color: Colors.black54),
                                  // Changing the password re-checks Confirm too,
                                  // so a previously-matching pair goes red again.
                                  onChanged: (_) {
                                    _revalidate(SignupField.password);
                                    _revalidate(SignupField.confirmPassword);
                                  },
                                  decoration: InputDecoration(
                                    labelText: 'Password',
                                    labelStyle: const TextStyle(color: Colors.blueAccent),
                                    errorText: _fieldErrors[SignupField.password],
                                    errorStyle: const TextStyle(fontSize: 12),
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
                                  validator: (_) => _fieldErrors[SignupField.password],
                                ),

                                const SizedBox(height: 12),

                                // Confirm Password
                                // Confirm Password
                                TextFormField(
                                  key: _fieldKeys[SignupField.confirmPassword],
                                  controller: _confirmPasswordController,
                                  enabled: !_credentialsLocked,
                                  focusNode: _confirmPasswordFocusNode,
                                  obscureText: !_confirmPasswordVisible,
                                  style: const TextStyle(color: Colors.black54),
                                  onChanged: (_) =>
                                      _revalidate(SignupField.confirmPassword),
                                  decoration: InputDecoration(
                                    labelText: 'Confirm Password',
                                    labelStyle: const TextStyle(color: Colors.blueAccent),
                                    errorText:
                                        _fieldErrors[SignupField.confirmPassword],
                                    errorStyle: const TextStyle(fontSize: 12),
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
                                  validator: (_) =>
                                      _fieldErrors[SignupField.confirmPassword],
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

// ─────────────────────────────────────────────────────────────────────────────
// Page 2: Onboarding (Goals, Focus, Injuries, Experience, Best Efforts)
// All fields are optional in the model; UI enforces "required" where needed.
// ─────────────────────────────────────────────────────────────────────────────

// TrainingExperience, BestEffort and OnboardingAnswers live in
// signup/onboarding_models.dart (re-exported above).

class OnboardingPageTwo extends StatefulWidget {
  final String email;
  final String password;
  final String? sex;       // 'M' | 'F' | 'N'
  final String? username;
  final String? fullName;
  final String? dob;       // dd-mm-yyyy

  /// The signup attempt this page belongs to, or null in edit mode (Templates
  /// / drawer). Signup mode is decided by this, never by the auth state: an
  /// established account and a half-finished signup can both have a
  /// non-anonymous currentUser.
  final SignupAttempt? signup;

  const OnboardingPageTwo({
    Key? key,
    required this.email,
    required this.password,
    this.sex,
    this.username,
    this.fullName,
    this.dob,
    this.signup,
  }) : super(key: key);

  @override
  State<OnboardingPageTwo> createState() => _OnboardingPageTwoState();
}

class _OnboardingPageTwoState extends State<OnboardingPageTwo> {
  final _formKey = GlobalKey<FormState>();

  /// Anchors on each required section's header, so Finish can scroll the first
  /// unmet requirement into view instead of only naming it in a snack bar.
  final Map<String, GlobalKey> _sectionKeys = {
    OnboardingSection.goals: GlobalKey(),
    OnboardingSection.bodyFocus: GlobalKey(),
    OnboardingSection.injuries: GlobalKey(),
    OnboardingSection.experience: GlobalKey(),
    OnboardingSection.env: GlobalKey(),
  };

  /// Every editable value on this page. During signup this is the attempt's
  /// draft, which outlives this route; in edit mode it is a fresh local copy
  /// that hydration fills from Firestore. The fields below are views onto it,
  /// so all of the existing UI code reads and writes the draft directly and
  /// no answer can be lost when this route is destroyed.
  late final OnboardingFormData _form =
      widget.signup?.draft.onboarding ?? OnboardingFormData();

  SignupAttempt? get _signup => widget.signup;

  // ── A) Goals: full list; user reorders to set priority.
  List<String> get _goals => _form.goals;
  set _goals(List<String> v) => _form.goals = v;

  List<String> get _notImportantGoals => _form.notImportantGoals;
  set _notImportantGoals(List<String> v) => _form.notImportantGoals = v;


  // ── B) Body focus (conditional if “muscle/toned” is relevant): simple checklist for v1
  final List<String> _bodyParts = const [
    'Chest', 'Back', 'Shoulders', 'Arms', 'Abs', 'Glutes', 'Quads', 'Hamstrings', 'Calves'
  ];
  // Order to use when "More specific" is ON
  static const List<String> _bodyPartsSpecificOrder = [
    'Chest','Abs','Hamstrings','Quads','Calves','Glutes','Back','Shoulders','Arms',
  ];

  // 0 = off, 1 = light, 2 = medium, 3 = strong
  Map<String, int> get _bodyFocusLevel => _form.bodyFocusLevel;

  // Toggle to reveal child muscles
  bool get _moreSpecific => _form.moreSpecific;
  set _moreSpecific(bool v) => _form.moreSpecific = v;

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
  Map<String, Map<String, int>> get _childFocusLevel => _form.childFocusLevel;



  // Shoulder / elbow detail flags
  bool get _shoulderPainOverhead => _form.shoulderPainOverhead;
  set _shoulderPainOverhead(bool v) => _form.shoulderPainOverhead = v;
  bool get _shoulderPainFront => _form.shoulderPainFront;
  set _shoulderPainFront(bool v) => _form.shoulderPainFront = v;
  bool get _elbowPainInside => _form.elbowPainInside;
  set _elbowPainInside(bool v) => _form.elbowPainInside = v;
  bool get _elbowPainOutside => _form.elbowPainOutside;
  set _elbowPainOutside(bool v) => _form.elbowPainOutside = v;

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
  // 'commercial' | 'powerlifting' | 'home' | 'travelling'
  String? get _env => _form.env;
  set _env(String? v) => _form.env = v;
  Set<String> get _equipSelected => _form.equipSelected;
  // dumbbell max (e.g., 40, 50, 60; -1 = None)
  int? get _dbMax => _form.dbMax;
  set _dbMax(int? v) => _form.dbMax = v;

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


  int? get _ptHistory => _form.ptHistory; // 0..3 (null = not chosen)
  set _ptHistory(int? v) => _form.ptHistory = v;

  Set<String> get _injuries => _form.injuries;
  // store slider as double 1..10; round to int when saving
  Map<String, double> get _painSlider => _form.painSlider;

  // ── D) Experience: radio
  TrainingExperience? get _experience => _form.experience;
  set _experience(TrainingExperience? v) => _form.experience = v;

  // ── E) Optional best efforts (rows currently hidden). Each controller
  // writes through to the form as it changes, so raw text survives route
  // destruction; the selected variants are kept on [_form] too.
  // Separate weight + reps controllers for each
  late final TextEditingController _benchWeightCtrl = _bound(BestEffortField.benchWeight);
  late final TextEditingController _benchRepsCtrl = _bound(BestEffortField.benchReps);

  late final TextEditingController _squatWeightCtrl = _bound(BestEffortField.squatWeight);
  late final TextEditingController _squatRepsCtrl = _bound(BestEffortField.squatReps);

  late final TextEditingController _pullWeightCtrl = _bound(BestEffortField.pullWeight);
  late final TextEditingController _pullRepsCtrl = _bound(BestEffortField.pullReps);

  late final TextEditingController _deadWeightCtrl = _bound(BestEffortField.deadWeight);
  late final TextEditingController _deadRepsCtrl = _bound(BestEffortField.deadReps);

  final List<TextEditingController> _boundControllers = <TextEditingController>[];

  TextEditingController _bound(String key) {
    final c = TextEditingController(text: _form.bestEffortText[key] ?? '');
    c.addListener(() => _form.bestEffortText[key] = c.text);
    _boundControllers.add(c);
    return c;
  }

  int? get _minTrainingDays => _form.minTrainingDays; // 2–7, chosen on this page
  set _minTrainingDays(int? v) => _form.minTrainingDays = v;


  late bool _saving = widget.signup?.isSubmitting ?? false;

  bool get _muscleOrTonedChosen {
    // if “Build more muscle” OR “Get leaner” OR “Feel more toned” appears high, we can encourage body focus
    return _goals.contains('Build more muscle') || _goals.contains('Get leaner');
  }

  int? get _trainingEffort => _form.trainingEffort; // 1..4, optional
  set _trainingEffort(int? v) => _form.trainingEffort = v;
  List<String> _trainingEffortLabels = const []; // built from sex + dob

  /// Lists what is still missing, in the order the questions appear, paired
  /// with the section that owns it. Empty means valid.
  ///
  /// Previously the Finish button disabled itself whenever this was non-empty,
  /// so tapping it did nothing and the explanation inside `_finish()` was
  /// unreachable — the user got no feedback at all. Finish now stays tappable
  /// and reports the first missing item, scrolling to the section that owns it.
  ///
  /// There is deliberately no `_uiIsValid()` helper any more: the only thing it
  /// was ever used for was disabling the button, which is the bug above.
  ///
  /// The rules and the exact user-facing copy live in signup_validation.dart so
  /// they can be tested without a backend; this only reads them off state.
  List<({String section, String message})> _missingRequirements() =>
      missingOnboardingRequirements(
        hasGoal: _goals.isNotEmpty,
        muscleOrTonedChosen: _muscleOrTonedChosen,
        hasAnyBodyFocus: _bodyFocusLevel.values.any((lvl) => lvl > 0),
        everyInjuryRated: _injuries.every((i) => (_painSlider[i] ?? 0) >= 1),
        hasExperience: _experience != null,
        hasEnvironment: _env != null,
      );

  /// Scrolls the header of [section] into view. Silently does nothing when the
  /// section is not currently built (some are conditional), in which case the
  /// snack bar still names the problem.
  Future<void> _revealSection(String section) async {
    final ctx = _sectionKeys[section]?.currentContext;
    if (ctx == null) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      alignment: 0.1,
    );
  }

  @override
  void dispose() {
    // Only controllers that were actually created (they are lazy).
    for (final c in _boundControllers) {
      c.dispose();
    }

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
    if (_saving) return; // one submission at a time
    final missing = _missingRequirements();
    if (missing.isNotEmpty) {
      // Name the specific thing to fix rather than a generic form-level error,
      // say how many others remain so nothing is hidden, and scroll to it.
      final more = missing.length - 1;
      final detail = more > 0
          ? '${missing.first.message} (+$more more to finish)'
          : missing.first.message;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(detail),
            duration: const Duration(seconds: 4),
          ),
        );
      await _revealSection(missing.first.section);
      return;
    }

    final signup = _signup;
    if (signup != null) {
      await _finishSignup(signup);
    } else {
      await _finishEdit();
    }
  }

  /// Signup Finish. The coordinator creates/resumes the account, reserves the
  /// username through the server transaction and writes everything, verifying
  /// it on the server. This page only reports the outcome; on success AppRoot
  /// routes to the normal destination, so there is deliberately no navigation
  /// here (pushing '/home' on the unauthenticated navigator would mount it
  /// with no UserContext above it).
  Future<void> _finishSignup(SignupAttempt attempt) async {
    setState(() => _saving = true);
    final SignupResult result = await attempt.owner.submit(attempt);
    if (!mounted) return;

    if (result.isSuccess) {
      // Keep the spinner up until AppRoot swaps in the member's app.
      return;
    }

    setState(() => _saving = false);
    final failure = result.failure!;
    if (failure.returnsToPageOne) {
      // Page 1 puts the message on the field that owns it. Every answer on
      // this page stays in the attempt's draft for when the member returns.
      Navigator.of(context).pop(failure);
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(failure.message),
          duration: const Duration(seconds: 8),
          action: failure.retryable
              ? SnackBarAction(label: 'Retry', onPressed: _finish)
              : null,
        ),
      );
  }

  /// Save Changes for an established member (Templates / drawer). Creates no
  /// account and claims no username.
  Future<void> _finishEdit() async {
    setState(() => _saving = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || user.isAnonymous) {
        throw StateError('Training preferences need a signed-in account');
      }

      // Idempotent: if Stripe/webhook already created it, we don't overwrite.
      await ensureMembershipDoc(user.uid);

      // Write profile payload to users & users_public.
      //
      // Identity fields (username/usernameLower/fullName/sex/dob) are added
      // ONLY when this widget instance actually carries a value for them.
      // Edit mode passes null for whichever identity field it isn't letting
      // the user change — merge() only protects a field whose key is absent,
      // so writing an explicit null/'' here would silently wipe the user's
      // existing value. See onboarding_identity_payload.dart.
      //
      // createdAt is never re-stamped by an edit: merge() would otherwise
      // overwrite the user's true creation time on every "Save Changes".
      final payload = {
        'email': user.email,
        ...buildIdentityPayloadFields(
          username: widget.username,
          fullName: widget.fullName,
          sex: widget.sex,   // 'M'|'F'|'N'
          dob: widget.dob,   // dd-mm-yyyy string
        ),
        ...buildCreatedAtField(isNewAccount: false),
      };

      // Cache demographics locally for offline + fast access across the app.
      await DemographicsCache.save(
        uid: user.uid,
        sex: widget.sex,
        dob: widget.dob, // dd-mm-yyyy
      );

      final db = FirebaseFirestore.instance;
      await db.collection('users').doc(user.uid).set(payload, SetOptions(merge: true));
      await db.collection('users_public').doc(user.uid).set(payload, SetOptions(merge: true));

      final submission = OnboardingSubmission.fromForm(_form);
      await writeFitnessOnboarding(db, user.uid, submission);

      // An established member already has blocks, so this is a read.
      final fallbackName = (user.displayName?.trim().isNotEmpty == true)
          ? user.displayName!.trim()
          : (user.email?.split('@').first ?? '').trim();
      await FirstBlockSeeder(firestore: db)
          .ensureForEditMode(user.uid, authFallbackName: fallbackName);

      await writeBestEffortsToCurrentBlock(db, user.uid, submission.bestEfforts);

      if (!mounted) return;
      // In edit mode, recompute templateCandidateExerciseIds for the active block
      final entryFrom2 = (ModalRoute.of(context)?.settings.arguments as Map?)?['entryFrom']?.toString() ?? 'onboarding';
      final isEditMode2 = entryFrom2 == 'templates' || entryFrom2 == 'drawer';
      if (isEditMode2) {
        await _recomputeTemplateCandidatesForActiveBlock();
      }
      if (mounted) Navigator.pushReplacementNamed(context, '/home');
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

  /// Updates templateCandidateExerciseIds on the active block and current_block pointer.
  /// SCOPE: this pass updates only the active block and the current_block pointer.
  /// Upcoming/future blocks retain their creation-time templateCandidateExerciseIds.
  /// Do NOT extend this write to future blocks without a separate approved plan.
  Future<void> _recomputeTemplateCandidatesForActiveBlock() async {
    try {
      final actingUid = context.read<UserContext>().currentUid;
      final db = FirebaseFirestore.instance;

      // Read sex from user doc
      final userSnap = await db.collection('users').doc(actingUid).get();
      final sexRaw = (userSnap.data()?['sex'] as String?)?.trim().toUpperCase() ?? 'N';
      final isFemale = sexRaw == 'F' || sexRaw == 'N';
      final candidateIds = computeTemplateCandidateIds(isFemale: isFemale);

      // Read active block ID from current_block pointer
      final ptrSnap = await db.collection('users').doc(actingUid)
          .collection('block_planner').doc('current_block').get();
      final activeBlockId = ptrSnap.data()?['blockId'] as String?;

      // Update active block doc (additive — does NOT mutate exercises or plannedExercises)
      if (activeBlockId != null && activeBlockId.isNotEmpty) {
        await db.collection('users').doc(actingUid)
            .collection('planned_blocks').doc(activeBlockId)
            .set({'templateCandidateExerciseIds': candidateIds}, SetOptions(merge: true));
      }

      // Mirror to current_block pointer
      await db.collection('users').doc(actingUid)
          .collection('block_planner').doc('current_block')
          .set({'templateCandidateExerciseIds': candidateIds}, SetOptions(merge: true));

      debugPrint('✅ [Onboarding] recomputeTemplateCandidates → ${candidateIds.length} ids for $actingUid');
    } catch (e, st) {
      debugPrint('⚠️ [Onboarding] recomputeTemplateCandidatesForActiveBlock failed: $e\n$st');
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
      final loadedExperience        = OnboardingAnswers.experienceFromString(loadedExperienceStr);

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

    return PopScope(
      // Back (button, gesture, system/predictive) is blocked only while a
      // submission is in flight. The answers are in the draft either way.
      canPop: !_saving,
      child: Theme(
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
                      'Set your training priorities',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A237E),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Rank what matters most so GoodLift can build around it.',
                      style: TextStyle(
                        fontSize: 13.5,
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 16),

                    _SectionHeader(
                      "What do you care about most? (drag to rank)",
                      color: Colors.blueAccent,
                      key: _sectionKeys[OnboardingSection.goals],
                    ),
                    const SizedBox(height: 8),
                    _GoalsRanker(
                      items: _goals,
                      notImportant: _notImportantGoals,
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
                    _SectionHeader(
                      "Any existing niggles or injuries?",
                      color: Colors.blueAccent,
                      key: _sectionKeys[OnboardingSection.injuries],
                    ),
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
                    _SectionHeader(
                      "Weights Training experience",
                      color: Colors.blueAccent,
                      key: _sectionKeys[OnboardingSection.experience],
                    ),
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
                        key: _sectionKeys[OnboardingSection.bodyFocus],
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
                    _SectionHeader(
                      "What kind of training equipment do you have available?",
                      color: Colors.black,
                      key: _sectionKeys[OnboardingSection.env],
                    ),
                    const SizedBox(height: 8),

// Environment picker (compact chips)

                    Wrap(
                      spacing: 8, runSpacing: 8,
                      children: [
                        for (final entry in const [
                          ['Typical commercial gym', 'commercial'],
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
                    const SizedBox(height: 9),
                  //  _SectionHeader("OPTIONAL Bits:", color: Colors.black),

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


/*

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
                      selected: _form.benchVariant,
                      onVariantChanged: (v) => setState(() => _form.benchVariant = v),
                      weightCtrl: _benchWeightCtrl,
                      repsCtrl: _benchRepsCtrl,
                    ),
                    const SizedBox(height: 8),

// Squat / Leg Press
                    _BestEffortRow(
                      variants: const ['Back Squat', 'Leg Press'],
                      selected: _form.squatVariant,
                      onVariantChanged: (v) => setState(() => _form.squatVariant = v),
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
                      selected: _form.pullVariant,
                      onVariantChanged: (v) => setState(() => _form.pullVariant = v),
                      weightCtrl: _pullWeightCtrl,
                      repsCtrl: _pullRepsCtrl,
                    ),


                    const SizedBox(height: 8),

// Deadlift (single option still supported)
                    _BestEffortRow(
                      variants: const ['Deadlift'],
                      selected: _form.deadVariant,
                      onVariantChanged: (v) => setState(() => _form.deadVariant = v),
                      weightCtrl: _deadWeightCtrl,
                      repsCtrl: _deadRepsCtrl,
                    ),

*/

                    const SizedBox(height: 20),

                    // Back (smaller, same family, sits above Finish)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _saving ? null : () {
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
                            // Default behavior during onboarding. maybePop
                            // honours the PopScope below, so Back cannot
                            // leave while setup is being committed.
                            Navigator.maybePop(context);
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
                      child: OutlinedButton(
                        // Deliberately NOT gated on _uiIsValid(): a disabled
                        // button cannot tell the user what is missing. _finish()
                        // validates and reports the specific blocker.
                        onPressed: _saving ? null : _finish,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: const BorderSide(color: Colors.blueAccent),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          foregroundColor: Colors.blueAccent,
                        ),
                        child: _saving
                            ? const CircularProgressIndicator(color: Colors.blueAccent)
                            : Text(
                          isEditMode ? 'Save Changes' : 'Finish',
                          style: const TextStyle(
                            fontSize: 18,
                            color: Colors.blueAccent,
                          ),
                        ),
                      ),

                    ),
                    SizedBox(height: MediaQuery.of(context).padding.bottom + 28)
                  ],
                ),

              ),
            ),
          ),
        ),
      ),
    )
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

  /// The current "not important" bin. Passed in so a restored draft (or an
  /// edit-mode hydration) is shown and is not wiped by the next reorder.
  final List<String> notImportant;
  final void Function(List<String> main, List<String> notImportant) onChanged;

  // 👇 Add these two fields to the widget
  final String? sex;
  final String? dob;

  const _GoalsRanker({
    required this.items,
    this.notImportant = const <String>[],
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
    notImportantGoals = List.from(widget.notImportant);
  }

  @override
  void didUpdateWidget(covariant _GoalsRanker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Adopt order changes made outside this widget (draft restore, edit-mode
    // hydration) so a later drag never reverts them.
    if (!listEquals(widget.items, mainGoals)) {
      mainGoals = List.from(widget.items);
    }
    if (!listEquals(widget.notImportant, notImportantGoals)) {
      notImportantGoals = List.from(widget.notImportant);
    }
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
          child: ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            buildDefaultDragHandles: false,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex--;
                final item = mainGoals.removeAt(oldIndex);
                mainGoals.insert(newIndex, item);
                widget.onChanged(mainGoals, notImportantGoals);
              });
            },
            children: [
              for (int i = 0; i < mainGoals.length; i++)
                ReorderableDelayedDragStartListener(
                  key: ValueKey(mainGoals[i]),
                  index: i,
                  child: ListTile(
                    dense: true,
                    visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    tileColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: Colors.blueGrey.shade100),
                    ),
                    leading: const Icon(Icons.drag_handle, color: Colors.black45),
                    title: Text(
                      mainGoals[i],
                      style: const TextStyle(
                        fontSize: 15.5,
                        color: Colors.black87,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        /* ANTI-GOALS SECTION — commented out for now.
           To re-enable: uncomment this block and remove this comment wrapper.
           Future copy: "Drag here any goals you explicitly don't want to work on right now"
           State: notImportantGoals is preserved and always saved to 'goalsNotImportant' on finish.

        const SizedBox(height: 11),

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
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                  ),
                  const SizedBox(height: 6),
                  if (notImportantGoals.isEmpty)
                    const Text(
                      'Drag here any goals you explicitly don\'t want to work on right now',
                      style: TextStyle(color: Colors.black54, fontSize: 13),
                    ),
                  for (final item in notImportantGoals)
                    ListTile(
                      dense: true,
                      title: Text(item),
                      leading: const Icon(Icons.remove_circle_outline, color: Colors.grey),
                      onTap: () {
                        setState(() {
                          notImportantGoals.remove(item);
                          if (!mainGoals.contains(item)) mainGoals.add(item);
                          widget.onChanged(mainGoals, notImportantGoals);
                        });
                      },
                    ),
                ],
              ),
            );
          },
        ),
        */
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

