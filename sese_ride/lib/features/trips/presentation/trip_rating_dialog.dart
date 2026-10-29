import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../services/trip_rating_service.dart';

/// Interactive post-trip 1-to-5 star review dialog.
///
/// When the user selects 3 stars or fewer the dialog expands to show
/// [_lowRatingChips] — quick-tap reason chips plus an optional free-text
/// field. Both the selected chips and the comment are saved as part of the
/// rating document so the Ops team can action patterns without reading
/// raw free-text in bulk.
class TripRatingDialog extends StatefulWidget {
  final String tripId;
  final String raterId;
  final String ratedUserId;
  final String ratedUserName;
  final bool isRatedUserDriver;
  final TripRatingService ratingService;

  const TripRatingDialog({
    super.key,
    required this.tripId,
    required this.raterId,
    required this.ratedUserId,
    required this.ratedUserName,
    required this.isRatedUserDriver,
    required this.ratingService,
  });

  /// Displays the rating modal dialog.
  /// Returns `true` if submitted, `false` if skipped, or `null` if dismissed.
  static Future<bool?> show(
    BuildContext context, {
    required String tripId,
    required String raterId,
    required String ratedUserId,
    required String ratedUserName,
    required bool isRatedUserDriver,
    TripRatingService? ratingService,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => TripRatingDialog(
        tripId: tripId,
        raterId: raterId,
        ratedUserId: ratedUserId,
        ratedUserName: ratedUserName,
        isRatedUserDriver: isRatedUserDriver,
        ratingService: ratingService ?? TripRatingService(),
      ),
    );
  }

  @override
  State<TripRatingDialog> createState() => _TripRatingDialogState();
}

class _TripRatingDialogState extends State<TripRatingDialog> {
  int _selectedRating = 5;
  final Set<String> _selectedChips = {};
  late final TextEditingController _commentCtrl;
  bool _submitting = false;

  static const _starLabels = [
    'Poor',
    'Fair',
    'Good',
    'Very Good',
    'Excellent!',
  ];

  /// Reason chips shown when the user rates 3 stars or below.
  /// Driver-side chips differ slightly from customer-side chips to capture
  /// the right operational signal.
  static const _driverLowRatingChips = [
    'Late arrival',
    'Unprofessional behaviour',
    'Poor vehicle condition',
    'Wrong route taken',
    'Reckless driving',
    'Overcharged / fee dispute',
    'No-show / very late',
    'Safety concern',
  ];

  static const _customerLowRatingChips = [
    'Unprofessional behaviour',
    'Damage to package',
    'Wrong item delivered',
    'Late arrival',
    'Safety concern',
    'Poor communication',
    'Route issue',
    'Other issue',
  ];

  /// Whether the low-rating feedback section should be visible.
  bool get _showLowRatingSection => _selectedRating <= 3;

  @override
  void initState() {
    super.initState();
    _commentCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  String _firstName(String fullName) {
    final trimmed = fullName.trim();
    if (trimmed.isEmpty) return 'User';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);

    // Build combined comment: chips first, then free-text appended.
    final chipSummary = _selectedChips.isNotEmpty
        ? _selectedChips.join(', ')
        : null;
    final freeText = _commentCtrl.text.trim();
    final combined = [
      chipSummary,
      if (freeText.isNotEmpty) freeText,
    ].nonNulls.join(' — ');

    try {
      await widget.ratingService.submitRating(
        tripId: widget.tripId,
        raterId: widget.raterId,
        ratedUserId: widget.ratedUserId,
        rating: _selectedRating,
        comment: combined,
        isRatedUserDriver: widget.isRatedUserDriver,
        lowRatingReasons: _selectedChips.toList(),
      );
      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Thank you for your feedback!')),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not submit rating. Please try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _firstName(widget.ratedUserName);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chips = widget.isRatedUserDriver
        ? _driverLowRatingChips
        : _customerLowRatingChips;

    return AlertDialog(
      key: const Key('trip_rating_dialog'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      title: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.seseGold.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.star_rounded,
              color: Color(0xFFD97706),
              size: 32,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Rate your trip with $name',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'How was your experience? Your feedback helps us keep SESE safe and reliable.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),

            // ── Star selector ──────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (index) {
                final starValue = index + 1;
                final isSelected = starValue <= _selectedRating;
                return GestureDetector(
                  key: Key('rating_star_$starValue'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _submitting
                      ? null
                      : () => setState(() {
                            _selectedRating = starValue;
                            // Clear chips when user raises rating above 3.
                            if (!_showLowRatingSection) {
                              _selectedChips.clear();
                            }
                          }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      isSelected
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: isSelected
                          ? const Color(0xFFF59E0B)
                          : Colors.grey.shade400,
                      size: 38,
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                _starLabels[_selectedRating - 1],
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: _selectedRating <= 3
                      ? Colors.red.shade600
                      : const Color(0xFFD97706),
                ),
              ),
            ),

            // ── Low-rating feedback section (≤ 3 stars) ───────────────────
            if (_showLowRatingSection) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF2A1515)
                      : Colors.red.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark
                        ? Colors.red.shade900.withValues(alpha: 0.4)
                        : Colors.red.shade100,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline_rounded,
                            size: 16,
                            color: isDark
                                ? Colors.red.shade300
                                : Colors.red.shade700),
                        const SizedBox(width: 6),
                        Text(
                          'Please tell us what happened',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? Colors.red.shade300
                                : Colors.red.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Quick-tap reason chips.
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: chips.map((chip) {
                        final active = _selectedChips.contains(chip);
                        return GestureDetector(
                          onTap: _submitting
                              ? null
                              : () => setState(() {
                                    if (active) {
                                      _selectedChips.remove(chip);
                                    } else {
                                      _selectedChips.add(chip);
                                    }
                                  }),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: active
                                  ? Colors.red.shade600
                                  : (isDark
                                      ? const Color(0xFF3A1010)
                                      : Colors.white),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: active
                                    ? Colors.red.shade600
                                    : (isDark
                                        ? Colors.red.shade900
                                            .withValues(alpha: 0.5)
                                        : Colors.red.shade200),
                              ),
                            ),
                            child: Text(
                              chip,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: active
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: active
                                    ? Colors.white
                                    : (isDark
                                        ? Colors.red.shade300
                                        : Colors.red.shade700),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),

            // ── Optional free-text comment ─────────────────────────────────
            TextField(
              key: const Key('rating_comment_field'),
              controller: _commentCtrl,
              enabled: !_submitting,
              maxLines: 2,
              maxLength: 200,
              decoration: InputDecoration(
                hintText: _showLowRatingSection
                    ? 'Add any extra details (optional)...'
                    : 'Add an optional comment...',
                hintStyle: TextStyle(
                  fontSize: 12,
                  color:
                      isDark ? Colors.grey.shade400 : Colors.grey.shade500,
                ),
                filled: true,
                fillColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        Row(
          children: [
            Expanded(
              child: TextButton(
                key: const Key('rating_skip_button'),
                onPressed:
                    _submitting ? null : () => Navigator.of(context).pop(false),
                child: const Text(
                  'Skip',
                  style: TextStyle(
                      color: Colors.grey, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                key: const Key('rating_submit_button'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.seseGold,
                  foregroundColor: Colors.black87,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black87,
                        ),
                      )
                    : const Text(
                        'Submit',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
