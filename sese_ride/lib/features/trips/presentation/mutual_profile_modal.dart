import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Modal bottom sheet surfacing detailed profile and trust metrics for a peer
/// (Driver or Customer) on an active trip.
class MutualProfileModal extends StatelessWidget {
  final String userId;
  final String fallbackName;
  final String fallbackPhotoUrl;
  final double fallbackRating;
  final String roleLabel;
  final String? vehicleInfo;

  const MutualProfileModal({
    super.key,
    required this.userId,
    required this.fallbackName,
    this.fallbackPhotoUrl = '',
    this.fallbackRating = 5.0,
    this.roleLabel = 'User',
    this.vehicleInfo,
  });

  static Future<void> show(
    BuildContext context, {
    required String userId,
    required String fallbackName,
    String fallbackPhotoUrl = '',
    double fallbackRating = 5.0,
    String roleLabel = 'User',
    String? vehicleInfo,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MutualProfileModal(
        userId: userId,
        fallbackName: fallbackName,
        fallbackPhotoUrl: fallbackPhotoUrl,
        fallbackRating: fallbackRating,
        roleLabel: roleLabel,
        vehicleInfo: vehicleInfo,
      ),
    );
  }

  String _formatMonthYear(DateTime dt) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${months[dt.month - 1]} ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: userId.isNotEmpty
          ? FirebaseFirestore.instance.collection('users').doc(userId).get()
          : null,
      builder: (context, snapshot) {
        final data = snapshot.data?.data();

        final fullName =
            (data?['fullName'] as String?)?.trim().isNotEmpty == true
                ? (data!['fullName'] as String).trim()
                : fallbackName.isNotEmpty
                    ? fallbackName
                    : 'Sese User';

        final photoUrl = (data?['photoUrl'] as String?) ?? fallbackPhotoUrl;

        // Live average star rating — server-computed from totalRatingSum/Count.
        final rating =
            (data?['averageRating'] as num?)?.toDouble() ?? fallbackRating;

        // Total number of individual ratings received (shown as "N Reviews").
        final ratingCount =
            (data?['totalRatingCount'] as num?)?.toInt() ?? 0;

        // Total completed trips — incremented by the onTripCompleted Cloud Function.
        final completedTrips =
            (data?['completedTrips'] as num?)?.toInt() ?? 0;

        final rawCreated = data?['createdAt'];
        final createdAt = AppUser.fromMap({'createdAt': rawCreated}).createdAt;
        final memberSince = _formatMonthYear(createdAt);

        final isDriver = roleLabel.toLowerCase().contains('driver');

        return Container(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 16,
                offset: Offset(0, -4),
              ),
            ],
          ),
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            24 + MediaQuery.of(context).padding.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Top drag bar handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF3A3A46) : Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Title Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    isDriver ? 'Driver Profile' : 'Customer Profile',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Profile Picture & Name Badge
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  UserAvatar(
                    displayName: fullName,
                    photoUrl: photoUrl,
                    radius: 44,
                  ),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.verified,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Full Name & Verified Badge
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      fullName,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.verified, color: Colors.blue, size: 20),
                ],
              ),
              const SizedBox(height: 4),

              // Role Pill / Vehicle Subtitle
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.seseGold.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  vehicleInfo ?? (isDriver ? 'Verified Driver' : 'Verified Customer'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFD97706),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Trust Metrics Row: Rating, Member Since, Completed Trips
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.star_rounded,
                      iconColor: Colors.amber,
                      value: ratingCount > 0
                          ? rating.toStringAsFixed(1)
                          : '—',
                      label: ratingCount > 0
                          ? '$ratingCount ${ratingCount == 1 ? "Review" : "Reviews"}'
                          : 'No ratings yet',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.calendar_today_rounded,
                      iconColor: Colors.blue,
                      value: memberSince,
                      label: 'Member Since',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.local_taxi_rounded,
                      iconColor: Colors.green,
                      value: '$completedTrips',
                      label: 'Trips Completed',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Trust Badges List
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF252530) : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isDark ? const Color(0xFF3A3A46) : Colors.grey.shade200,
                  ),
                ),
                child: Column(
                  children: [
                    _TrustBadgeTile(
                      icon: Icons.shield_outlined,
                      title: 'Identity Verified',
                      subtitle: 'Government ID & facial verification complete',
                    ),
                    Divider(
                      height: 16,
                      color: isDark ? const Color(0xFF3A3A46) : null,
                    ),
                    _TrustBadgeTile(
                      icon: Icons.phone_android_outlined,
                      title: 'Phone Number Verified',
                      subtitle: 'Cryptographically secured account line',
                    ),
                    if (isDriver) ...[
                      Divider(
                        height: 16,
                        color: isDark ? const Color(0xFF3A3A46) : null,
                      ),
                      _TrustBadgeTile(
                        icon: Icons.verified_user_outlined,
                        title: 'Background & Vehicle Checked',
                        subtitle: 'Passed SeseRide safety and registration audit',
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Done Action Button
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  style: FilledButton.styleFrom(
                    backgroundColor: cs.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text(
                    'Done',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String value;
  final String label;

  const _MetricCard({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252530) : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF3A3A46) : Colors.grey.shade200,
        ),
      ),
      child: Column(
        children: [
          Icon(icon, color: iconColor, size: 22),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _TrustBadgeTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _TrustBadgeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF10B981).withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: const Color(0xFF10B981), size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
        const Icon(
          Icons.check_circle,
          color: Color(0xFF10B981),
          size: 18,
        ),
      ],
    );
  }
}
