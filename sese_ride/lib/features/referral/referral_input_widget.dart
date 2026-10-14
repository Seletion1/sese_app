import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Optional referral-code step for registration / Google sign-up onboarding.
///
/// Behaviour (spec):
/// - Blank / skipped input never blocks completion.
/// - Non-blank input is validated against `/referral_codes` with a 400ms debouncer.
/// - Valid codes resolve to a referrer uid and display: "Referred by [Name]".
/// - Invalid codes show: "Invalid referral code. You can clear this field to proceed."
/// - Optional Skip/Continue action button for immediate registration.
class ReferralInputWidget extends StatefulWidget {
  final ReferralService referralService;
  final ValueChanged<String?> onResolved;
  final VoidCallback? onSkip;
  final InputDecoration? decoration;

  const ReferralInputWidget({
    super.key,
    required this.referralService,
    required this.onResolved,
    this.onSkip,
    this.decoration,
  });

  @override
  State<ReferralInputWidget> createState() => _ReferralInputWidgetState();
}

class _ReferralInputWidgetState extends State<ReferralInputWidget> {
  final _ctrl = TextEditingController();
  Timer? _debounceTimer;
  bool _checking = false;
  String? _error;
  String? _referrerBadge;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 400), () {
      _validate(value);
    });
  }

  Future<void> _validate(String value) async {
    final code = normalizeReferralCode(value);
    if (code.isEmpty) {
      setState(() {
        _checking = false;
        _error = null;
        _referrerBadge = null;
      });
      widget.onResolved(null);
      return;
    }
    if (!isPlausibleReferralCode(code)) {
      setState(() {
        _checking = false;
        _error = 'Invalid referral code. You can clear this field to proceed.';
        _referrerBadge = null;
      });
      widget.onResolved(null);
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final details = await widget.referralService.resolveReferrerDetails(code);
    if (!mounted) return;
    setState(() => _checking = false);

    if (details == null) {
      setState(() {
        _error = 'Invalid referral code. You can clear this field to proceed.';
        _referrerBadge = null;
      });
      widget.onResolved(null);
    } else {
      final referrerId = details['referrerId'];
      final firstName = details['firstName'] ?? 'User';
      setState(() {
        _error = null;
        _referrerBadge = 'Referred by $firstName';
      });
      widget.onResolved(referrerId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const Key('referral_code_field'),
          controller: _ctrl,
          textCapitalization: TextCapitalization.characters,
          decoration: (widget.decoration ??
                  const InputDecoration(
                    labelText: 'Referral Code (Optional)',
                    hintText: 'e.g. MB6789',
                    prefixIcon: Icon(Icons.card_giftcard_outlined),
                  ))
              .copyWith(
            suffixIcon: _checking
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _referrerBadge != null
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : null,
          ),
          onChanged: _onTextChanged,
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(
            _error!,
            style: TextStyle(color: Colors.orange.shade800, fontSize: 12),
          ),
        ],
        if (_referrerBadge != null) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.green.shade300),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle, size: 14, color: Colors.green),
                const SizedBox(width: 6),
                Text(
                  _referrerBadge!,
                  style: TextStyle(
                    color: Colors.green.shade900,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (widget.onSkip != null) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: widget.onSkip,
              child: const Text('Skip / Continue without code'),
            ),
          ),
        ],
      ],
    );
  }
}
