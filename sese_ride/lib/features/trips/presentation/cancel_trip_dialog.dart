import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// One selectable cancellation reason: stable wire [code] (audited
/// server-side) + human [label] shown in the dialog.
class CancelReason {
  final String code;
  final String label;

  const CancelReason(this.code, this.label);
}

/// Result returned when the user confirms the cancellation dialog.
///
/// [reason] is the stable backend audit code.
/// [useCashSettlement] is set when the customer elects to pay a waiting fee
/// in cash directly to the driver rather than from their wallet.
/// [customDetail] is non-empty only when reason == `'other'` and the user
/// typed additional context in the optional "Other reason" text field.
class CancelTripResult {
  final String reason;
  final bool useCashSettlement;
  final String customDetail;

  const CancelTripResult({
    required this.reason,
    this.useCashSettlement = false,
    this.customDetail = '',
  });
}

/// Secure trip-cancellation confirmation.
///
/// Cancelling never dismisses instantly: the caller must present this dialog,
/// the user must pick one reason and tap Confirm, and only then is the
/// `cancelTrip` callable invoked with the selected code. Dismissing (back,
/// tap-outside, Keep trip button) returns null and commits nothing.
///
/// When the user picks **"Other reason"** an optional free-text field expands
/// inline so they can supply extra context before confirming — no secondary
/// screen is shown after cancellation.
///
/// Reason codes are the audit vocabulary — the backend allow-lists them and
/// persists every cancellation to the immutable `cancellation_audits`
/// collection (timestamp, user id, role, reason, trip id) for abuse tracking
/// and spam-cancel rate-limiting. Keep codes stable; labels may be reworded.
abstract final class CancelTripDialog {
  /// Customer-side reasons (booking party).
  static const List<CancelReason> customerReasons = [
    CancelReason('driver_taking_too_long', 'Driver is taking too long'),
    CancelReason('changed_my_mind', 'I changed my mind'),
    CancelReason('wrong_pickup', 'Wrong pickup location'),
    CancelReason('wrong_dropoff', 'Wrong destination'),
    CancelReason('fare_too_high', 'Fare is too high'),
    CancelReason('booked_by_mistake', 'Booked by mistake'),
    CancelReason('driver_asked_to_cancel', 'Driver asked me to cancel'),
    CancelReason('other', 'Other reason'),
  ];

  /// Driver-side reasons (assigned party).
  static const List<CancelReason> driverReasons = [
    CancelReason('customer_no_show', 'Customer is a no-show'),
    CancelReason('customer_asked_to_cancel', 'Customer asked me to cancel'),
    CancelReason('pickup_too_far', 'Pickup is too far away'),
    CancelReason('vehicle_issue', 'Vehicle issue'),
    CancelReason('emergency', 'Emergency'),
    CancelReason('wrong_trip_match', 'Wrong trip match for my vehicle'),
    CancelReason('fare_too_low', 'Fare is too low'),
    CancelReason('other', 'Other reason'),
  ];

  /// Shows the cancellation dialog.
  ///
  /// Returns [CancelTripResult] when the user confirms, or `null` when they
  /// dismiss or tap "Keep trip" (nothing is cancelled in that case).
  static Future<CancelTripResult?> show(
    BuildContext context, {
    required bool isDriver,
    double paidWaitingFee = 0.0,
    bool isTrustedCustomer = false,
  }) {
    final reasons = isDriver ? driverReasons : customerReasons;
    return showDialog<CancelTripResult>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _CancelTripDialogBody(
        reasons: reasons,
        paidWaitingFee: paidWaitingFee,
        isTrustedCustomer: isTrustedCustomer,
      ),
    );
  }
}

// ── Cancellation confirmation dialog ──────────────────────────────────────────

class _CancelTripDialogBody extends StatefulWidget {
  final List<CancelReason> reasons;
  final double paidWaitingFee;
  final bool isTrustedCustomer;

  const _CancelTripDialogBody({
    required this.reasons,
    this.paidWaitingFee = 0.0,
    this.isTrustedCustomer = false,
  });

