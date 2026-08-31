/// Every user-facing string in the set-video flow, in one place.
///
/// Kept out of the widgets so the wording can be asserted directly. The two
/// trimming prompts are the whole point of the feature economically: an
/// untrimmed set is mostly setup footage, and setup footage is what fills a
/// user's device and, for a personal best, the project's storage bill.
library;

class SetVideoCopy {
  /// Shown on the capture screen, before recording starts.
  static const String recordGuidance =
      'Record the working set, then trim from the start of rep 1 to the '
      're-rack or end of the final rep.';

  /// Shown prominently on the trim screen.
  static const String trimGuidance =
      'Trim tightly: first rep → re-rack/end of last rep. '
      'Only the trimmed clip is saved.';

  /// The privacy promise, shown in both the capture and trim flows.
  ///
  /// Stated up front rather than buried: automatic publication is a real
  /// surprise if the user has not been told, and "stays on this device" is the
  /// true default for all but a handful of sets.
  static const String privacyNotice =
      'Set videos stay on this device. If this set becomes a qualifying '
      'personal best, the trimmed clip will be added to your profile.';

  // ── Permissions ───────────────────────────────────────────────────────────

  static const String cameraDeniedTitle = 'Camera access needed';

  static const String cameraDeniedBody =
      'GoodLift needs the camera to record a set. You can keep logging your '
      'workout without it.';

  static const String cameraPermanentlyDeniedBody =
      'Camera access is turned off for GoodLift. You can turn it back on in '
      'Settings. Logging your workout works without it.';

  static const String microphoneDeniedBody =
      'Without microphone access the set will record without sound.';

  static const String openSettings = 'Open Settings';

  static const String notNow = 'Not now';

  // ── Capture ───────────────────────────────────────────────────────────────

  static const String recordingUnavailable =
      'Recording is not available on this device right now.';

  static const String cameraInterrupted =
      'Recording stopped because the camera was interrupted.';

  static const String discardRecordingTitle = 'Discard this recording?';

  static const String discardRecordingBody = 'The footage will not be saved.';

  static const String discard = 'Discard';

  static const String keepRecording = 'Keep recording';

  // ── Trim ──────────────────────────────────────────────────────────────────

  static const String trimTitle = 'Trim your set';

  static const String saveTrimmed = 'Save';

  static const String cancelTrim = 'Cancel';

  static const String trimFailed =
      'That clip could not be trimmed. The recording has not been saved.';

  static const String trimTooShort = 'Trim to at least one second.';

  /// Shown while the native trim runs.
  static const String trimming = 'Trimming…';

  // ── Attached state ────────────────────────────────────────────────────────

  static const String viewVideo = 'View video';
  static const String replaceVideo = 'Replace video';
  static const String deleteVideo = 'Delete video';

  static const String deleteVideoTitle = 'Delete this set video?';

  /// Names what is removed. A destructive action must say what it destroys.
  static const String deleteVideoBody =
      'The video will be removed from this device. If it is currently shown '
      'on your profile as proof of a personal best, it will be removed from '
      'there too.';

  /// Detachment is NOT deletion, and must not be worded as if it were.
  static const String detachTitle = 'Remove from this achievement?';

  static const String detachBody =
      'The video stays in your profile gallery. It will no longer be shown as '
      'proof for this lift.';

  static const String detach = 'Remove from achievement';

  static const String videoDeleted = 'Set video deleted';
  static const String videoSaved = 'Set video saved';
  static const String undo = 'Undo';

  // ── Set-row control ───────────────────────────────────────────────────────

  static const String recordSetTooltip = 'Record this set';
  static const String recordedSetTooltip = 'Set video recorded';

  /// Screen-reader label for the control when nothing is attached.
  static String recordSemanticLabel(int setNumber) =>
      'Record a video of set $setNumber';

  /// Screen-reader label once footage is attached, so the state is announced
  /// rather than left to the icon alone.
  static String recordedSemanticLabel(int setNumber) =>
      'Set $setNumber has a video. View, replace or delete it';
}
