import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Full-screen or modal dialog inside Sese Hub to inspect candidate agent applications,
/// review uploaded documents/selfie, check hub_staff whitelisting, and perform manual approval/rejection.
class AgentApplicationDetailDialog extends StatefulWidget {
  final AdminApplication application;

  const AgentApplicationDetailDialog({
    super.key,
    required this.application,
  });

  static Future<void> show(BuildContext context, AdminApplication app) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => AgentApplicationDetailDialog(application: app),
    );
  }

  @override
  State<AgentApplicationDetailDialog> createState() =>
      _AgentApplicationDetailDialogState();
}

class _AgentApplicationDetailDialogState
    extends State<AgentApplicationDetailDialog> {
  final _service = AdminApplicationService();
  bool _processing = false;

  String get _reviewerEmail =>
      FirebaseAuth.instance.currentUser?.email ?? 'bamiduromichael2@gmail.com';

  Future<void> _approve() async {
    setState(() => _processing = true);
    try {
      await _service.approveApplication(
        uid: widget.application.uid,
        email: widget.application.email,
        reviewerEmail: _reviewerEmail,
      );

      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Agent ${widget.application.fullName} approved and activated in hub_staff.',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Approval failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _reject() async {
    final reasonCtrl = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Agent Application'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Please enter a rejection reason for the applicant:',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Rejection Reason',
                hintText: 'Document blurry, address mismatch, etc.',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Reject'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _processing = true);
    try {
      await _service.rejectApplication(
        uid: widget.application.uid,
        reviewerEmail: _reviewerEmail,
        reason: reasonCtrl.text.trim(),
      );

      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Application for ${widget.application.fullName} marked as rejected.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Rejection failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _whitelistEmail() async {
    setState(() => _processing = true);
    try {
      await _service.provisionHubStaff(
        candidateEmail: widget.application.email,
        provisionerEmail: _reviewerEmail,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Email ${widget.application.email} added to hub_staff whitelist.',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Whitelisting failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final app = widget.application;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 900),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: AppColors.seseGold.withValues(alpha: 0.2),
                    child: const Icon(Icons.badge, color: Colors.black),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.fullName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Agent Application • Submitted ${app.submittedAt.toLocal().toString().split('.').first}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Divider(height: 20),

              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Whitelisting status banner
                      StreamBuilder<DocumentSnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('hub_staff')
                            .doc(app.email.trim().toLowerCase())
                            .snapshots(),
                        builder: (context, snap) {
                          final isWhitelisted = snap.hasData &&
                              snap.data!.exists &&
                              (snap.data!.data() as Map?)?['active'] != false;

                          if (isWhitelisted) {
                            return Container(
                              padding: const EdgeInsets.all(12),
                              margin: const EdgeInsets.only(bottom: 16),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.green),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.verified, color: Colors.green),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Email (${app.email}) is present & active in hub_staff whitelist.',
                                      style: TextStyle(
                                        color: Colors.green.shade900,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }

                          return Container(
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade50,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.orange),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Email (${app.email}) is NOT in hub_staff whitelist!',
                                        style: TextStyle(
                                          color: Colors.orange.shade900,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      const Text(
                                        'Whitelisting is required before the user can authenticate into Sese Hub.',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton.icon(
                                  onPressed: _processing ? null : _whitelistEmail,
                                  icon: const Icon(Icons.add_moderator, size: 16),
                                  label: const Text('Whitelist Email'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),

                      // Candidate Personal Info
                      _sectionTitle(context, 'Applicant Details'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          _detailChip(context, 'Full Name', app.fullName),
                          _detailChip(context, 'Phone Number', app.phoneNumber),
                          _detailChip(context, 'Email Address', app.email),
                          _detailChip(context, 'Date of Birth', app.dob),
                          _detailChip(context, 'ID Type', app.idType.toUpperCase()),
                          _detailChip(context, 'Status', app.status.toUpperCase()),
                        ],
                      ),

                      if (app.deviceMetadata.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _sectionTitle(context, 'Device Metadata & Security Audit'),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            app.deviceMetadata.entries
                                .map((e) => '${e.key}: ${e.value}')
                                .join(' • '),
                            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                          ),
                        ),
                      ],

                      const SizedBox(height: 20),
                      _sectionTitle(context, 'Verification Documents & Biometric Snapshot'),
                      const SizedBox(height: 12),

                      // Document Images
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final isWide = constraints.maxWidth > 600;
                          final cardWidth = isWide
                              ? (constraints.maxWidth - 24) / 3
                              : constraints.maxWidth;

                          return Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              _documentPreviewCard(
                                context,
                                title: 'Government ID (${app.idType})',
                                url: app.idUrl,
                                width: cardWidth,
                              ),
                              _documentPreviewCard(
                                context,
                                title: 'Proof of Address',
                                url: app.proofOfAddressUrl,
                                width: cardWidth,
                              ),
                              _documentPreviewCard(
                                context,
                                title: 'Live Camera Selfie',
                                url: app.selfieUrl,
                                width: cardWidth,
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),

              const Divider(height: 20),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                  const SizedBox(width: 12),
                  if (app.isPending) ...[
                    ElevatedButton.icon(
                      onPressed: _processing ? null : _reject,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade100,
                        foregroundColor: Colors.red.shade900,
                      ),
                      icon: const Icon(Icons.close),
                      label: const Text('Reject'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _processing ? null : _approve,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                      icon: _processing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_circle_outline),
                      label: const Text('Approve & Activate Agent'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
    );
  }

  Widget _detailChip(BuildContext context, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: RichText(
        text: TextSpan(
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13),
          children: [
            TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }

  Widget _documentPreviewCard(
    BuildContext context, {
    required String title,
    required String url,
    required double width,
  }) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
            child: SizedBox(
              height: 180,
              child: url.isNotEmpty
                  ? Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined, size: 40),
                      ),
                      loadingBuilder: (_, child, progress) {
                        if (progress == null) return child;
                        return const Center(child: CircularProgressIndicator());
                      },
                    )
                  : const Center(
                      child: Text('No image uploaded', style: TextStyle(fontSize: 12)),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
