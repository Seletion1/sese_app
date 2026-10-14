import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../legal/legal_document_content.dart';
import 'legal_document_viewer.dart';

/// Interactive Legal Auth Disclaimer widget matching the SESE registration/login design.
///
/// Renders: "By continuing, you agree to our Terms of Use and Privacy Policy."
/// with clickable, underlined links to Terms of Use and Privacy Policy.
class LegalAuthDisclaimer extends StatefulWidget {
  final TextAlign textAlign;

  const LegalAuthDisclaimer({
    super.key,
    this.textAlign = TextAlign.center,
  });

  @override
  State<LegalAuthDisclaimer> createState() => _LegalAuthDisclaimerState();
}

class _LegalAuthDisclaimerState extends State<LegalAuthDisclaimer> {
  late final TapGestureRecognizer _termsRecognizer;
  late final TapGestureRecognizer _privacyRecognizer;

  @override
  void initState() {
    super.initState();
    _termsRecognizer = TapGestureRecognizer()
      ..onTap = () => LegalDocumentViewer.show(context, LegalDocType.terms);
    _privacyRecognizer = TapGestureRecognizer()
      ..onTap = () => LegalDocumentViewer.show(context, LegalDocType.privacy);
  }

  @override
  void dispose() {
    _termsRecognizer.dispose();
    _privacyRecognizer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final linkColor = theme.primaryColor;
    final baseColor = theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7) ??
        const Color(0xFF5F6368);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Text.rich(
        TextSpan(
          text: 'By continuing, you agree to our ',
          style: TextStyle(
            fontSize: 13,
            color: baseColor,
            fontWeight: FontWeight.normal,
          ),
          children: [
            TextSpan(
              text: 'Terms of Use',
              style: TextStyle(
                fontSize: 13,
                color: linkColor,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
                decorationColor: linkColor,
              ),
              recognizer: _termsRecognizer,
            ),
            const TextSpan(text: ' and '),
            TextSpan(
              text: 'Privacy Policy',
              style: TextStyle(
                fontSize: 13,
                color: linkColor,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
                decorationColor: linkColor,
              ),
              recognizer: _privacyRecognizer,
            ),
            const TextSpan(text: '.'),
          ],
        ),
        textAlign: widget.textAlign,
      ),
    );
  }
}
