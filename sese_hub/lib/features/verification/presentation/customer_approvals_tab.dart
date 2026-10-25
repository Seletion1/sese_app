// ignore_for_file: deprecated_member_use
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../../auth/hub_session_guard.dart';
import '../../dashboard/presentation/hub_user_wallet_card.dart';

/// Customer KYC verification audit queue.
///
/// Lists `users` documents with `customerVerificationStatus == 'pending_review'`
/// (also catches legacy `pending` value). Displays full KYC payload including
/// personal info, employment, government ID, and document photo chips.
///
/// Approve → sets `verified` + `isVerifiedCustomer: true` + writes
///   `verificationReviewedAt`.
/// Reject  → prompts admin for a structured reason, stores it as
///   `kycRejectionReason`, sets status back to `rejected`.
class CustomerApprovalsTab extends StatefulWidget {
  final FirebaseFirestore? firestore;

  const CustomerApprovalsTab({super.key, this.firestore});

  @override
  State<CustomerApprovalsTab> createState() => _CustomerApprovalsTabState();
}

class _CustomerApprovalsTabState extends State<CustomerApprovalsTab> {
  FirebaseFirestore get _db => widget.firestore ?? FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();
    // Force-refresh the ID token BEFORE the WatchStream opens.
    ensureFreshHubIdToken();
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _queue() {
    // Accept both the new `pending_review` and legacy `pending` values.
    return _db
        .collection('users')
        .where(CustomerVerification.fieldStatus,
            whereIn: [
              CustomerVerification.pendingReview,
              CustomerVerification.pending,
            ])
        .snapshots()
        .map((snap) => snap.docs);
  }

