import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../services/trip_rating_service.dart';

/// Interactive post-trip 1-to-5 star review popup modal.
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

  /// Displays the rating modal dialog. Returns `true` if submitted, `false` if skipped, or `null` if dismissed.
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
  late final TextEditingController _commentCtrl;
  bool _submitting = false;

  static const _starLabels = [
    'Poor',
    'Fair',
    'Good',
    'Very Good',
    'Excellent!',
  ];

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

    try {
      await widget.ratingService.submitRating(
        tripId: widget.tripId,
        raterId: widget.raterId,
        ratedUserId: widget.ratedUserId,
        rating: _selectedRating,
        comment: _commentCtrl.text,
        isRatedUserDriver: widget.isRatedUserDriver,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Thank you for your rating!')),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not submit rating. Please try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _firstName(widget.ratedUserName);
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'How was your experience? Your feedback helps us keep SESE safe and reliable.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 16),

          // Interactive 5 Gold Stars Selector
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
                    : () => setState(() => _selectedRating = starValue),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    isSelected ? Icons.star_rounded : Icons.star_outline_rounded,
                    color: isSelected ? const Color(0xFFF59E0B) : Colors.grey.shade400,
                    size: 38,
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 6),
          Text(
            _starLabels[_selectedRating - 1],
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: Color(0xFFD97706),
            ),
          ),
          const SizedBox(height: 16),

          // Feedback comment text field
          TextField(
            key: const Key('rating_comment_field'),
            controller: _commentCtrl,
            enabled: !_submitting,
            maxLines: 2,
            maxLength: 120,
            decoration: InputDecoration(
              hintText: 'Add an optional comment...',
              hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              filled: true,
              fillColor: isDark ? const Color(0xFF282832) : const Color(0xFFF9FAFB),
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
      actions: [
        Row(
          children: [
            Expanded(
              child: TextButton(
                key: const Key('rating_skip_button'),
                onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
                child: const Text(
                  'Skip',
                  style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
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
                onPressed: _submitting ? _submit : _submit,
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
