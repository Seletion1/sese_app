import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Modal status viewer displayed when candidate agent clicks the agent button
/// after an application has already been submitted.
class AgentStatusCardSheet extends StatelessWidget {
  final AdminApplication application;
  final VoidCallback? onResubmit;

  const AgentStatusCardSheet({
    super.key,
    required this.application,
    this.onResubmit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          if (application.isPending) ...[
            const Icon(
              Icons.hourglass_top_rounded,
              size: 56,
              color: Colors.orange,
            ),
            const SizedBox(height: 12),
            Text(
              'Your Agent Profile is Under Verification',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Thank you for submitting your "Work With Us" profile. '
              'Our administrative staff in Sese Hub is currently auditing your submitted '
              'Government ID (${application.idType}), proof of address, and live camera selfie.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Card(
              elevation: 0,
              color: cs.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    _infoRow(context, 'Full Name', application.fullName),
                    _infoRow(context, 'Phone Number', application.phoneNumber),
                    _infoRow(context, 'Email Address', application.email),
                    _infoRow(context, 'Status', 'PENDING REVIEW', valueColor: Colors.orange),
                    _infoRow(
                      context,
                      'Submitted On',
                      application.submittedAt.toLocal().toString().split('.').first,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.seseGoldLight,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.seseGold),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.black87, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Once your email is whitelisted and records approved by Sese Hub administration, '
                      'you will be authorized to access staff tools.',
                      style: TextStyle(fontSize: 12, color: Colors.black87),
                    ),
                  ),
                ],
              ),
            ),
          ] else if (application.isApproved) ...[
            const Icon(
              Icons.verified_user_rounded,
              size: 56,
              color: Colors.green,
            ),
            const SizedBox(height: 12),
            Text(
              'Agent Profile Approved!',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.green,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Congratulations! Your Agent application has been approved by Sese Hub administration. '
              'You can now log into Sese Hub with your registered credentials (${application.email}).',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ] else if (application.isRejected) ...[
            const Icon(
              Icons.cancel_outlined,
              size: 56,
              color: Colors.red,
            ),
            const SizedBox(height: 12),
            Text(
              'Application Rejected',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.red,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              application.rejectionReason.isNotEmpty
                  ? 'Reason: ${application.rejectionReason}'
                  : 'Your document verification could not be completed. Please re-submit clear documents.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.red.shade800,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                onResubmit?.call();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Edit & Re-submit Application'),
            ),
          ],

          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(
    BuildContext context,
    String label,
    String value, {
    Color? valueColor,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: valueColor ?? theme.colorScheme.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
