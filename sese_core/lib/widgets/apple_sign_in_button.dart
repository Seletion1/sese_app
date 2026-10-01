import 'package:flutter/material.dart';
import 'package:sign_in_button/sign_in_button.dart';

/// Shared official Apple sign-in button for sese_ride and sese_hub.
class AppleSignInButton extends StatelessWidget {
  const AppleSignInButton({
    super.key,
    required this.onPressed,
    this.text = 'Continue with Apple',
  });

  final VoidCallback onPressed;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: SignInButton(
        Buttons.appleDark,
        text: text,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
        onPressed: onPressed,
      ),
    );
  }
}
