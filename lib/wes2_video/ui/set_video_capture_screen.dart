/// Embedded set-video capture.
///
/// Recording happens INSIDE GoodLift rather than through a system camera
/// intent: an intent leaves the app, loses the workout context the user is
/// halfway through, and on Android returns a file whose container and location
/// vary by OEM. An embedded preview also lets the trimming instruction be shown
/// before the first rep, which is when it can still change what gets filmed.
///
/// ── Lifecycle ───────────────────────────────────────────────────────────────
/// A camera is a shared, pre-emptible resource. It is released whenever the app
/// leaves the foreground and rebuilt on return, because on both platforms the
/// controller is invalid after the OS hands the camera to something else — a
/// phone call, another app, a split-screen sibling. An in-progress recording is
/// stopped and offered to the trimmer rather than silently thrown away: the
/// user filmed something, and losing it because a notification arrived would be
/// worse than handing them a slightly short clip.
library;

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../set_video_copy.dart';
import '../set_video_pipeline.dart';

/// How a capture attempt ended.
enum CaptureOutcome { recorded, cancelled, denied, unavailable }

class CaptureResult {
  const CaptureResult(this.outcome, {this.capture, this.message});

  final CaptureOutcome outcome;
  final RawCapture? capture;
  final String? message;
}

/// How a camera authorisation failure should be presented.
///
/// The `camera` plugin already owns authorisation on both platforms: it
/// prompts, and reports the outcome as a [CameraException] whose code
/// distinguishes a fresh refusal from one the OS will not re-prompt for. A
/// second permissions package duplicates that, declares permissions this
/// feature does not need, and — in permission_handler's case — forced the whole
/// app onto a newer compileSdk and an extra iOS Podfile configuration step for
/// no behavioural gain.
enum CameraDenialKind {
  /// Refused this time. The OS will ask again on the next attempt.
  denied,

  /// Refused before; the OS will not prompt again. Settings is the only route.
  permanentlyDenied,

  /// Blocked by policy (parental controls). Settings will not help.
  restricted,

  /// Not an authorisation problem at all.
  other,
}

/// Classifies a [CameraException] raised while opening the camera.
///
/// Pure, so every branch is testable without a device. The codes are those the
/// camera plugin documents and both platform implementations raise.
CameraDenialKind classifyCameraError(Object error) {
  if (error is! CameraException) return CameraDenialKind.other;
  switch (error.code) {
    case 'CameraAccessDeniedWithoutPrompt':
    case 'AudioAccessDeniedWithoutPrompt':
      return CameraDenialKind.permanentlyDenied;
    case 'CameraAccessRestricted':
    case 'AudioAccessRestricted':
      return CameraDenialKind.restricted;
    case 'CameraAccessDenied':
    case 'AudioAccessDenied':
      return CameraDenialKind.denied;
    default:
      return CameraDenialKind.other;
  }
}

/// The message to show for a denial kind.
String messageForDenial(CameraDenialKind kind) {
  switch (kind) {
    case CameraDenialKind.permanentlyDenied:
      return SetVideoCopy.cameraPermanentlyDeniedBody;
    case CameraDenialKind.restricted:
      return SetVideoCopy.cameraRestrictedBody;
    case CameraDenialKind.denied:
      return SetVideoCopy.cameraDeniedBody;
    case CameraDenialKind.other:
      return SetVideoCopy.recordingUnavailable;
  }
}

/// Opens the OS settings page for this app, where that is possible.
///
/// iOS exposes a documented URL scheme. Android has no equivalent URL, and is
/// also the platform that re-prompts, so the pane there explains where to go
/// rather than offering a button that cannot work.
abstract class AppSettingsOpener {
  bool get isSupported;
  Future<bool> open();
}

class RuntimeAppSettingsOpener implements AppSettingsOpener {
  const RuntimeAppSettingsOpener();

  @override
  bool get isSupported => Platform.isIOS;

  @override
  Future<bool> open() async {
    if (!isSupported) return false;
    try {
      return await launchUrl(Uri.parse('app-settings:'));
    } catch (_) {
      return false;
    }
  }
}

class SetVideoCaptureScreen extends StatefulWidget {
  const SetVideoCaptureScreen({
    super.key,
    required this.tempDirectory,
    this.settingsOpener = const RuntimeAppSettingsOpener(),
    this.availableCamerasOverride,
  });

  /// Where the raw recording is written. Temporary by contract — the pipeline
  /// deletes it once the trimmed result is committed.
  final Directory tempDirectory;

  final AppSettingsOpener settingsOpener;

