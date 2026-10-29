import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../services/trip_rating_service.dart';

/// One selectable cancellation reason: stable wire [code] (audited
/// server-side) + human [label] shown in the dialog.
class CancelReason {
  final String code;
  final String label;

  const CancelReason(this.code, this.label);
}

/// Result returned when user completes cancellation dialog choices.
class CancelTripResult {
  final String reason;
  final bool useCashSettlement;

  const CancelTripResult({
    required this.reason,
    this.useCashSettlement = false,
  });
}

/// Secure trip-cancellation confirmation.
///
/// Cancelling never dismisses instantly: the caller must present this dialog,
/// the user must pick one reason and tap Confirm, and only then is the
/// `cancelTrip` callable invoked with the selected code. Dismissing (back,
/// tap-outside, Cancel button) returns null and commits nothing.
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

  /// Shows the dialog. Returns the selected reason code or result, or null when the
  /// user backs out (nothing is cancelled in that case).
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

  // ── Post-cancellation feedback ─────────────────────────────────────────────

  /// Politely prompts the user for additional feedback AFTER cancellation has
  /// already been committed on the server. This is non-blocking — tapping
  /// "Skip" returns immediately without recording anything.
  ///
  /// [tripId] and [userId] are used to key the `cancellation_feedback` doc.
  /// [role] should be `'customer'` or `'driver'`.
  static Future<void> showPostCancelFeedback(
    BuildContext context, {
    required String tripId,
    required String userId,
    required String role,
    required bool isDriver,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PostCancelFeedbackSheet(
        tripId: tripId,
        userId: userId,
        role: role,
        isDriver: isDriver,
      ),
    );
  }
}

// ── Pre-cancellation confirmation dialog ──────────────────────────────────────

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
                            ? 'Cancelling during paid waiting incurs ₦${widget.paidWaitingFee.toStringAsFixed(0)}. '
                              'As a 5+ trip customer, any wallet shortage will carry as an outstanding balance on your next booking.'
                            : 'Cancelling during paid waiting incurs ₦${widget.paidWaitingFee.toStringAsFixed(0)}. '
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
                  title: const Text('Pay via Cash Settlement with Driver',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold)),
                  subtitle: const Text(
                      'Pay cash directly to driver upon cancelling',
                      style: TextStyle(fontSize: 11)),
                  value: _useCashSettlement,
                  onChanged: (val) =>
                      setState(() => _useCashSettlement = val ?? false),
                ),
                const SizedBox(height: 8),
              ],
            ],
            const Text(
              'Tell us why — it helps us track reliability and keep the '
              'marketplace fair. This cancellation is logged.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: RadioGroup<String>(
                  groupValue: _selected,
                  onChanged: (v) => setState(() => _selected = v),
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
                    ),
                  ),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

// ── Post-cancellation feedback bottom sheet ───────────────────────────────────

/// Shown after a cancellation is confirmed on the server.
///
/// The user may select additional reason chips and add a free-text detail.
/// All of this is saved to `cancellation_feedback/{tripId}_{userId}`.
/// The sheet is entirely optional — tapping "Skip" stores nothing.
class _PostCancelFeedbackSheet extends StatefulWidget {
  final String tripId;
  final String userId;
  final String role;
  final bool isDriver;

  const _PostCancelFeedbackSheet({
    required this.tripId,
    required this.userId,
    required this.role,
    required this.isDriver,
  });

  @override
  State<_PostCancelFeedbackSheet> createState() =>
      _PostCancelFeedbackSheetState();
}

class _PostCancelFeedbackSheetState extends State<_PostCancelFeedbackSheet> {
  String? _selectedReason;
  final TextEditingController _detailCtrl = TextEditingController();
  bool _submitting = false;

  /// Reason chips for the post-cancellation sheet — broader than the
  /// pre-cancel radio list so we capture richer signals.
  static const _customerChips = [
    'Driver took too long',
    'Change of plans',
    'Emergency',
    'Wrong address entered',
    'Found another ride',
    'Price too high',
    'Driver unresponsive',
    'Other',
  ];

  static const _driverChips = [
    'Customer not at location',
    'Route was unsafe',
    'Vehicle breakdown',
    'Emergency',
    'Customer unresponsive',
    'Fare too low',
    'Wrong item / trip type',
    'Other',
  ];

  @override
  void dispose() {
    _detailCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || _selectedReason == null) return;
    setState(() => _submitting = true);
    await TripRatingService().submitCancellationFeedback(
      tripId: widget.tripId,
      userId: widget.userId,
      role: widget.role,
      reason: _selectedReason!,
      detail: _detailCtrl.text,
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor =
        isDark ? const Color(0xFF1E1E28) : Colors.white;
    final labelColor =
        isDark ? Colors.grey.shade300 : Colors.grey.shade700;
    final chips =
        widget.isDriver ? _driverChips : _customerChips;

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF3A3A46)
                      : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.cancel_outlined,
                      size: 20, color: Colors.orange),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Trip cancelled',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      Text(
                        'Please tell us what happened',
                        style: TextStyle(
                            fontSize: 12, color: labelColor),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Reason chips
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: chips.map((chip) {
                final active = _selectedReason == chip;
                return GestureDetector(
                  onTap: _submitting
                      ? null
                      : () => setState(() => _selectedReason = chip),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: active
                          ? AppColors.seseGold
                          : (isDark
                              ? const Color(0xFF252530)
                              : Colors.grey.shade100),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: active
                            ? AppColors.seseGold
                            : (isDark
                                ? const Color(0xFF3A3A46)
                                : Colors.grey.shade300),
                      ),
                    ),
                    child: Text(
                      chip,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            active ? FontWeight.bold : FontWeight.normal,
                        color: active
                            ? Colors.black
                            : (isDark
                                ? Colors.grey.shade300
                                : Colors.grey.shade800),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // Optional detail field
            TextField(
              controller: _detailCtrl,
              enabled: !_submitting,
              maxLines: 2,
              maxLength: 200,
              decoration: InputDecoration(
                hintText: 'Add extra details (optional)...',
                hintStyle: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? Colors.grey.shade500
                        : Colors.grey.shade400),
                filled: true,
                fillColor: isDark
                    ? const Color(0xFF252530)
                    : Colors.grey.shade50,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      BorderSide(color: Colors.grey.shade300),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Action row
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide(color: Colors.grey.shade400),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Skip'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.seseGold,
                      foregroundColor: Colors.black,
                      padding:
                          const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: (_selectedReason == null || _submitting)
                        ? null
                        : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Text(
                            'Send Feedback',
                            style: TextStyle(
                                fontWeight: FontWeight.bold),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