  @override
  State<_CancelTripDialogBody> createState() => _CancelTripDialogBodyState();
}

class _CancelTripDialogBodyState extends State<_CancelTripDialogBody> {
  String? _selected;
  bool _useCashSettlement = false;

  /// Controller for the optional "Other reason" detail field.
  /// Only visible (and submitted) when the user picks the `'other'` code.
  final TextEditingController _otherCtrl = TextEditingController();

  @override
  void dispose() {
    _otherCtrl.dispose();
    super.dispose();
  }

  /// Whether the currently selected reason is "other" — triggers the inline
  /// detail field to expand.
  bool get _isOther => _selected == 'other';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('cancel_trip_dialog'),
      title: const Text('Cancel this trip?'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Waiting fee warning (shown only when fee > 0) ──────────────
            if (widget.paidWaitingFee > 0) ...[
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade300),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Color(0xFFD97706), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.isTrustedCustomer
                            ? 'Cancelling during paid waiting incurs '
                                '₦${widget.paidWaitingFee.toStringAsFixed(0)}. '
                                'As a 5+ trip customer, any wallet shortage will '
                                'carry as an outstanding balance on your next booking.'
                            : 'Cancelling during paid waiting incurs '
                                '₦${widget.paidWaitingFee.toStringAsFixed(0)}. '
                                'Check Cash Settlement below if your wallet balance is low.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF92400E),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!widget.isTrustedCustomer) ...[
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    'Pay via Cash Settlement with Driver',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'Pay cash directly to driver upon cancelling',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: _useCashSettlement,
                  onChanged: (val) =>
                      setState(() => _useCashSettlement = val ?? false),
                ),
                const SizedBox(height: 8),
              ],
            ],

            // ── Helper subtitle ────────────────────────────────────────────
            const Text(
              'Tell us why — it helps us track reliability and keep the '
              'marketplace fair. This cancellation is logged.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),

            // ── Reason radio list ──────────────────────────────────────────
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RadioGroup<String>(
                      groupValue: _selected,
                      onChanged: (v) => setState(() {
                        _selected = v;
                        // Clear any typed detail when switching away from other.
                        if (v != 'other') _otherCtrl.clear();
                      }),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final r in widget.reasons)
                            RadioListTile<String>(
                              key: Key('cancel_reason_${r.code}'),
                              value: r.code,
                              title: Text(
                                r.label,
                                style: const TextStyle(fontSize: 13),
                              ),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                        ],
                      ),
                    ),

                    // ── "Other reason" inline detail field ─────────────────
                    // Expands with a smooth AnimatedSwitcher the moment the
                    // user selects "Other reason". No second screen, no
                    // separate step — everything stays in this single dialog.
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, animation) =>
                          SizeTransition(
                              sizeFactor: animation, child: child),
                      child: _isOther
                          ? Padding(
                              key: const ValueKey('other_field'),
                              padding: const EdgeInsets.only(top: 8),
                              child: TextField(
                                controller: _otherCtrl,
                                autofocus: true,
                                maxLines: 2,
                                maxLength: 200,
                                style: const TextStyle(fontSize: 13),
                                decoration: InputDecoration(
                                  hintText:
                                      'Briefly describe your reason (optional)…',
                                  hintStyle: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade400,
                                  ),
                                  filled: true,
                                  fillColor: Colors.grey.shade50,
                                  contentPadding:
                                      const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 10),
                                  border: OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                        color: Colors.grey.shade300),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                        color: Colors.grey.shade300),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                        color:
                                            AppColors.seseGold),
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('other_field_hidden')),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep trip'),
        ),
        FilledButton(
          key: const Key('cancel_trip_confirm_button'),
          onPressed: _selected == null
              ? null
              : () => Navigator.of(context).pop(
                    CancelTripResult(
                      reason: _selected!,
                      useCashSettlement: _useCashSettlement,
                      customDetail:
                          _isOther ? _otherCtrl.text.trim() : '',
                    ),
                  ),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
