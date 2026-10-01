import 'package:flutter/material.dart';
import 'package:sign_in_button/sign_in_button.dart';

import '../theme/app_theme.dart';

/// Shared official Google sign-in button for sese_ride and sese_hub.
///
/// Built on the community-standard `sign_in_button` package (official brand
/// assets) with sese sizing so it matches the email/password fields:
/// full-width, 56 tall, large G logo.
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({
    super.key,
    required this.onPressed,
    this.text = 'Continue with Google',
  });

  /// Called on tap. Must be non-null — callers gate on their own
  /// submitting state because the package button takes a non-nullable
  /// callback.
  final VoidCallback onPressed;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: SignInButtonBuilder(
        // Soft grey fill (matches borderless text fields) so the pill reads
        // as a control without any stroked outline.
        backgroundColor: AppColors.lightFieldFill,
        text: text,
        textColor: const Color(0xFF1F1F1F),
        fontSize: 14,
        // Tighter than the package default (13px) so the larger logo +
        // text fit phones down to 320px wide.
        innerPadding: const EdgeInsets.symmetric(horizontal: 5),
        image: Container(
          margin: const EdgeInsets.fromLTRB(0, 0, 6, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: const Image(
              image: AssetImage(
                'assets/logos/google_light.png',
                package: 'sign_in_button',
              ),
              height: 32,
            ),
          ),
        ),
        // Borderless pill: soft grey fill instead of a stroked outline.
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide.none,
        ),
        // Inner content cap (package defaults to 220,
        // which overflows the larger logo + text).
        width: 320,
        onPressed: onPressed,
      ),
    );
  }
}
