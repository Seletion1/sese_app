import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Persistent verification banner shown while the driver profile is not yet
/// hub-approved.
///
/// Visible when `drivers/{uid}.verificationStatus` is `pending`,
/// `pending_onboarding`, or legacy `PENDING`, or when `isProfileVerified`
/// is not `true`. Fleet & Vehicles stays reachable underneath so drivers can
/// submit vehicles while profile verification is pending.
class VerificationBanner extends StatefulWidget {
  final String driverId;

  const VerificationBanner({super.key, required this.driverId});

  @override
  State<VerificationBanner> createState() => _VerificationBannerState();
}

class _VerificationBannerState extends State<VerificationBanner> {
  bool _isDismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_isDismissed) return const SizedBox.shrink();

    FirebaseFirestore? db;
    try {
      db = FirebaseFirestore.instance;
    } catch (_) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('drivers').doc(widget.driverId).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        if (data == null) return const SizedBox.shrink();
        final status =
            (data[DriverVerification.fieldStatus] ?? '').toString().toLowerCase();
        final profileVerified =
            data[DriverVerification.fieldProfileVerified] == true;
        final pending = status == DriverVerification.pending ||
            status == DriverVerification.pendingOnboarding ||
            !profileVerified;
        final approved =
            status == DriverVerification.approved && profileVerified;
        if (!pending || approved) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;
        final bannerBg = isDark
            ? theme.colorScheme.surfaceContainerHighest
            : const Color(0xFFFFF8E1); // Soft alert yellow
        final textColor =
            isDark ? theme.colorScheme.onSurface : const Color(0xFF5D4037);
        final iconColor = isDark ? Colors.amber : const Color(0xFFF57C00);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            color: bannerBg,
            elevation: 1,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              key: const Key('driver_verification_banner'),
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: bannerBg,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black
                        .withValues(alpha: isDark ? 0.2 : 0.06),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: iconColor, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Account pending verification. Our team is reviewing your submission.',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                        color: textColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    key: const Key('dismiss_verification_banner'),
                    onTap: () => setState(() => _isDismissed = true),
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Icon(
                        Icons.close,
                        size: 18,
                        color: textColor.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