  Future<void> _approve(String uid, String name) async {
    try {
      await _db.collection('users').doc(uid).set(
        {
          CustomerVerification.fieldStatus: CustomerVerification.verified,
          CustomerVerification.fieldIsVerified: true,
          CustomerVerification.fieldRejectionReason: '',
          'verificationReviewedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Customer $name VERIFIED ✓'),
          backgroundColor: Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error verifying: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  Future<void> _reject(String uid, String name) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => _KycRejectionDialog(name: name),
    );
    if (reason == null || reason.isEmpty) return;
    try {
      await _db.collection('users').doc(uid).set(
        {
          CustomerVerification.fieldStatus: CustomerVerification.rejected,
          CustomerVerification.fieldIsVerified: false,
          CustomerVerification.fieldRejectionReason: reason,
          'verificationReviewedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Customer $name REJECTED.'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error rejecting: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  void _showImage(String title, String url) {
    if (url.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 48, 8),
              child: Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            Flexible(
              child: Image.network(url,
                  cacheWidth: 1024,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Could not load image.'),
                      )),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      stream: _queue(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          if (isHubSessionExpiredError(snapshot.error)) {
            return const HubSessionExpiredView(
                contextLabel: 'customer verifications');
          }
          return Center(
            child: Text('Failed to load: ${snapshot.error}'),
          );
        }
        final docs = snapshot.data ?? [];
        if (docs.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline,
                    size: 64, color: Colors.green),
                SizedBox(height: 16),
                Text('No pending customer verifications.'),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final doc = docs[index];
            final data = doc.data();
            final kyc = data[CustomerVerification.fieldKycData];
            final kycMap = kyc is Map
                ? Map<String, dynamic>.from(kyc)
                : <String, dynamic>{};

            final name =
                (kycMap['fullName'] ?? data['fullName'] ?? '').toString().isNotEmpty
                    ? (kycMap['fullName'] ?? data['fullName']).toString()
                    : doc.id;

            return Card(
              key: Key('customer_approval_${doc.id}'),
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Header row ──────────────────────────────────────────
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor:
                              Theme.of(context).colorScheme.primaryContainer,
                          child: Text(
                            name.isNotEmpty ? name[0].toUpperCase() : 'C',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                              Text(
                                '${data['phoneNumber'] ?? ''} · ${data['email'] ?? ''}',
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        Chip(
                          label: const Text('pending'),
                          backgroundColor: Colors.orange.shade100,
                          labelStyle: TextStyle(
                              color: Colors.orange.shade900, fontSize: 11),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // ── Personal info ───────────────────────────────────────
                    _sectionLabel('Personal Information'),
                    _fact('DOB', kycMap['dateOfBirth'] ?? ''),
                    _fact('Gender', kycMap['gender'] ?? ''),
                    _fact('Address', kycMap['residentialAddress'] ?? data['homeAddress'] ?? ''),

                    // ── Employment ──────────────────────────────────────────
                    if ((kycMap['occupation'] ?? '').toString().isNotEmpty) ...[
                      _sectionLabel('Employment / Organisation'),
                      _fact('Occupation', kycMap['occupation'] ?? ''),
                      _fact('Org Name', kycMap['orgName'] ?? ''),
                      _fact('Org Address', kycMap['orgAddress'] ?? ''),
                    ],

                    // ── ID ──────────────────────────────────────────────────
                    _sectionLabel('Government ID'),
                    _fact(
                      'ID',
                      '${kycMap['idType'] ?? data['verificationIdType'] ?? ''}: '
                          '${kycMap['idNumber'] ?? data['verificationIdNumber'] ?? ''}',
                    ),

                    const SizedBox(height: 10),

                    // ── Document photo chips ────────────────────────────────
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _docChip('Proof of Address',
                            Icons.home_outlined,
                            kycMap['proofOfAddressUrl'] ?? ''),
                        _docChip('ID Front',
                            Icons.badge_outlined,
                            kycMap['idFrontUrl'] ?? data['idFrontUrl'] ?? ''),
                        _docChip('ID Back',
                            Icons.badge_outlined,
                            kycMap['idBackUrl'] ?? data['idBackUrl'] ?? ''),
                        _docChip('Live Selfie',
                            Icons.photo_camera_outlined,
                            kycMap['selfieUrl'] ??
                                data['verificationSelfieUrl'] ??
                                data['selfieUrl'] ?? ''),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // ── Wallet balances ─────────────────────────────────────
                    // WHY: Admins need visibility into both wallets for every
                    // user type (not just drivers) during the approval workflow.
                    // Mirrors the HubUserWalletCard already present in
                    // driver_profile_approvals_tab.dart:345.
                    HubUserWalletCard(
                      key: Key('customer_wallet_${doc.id}'),
                      userId: doc.id,
                      firestore: _db,
                    ),

                    const SizedBox(height: 12),

                    // ── Action buttons ──────────────────────────────────────
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _reject(doc.id, name),
                            style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red.shade700),
                            child: const Text('Reject'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => _approve(doc.id, name),
                            style: FilledButton.styleFrom(
                                backgroundColor: Colors.green.shade700),
                            child: const Text('Verify ✓'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _sectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _fact(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 12)),
          ),
          Expanded(
            child: Text(value.isEmpty ? '—' : value,
                style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _docChip(String label, IconData icon, String url) {
    if (url.isEmpty) return const SizedBox.shrink();
    return ActionChip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      onPressed: () => _showImage(label, url),
    );
  }
}

// ── Rejection dialog ──────────────────────────────────────────────────────────

class _KycRejectionDialog extends StatefulWidget {
  final String name;

  const _KycRejectionDialog({required this.name});

  @override
  State<_KycRejectionDialog> createState() => _KycRejectionDialogState();
}

class _KycRejectionDialogState extends State<_KycRejectionDialog> {
  final _ctrl = TextEditingController();
  String _preset = '';

  static const _reasons = [
    'Blurry or unreadable document image',
    'Name mismatch between ID and form',
    'Invalid or expired ID number',
    'Selfie does not match ID photo',
    'Proof of address insufficient',
    'Other (specify below)',
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String get _finalReason =>
      _preset.isEmpty || _preset == 'Other (specify below)'
          ? _ctrl.text.trim()
          : _preset;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Reject ${widget.name}?'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Select a reason:',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ..._reasons.map((r) => RadioListTile<String>(
                  title: Text(r, style: const TextStyle(fontSize: 13)),
                  value: r,
                  groupValue: _preset,
                  dense: true,
                  onChanged: (v) => setState(() => _preset = v ?? ''),
                )),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Additional notes (optional)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _finalReason.isEmpty
              ? null
              : () => Navigator.pop(context, _finalReason),
          style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700),
          child: const Text('Reject'),
        ),
      ],
    );
  }
}