  /// Injected camera list, for tests.
  final Future<List<CameraDescription>> Function()? availableCamerasOverride;

  @override
  State<SetVideoCaptureScreen> createState() => _SetVideoCaptureScreenState();
}

class _SetVideoCaptureScreenState extends State<SetVideoCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const <CameraDescription>[];
  int _cameraIndex = 0;

  bool _initialising = true;
  bool _recording = false;
  bool _micGranted = true;
  String? _fatal;
  CameraDenialKind _denial = CameraDenialKind.other;
  DateTime? _startedAt;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    // Released explicitly: an orphaned controller keeps the camera locked for
    // every other app on the device.
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? c = _controller;
    if (c == null || !c.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // Stop first so the partial recording is preserved, then release.
      if (_recording) {
        unawaited(_stopAndReturn(interrupted: true));
      } else {
        _controller = null;
        unawaited(c.dispose());
        if (mounted) setState(() {});
      }
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      unawaited(_startController(_cameraIndex));
    }
  }

  Future<void> _bootstrap() async {
    // No pre-flight permission request: CameraController.initialize() prompts
    // and reports the outcome itself, so asking first would prompt twice.
    try {
      final List<CameraDescription> cams =
          await (widget.availableCamerasOverride ?? availableCameras)();
      if (!mounted) return;
      if (cams.isEmpty) {
        setState(() {
          _initialising = false;
          _fatal = SetVideoCopy.recordingUnavailable;
        });
        return;
      }
      _cameras = cams;
      // Prefer the rear camera: a lifter films the bar, not themselves.
      _cameraIndex =
          cams.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _startController(_cameraIndex);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initialising = false;
        _denial = classifyCameraError(e);
        _fatal = messageForDenial(_denial);
      });
    }
  }

  Future<void> _startController(int index, {bool withAudio = true}) async {
    if (index < 0 || index >= _cameras.length) return;
    final CameraController c = CameraController(
      _cameras[index],
      ResolutionPreset.high,
      enableAudio: withAudio,
    );
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _cameraIndex = index;
        _micGranted = withAudio;
        _initialising = false;
        _fatal = null;
        _denial = CameraDenialKind.other;
      });
    } catch (e) {
      await c.dispose();
      if (!mounted) return;

      // A MICROPHONE refusal must not cost the user the recording: retry once
      // without audio. A camera refusal is genuinely fatal to this screen.
      if (e is CameraException &&
          e.code.startsWith('AudioAccess') &&
          withAudio) {
        await _startController(index, withAudio: false);
        return;
      }

      setState(() {
        _initialising = false;
        _denial = classifyCameraError(e);
        _fatal = messageForDenial(_denial);
      });
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _recording) return;
    final CameraController? old = _controller;
    setState(() => _controller = null);
    await old?.dispose();
    await _startController((_cameraIndex + 1) % _cameras.length,
        withAudio: _micGranted);
  }

  Future<void> _startRecording() async {
    final CameraController? c = _controller;
    if (c == null || !c.value.isInitialized || _recording) return;
    try {
      await c.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _startedAt = DateTime.now();
        _elapsed = Duration.zero;
      });
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _startedAt == null) return;
        setState(() => _elapsed = DateTime.now().difference(_startedAt!));
      });
    } catch (_) {
      if (mounted) _toast(SetVideoCopy.recordingUnavailable);
    }
  }

  Future<void> _stopAndReturn({bool interrupted = false}) async {
    final CameraController? c = _controller;
    if (c == null || !_recording) return;
    _ticker?.cancel();
    _recording = false;

    try {
      final XFile file = await c.stopVideoRecording();
      final int ms = _startedAt == null
          ? 0
          : DateTime.now().difference(_startedAt!).inMilliseconds;

      // Move out of the plugin's own directory immediately: on iOS the path the
      // camera returns can be invalidated as soon as this screen closes.
      final File raw = await _adoptRaw(File(file.path));
      if (!mounted) return;
      Navigator.of(context).pop(CaptureResult(
        CaptureOutcome.recorded,
        capture: RawCapture(file: raw, durationMs: ms),
        message: interrupted ? SetVideoCopy.cameraInterrupted : null,
      ));
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pop(const CaptureResult(
        CaptureOutcome.unavailable,
        message: SetVideoCopy.recordingUnavailable,
      ));
    }
  }

  Future<File> _adoptRaw(File source) async {
    final Directory dir = widget.tempDirectory;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final String ext =
        source.path.contains('.') ? source.path.split('.').last : 'mp4';
    final File target = File(
      '${dir.path}${Platform.pathSeparator}'
      'capture_${DateTime.now().millisecondsSinceEpoch}.$ext',
    );
    return source.copy(target.path);
  }

  Future<void> _cancel() async {
    if (_recording) {
      final bool? discard = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text(SetVideoCopy.discardRecordingTitle),
          content: const Text(SetVideoCopy.discardRecordingBody),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text(SetVideoCopy.keepRecording),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text(SetVideoCopy.discard),
            ),
          ],
        ),
      );
      if (discard != true) return;
      _ticker?.cancel();
      _recording = false;
      try {
        final XFile f = await _controller!.stopVideoRecording();
        await File(f.path).delete();
      } catch (_) {
        // Nothing to clean up, or already gone.
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(const CaptureResult(CaptureOutcome.cancelled));
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String get _elapsedLabel {
    final int s = _elapsed.inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _fatal != null
            ? _PermissionPane(
                message: _fatal!,
                // Only offered where a settings deep link actually exists.
                onOpenSettings: widget.settingsOpener.isSupported &&
                        _denial != CameraDenialKind.restricted
                    ? () => widget.settingsOpener.open()
                    : null,
                onDismiss: () => Navigator.of(context)
                    .pop(const CaptureResult(CaptureOutcome.denied)),
              )
            : _initialising
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.white))
                : _cameraPane(),
      ),
    );
  }

  Widget _cameraPane() {
    final CameraController? c = _controller;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (c != null && c.value.isInitialized)
          Center(
            // Orientation is handled by letting the preview keep its own aspect
            // ratio inside the available space, rather than by locking the
            // screen: a lifter may well film in either orientation.
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio,
              child: CameraPreview(c),
            ),
          )
        else
          const ColoredBox(color: Colors.black),

        // The instruction that determines what actually gets filmed, shown
        // before the first rep rather than after.
        Positioned(
          top: 12,
          left: 16,
          right: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Banner(
                text: SetVideoCopy.recordGuidance,
                emphasis: true,
              ),
              const SizedBox(height: 8),
              _Banner(text: SetVideoCopy.privacyNotice),
              if (!_micGranted) ...<Widget>[
                const SizedBox(height: 8),
                _Banner(text: SetVideoCopy.microphoneDeniedBody),
              ],
            ],
          ),
        ),

        if (_recording)
          Positioned(
            top: 12,
            right: 16,
            child: Semantics(
              liveRegion: true,
              label: 'Recording, $_elapsedLabel',
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_elapsedLabel,
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ),
          ),

        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              TextButton(
                onPressed: _cancel,
                child: const Text(SetVideoCopy.cancelTrim,
                    style: TextStyle(color: Colors.white70)),
              ),
              Semantics(
                button: true,
                label: _recording ? 'Stop recording' : 'Start recording',
                child: GestureDetector(
                  onTap: _recording ? _stopAndReturn : _startRecording,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _recording ? Colors.red : Colors.white,
                      border: Border.all(color: Colors.white70, width: 3),
                    ),
                    child: Icon(
                      _recording ? Icons.stop : Icons.videocam,
                      color: _recording ? Colors.white : Colors.black,
                      size: 32,
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed:
                    _cameras.length > 1 && !_recording ? _switchCamera : null,
                tooltip: 'Switch camera',
                icon: const Icon(Icons.cameraswitch,
                    color: Colors.white70, size: 28),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.emphasis = false});

  final String text;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: emphasis ? 0.72 : 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white,
          fontSize: emphasis ? 14 : 12,
          fontWeight: emphasis ? FontWeight.w600 : FontWeight.normal,
          height: 1.3,
        ),
      ),
    );
  }
}

/// Shown when the camera is refused. Deliberately offers a way onward rather
/// than a dead end: logging a workout never depends on this permission.
class _PermissionPane extends StatelessWidget {
  const _PermissionPane({
    required this.message,
    required this.onOpenSettings,
    required this.onDismiss,
  });

  final String message;

  /// Null where the platform has no settings deep link (Android), which is
  /// also the platform that re-prompts anyway.
  final VoidCallback? onOpenSettings;

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.videocam_off, color: Colors.white54, size: 44),
            const SizedBox(height: 16),
            const Text(
              SetVideoCopy.cameraDeniedTitle,
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                TextButton(
                  onPressed: onDismiss,
                  child: const Text(SetVideoCopy.notNow,
                      style: TextStyle(color: Colors.white70)),
                ),
                if (onOpenSettings != null) ...<Widget>[
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: onOpenSettings,
                    child: const Text(SetVideoCopy.openSettings),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
