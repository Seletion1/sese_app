import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Optional referral-code step for registration / Google sign-up onboarding.
///
/// Behaviour (spec):
/// - Blank / skipped input never blocks completion.
/// - Non-blank input is validated against `/referral_codes`.
/// - Valid codes resolve to a referrer uid via [onResolved]; the caller
///   stores `referredBy: referrerUserId` on the new profile document.
/// - Invalid codes show an inline error but still allow skipping.
class ReferralInputWidget extends StatefulWidget {
  final ReferralService referralService;
  final ValueChanged<String?> onResolved;
  final InputDecoration? decoration;

  const ReferralInputWidget({
    super.key,
    required this.referralService,
    required this.onResolved,
    this.decoration,
  });

  @override
  State<ReferralInputWidget> createState() => _ReferralInputWidgetState();
}

class _ReferralInputWidgetState extends State<ReferralInputWidget> {
  final _ctrl = TextEditingController();
  bool _checking = false;
  String? _error;
  String? _resolvedName;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _validate(String value) async {
    final code = normalizeReferralCode(value);
    if (code.isEmpty) {
      setState(() {
        _error = null;
        _resolvedName = null;
      });
      widget.onResolved(null);
      return;
    }
    if (!isPlausibleReferralCode(code)) {
      setState(() {
        _error = 'That code does not look valid — you can skip this step.';
        _resolvedName = null;
      });
      widget.onResolved(null);
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final referrerId = await widget.referralService.resolveReferrerId(code);
    if (!mounted) return;
    setState(() => _checking = false);
    if (referrerId == null) {
      setState(() {
        _error = 'Referral code not found — you can skip or try again.';
        _resolvedName = null;
      });
      widget.onResolved(null);
    } else {
      setState(() {
        _error = null;
        _resolvedName = 'Code applied ✓';
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
                    hintText: 'e.g. MB4321',
                    prefixIcon: Icon(Icons.card_giftcard_outlined),
                  ))
              .copyWith(
            suffixIcon: _checking
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child:
                          CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _resolvedName != null
                    ? const Icon(Icons.check_circle,
                        color: Colors.green)
                    : null,
          ),
          onChanged: _validate,
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(_error!,
              style: TextStyle(
                  color: Colors.orange.shade800, fontSize: 12)),
        ],
        if (_resolvedName != null) ...[
          const SizedBox(height: 4),
          Text(_resolvedName!,
              style: const TextStyle(
                  color: Colors.green, fontSize: 12)),
        ],
      ],
    );
  }
}
