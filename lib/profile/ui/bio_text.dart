/// Renders a bio with tappable links.
///
/// Only `http` and `https` are ever linkified. A bio is user-supplied text
/// shown to other people, so anything else — `javascript:`, `file:`,
/// `intent:`, a bare `data:` blob — must stay inert plain text rather than
/// becoming something another user can tap.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'profile_theme.dart';

/// Matches bare URLs and www-prefixed hosts. Trailing punctuation is left out
/// of the link so "see https://goodlift.app." does not linkify the full stop.
final RegExp _linkPattern = RegExp(
  r'((?:https?://|www\.)[^\s<>"]+[^\s<>".,!?;:)\]}])',
  caseSensitive: false,
);

/// One run of bio text: either plain, or a link with the URL it resolves to.
class BioSpan {
  const BioSpan(this.text, {this.url});

  final String text;

  /// Null for plain text. Always an `http`/`https` URL when set.
  final String? url;

  bool get isLink => url != null;
}

/// Splits [bio] into plain and link runs.
///
/// Pure and exported so the link policy is unit-testable without building a
/// widget tree.
List<BioSpan> parseBio(String bio) {
  final List<BioSpan> spans = <BioSpan>[];
  int cursor = 0;

  for (final RegExpMatch match in _linkPattern.allMatches(bio)) {
    if (match.start > cursor) {
      spans.add(BioSpan(bio.substring(cursor, match.start)));
    }
    final String raw = match.group(0)!;
    final String? url = safeLinkUrl(raw);
    spans.add(url == null ? BioSpan(raw) : BioSpan(raw, url: url));
    cursor = match.end;
  }
  if (cursor < bio.length) spans.add(BioSpan(bio.substring(cursor)));
  return spans;
}

/// Returns a launchable URL for [raw], or null when it is not a safe web link.
///
/// A bare `www.` host is promoted to `https://` — never `http://` — so a link
/// we synthesise is not downgraded to plaintext transport.
String? safeLinkUrl(String raw) {
  final String candidate =
      raw.toLowerCase().startsWith('www.') ? 'https://$raw' : raw;
  final Uri? uri = Uri.tryParse(candidate);
  // A non-empty HOST is required, not merely an authority: `https:///` parses
  // with an authority and an empty host, and there is nothing there to open.
  if (uri == null || uri.host.isEmpty) return null;
  final String scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  return uri.toString();
}

class BioText extends StatefulWidget {
  const BioText(this.bio, {super.key, this.maxLines});

  final String bio;
  final int? maxLines;

  @override
  State<BioText> createState() => _BioTextState();
}

class _BioTextState extends State<BioText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final TapGestureRecognizer r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final TapGestureRecognizer r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final List<BioSpan> spans = parseBio(widget.bio);
    return Text.rich(
      TextSpan(
        children: spans.map((BioSpan s) {
          if (!s.isLink) {
            return TextSpan(text: s.text, style: ProfileText.bio(context));
          }
          final TapGestureRecognizer recognizer = TapGestureRecognizer()
            ..onTap = () => _open(s.url!);
          _recognizers.add(recognizer);
          return TextSpan(
            text: s.text,
            style: ProfileText.link(context),
            recognizer: recognizer,
          );
        }).toList(growable: false),
      ),
      maxLines: widget.maxLines,
      overflow:
          widget.maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
  }

  Future<void> _open(String url) async {
    final Uri uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open that link.")),
      );
    }
  }
}
