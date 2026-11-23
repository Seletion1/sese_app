import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../../auth/hub_session_guard.dart';
import '../../../widgets/hub_badge.dart';

/// Driver profile audit queue (Step 2 onboarding submissions).
///
/// Lists `drivers` documents awaiting manual document audit
/// (`verificationStatus` in `pending` / `pending_onboarding` / legacy
/// `PENDING`), rendering personal details, government ID captures, the
/// camera-only live selfie, and the emergency contact. Approving sets
/// `isProfileVerified: true`, `isActive: true`, and `verificationStatus:
/// 'approved'`; `canGoOnline` is recomputed (true only when a vehicle is
/// hub-approved too). Rejecting records `verificationStatus: 'rejected'`.
class DriverProfileApprovalsTab extends StatefulWidget {
  final FirebaseFirestore? firestore;

  const DriverProfileApprovalsTab({super.key, this.firestore});

  @override
  State<DriverProfileApprovalsTab> createState() =>
      _DriverProfileApprovalsTabState();
}

class _DriverProfileApprovalsTabState
    extends State<DriverProfileApprovalsTab> {
  FirebaseFirestore get _db => widget.firestore ?? FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();
    // Force-refresh the ID token BEFORE the three WatchStreams open.
    ensureFreshHubIdToken();
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _queue() {
    try {
      final stream1 = _db
          .collection('drivers')
          .where('profileStatus', isEqualTo: 'pending_verification')
          .snapshots();
      final stream2 = _db
          .collection('drivers')
          .where('isPendingReview', isEqualTo: true)
          .snapshots();
      final stream3 = _db
          .collection('drivers')
          .where(DriverVerification.fieldStatus, whereIn: [
            DriverVerification.pending,
            'submitted',
            DriverVerification.pendingOnboarding,
            'PENDING',
          ])
          .snapshots();

      late final StreamController<List<QueryDocumentSnapshot<Map<String, dynamic>>>> controller;
      Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> map1 = {};
      Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> map2 = {};
      Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> map3 = {};

      StreamSubscription? sub1;
      StreamSubscription? sub2;
      StreamSubscription? sub3;

      void emit() {
        final combined = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
        for (final doc in [...map1.values, ...map2.values, ...map3.values]) {
          if (!DriverVerification.isPendingDriverKycDoc(doc.data())) {
            continue;
          }
          combined[doc.id] = doc;
        }
        if (!controller.isClosed) {
          controller.add(combined.values.toList());
        }
      }

      controller = StreamController<List<QueryDocumentSnapshot<Map<String, dynamic>>>>.broadcast(
        onListen: () {
          sub1 = stream1.listen((snap) {
            map1 = {for (var d in snap.docs) d.id: d};
            emit();
          }, onError: (e) {
            if (map2.isEmpty && map3.isEmpty) controller.addError(e);
          });
          sub2 = stream2.listen((snap) {
            map2 = {for (var d in snap.docs) d.id: d};
            emit();
          }, onError: (e) {
            if (map1.isEmpty && map3.isEmpty) controller.addError(e);
          });
          sub3 = stream3.listen((snap) {
            map3 = {for (var d in snap.docs) d.id: d};
            emit();
          }, onError: (e) {
            if (map1.isEmpty && map2.isEmpty) controller.addError(e);
          });
        },
        onCancel: () async {
          await sub1?.cancel();
          await sub2?.cancel();
          await sub3?.cancel();
          if (!controller.isClosed) {
            await controller.close();
          }
        },
      );

      return controller.stream;
    } catch (_) {
      return Stream.value(const []);
    }
  }

  Future<void> _recomputeCanGoOnline(String driverId) async {
    try {
      final doc = await _db.collection('drivers').doc(driverId).get();
      final data = doc.data();
      if (data == null) return;
      final canGoOnline = data[DriverVerification.fieldProfileVerified] ==
              true &&
          data[DriverVerification.fieldVehicleVerified] == true;
      await _db.collection('drivers').doc(driverId).set(
        {DriverVerification.fieldCanGoOnline: canGoOnline},
        SetOptions(merge: true),
      );
    } catch (_) {}
  }

  Future<void> _approve(String driverId, String name) async {
    try {
      await _db.collection('drivers').doc(driverId).set(
        {
          'profileStatus': 'approved',
          DriverVerification.fieldStatus: DriverVerification.approved,
          DriverVerification.fieldProfileVerified: true,
          'isPendingReview': false,
          'isActive': true,
          'profileApprovedAt': DateTime.now().toIso8601String(),
        },
        SetOptions(merge: true),
      );
      await _recomputeCanGoOnline(driverId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Driver $name profile APPROVED.'),
          backgroundColor: Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error approving profile: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  Future<void> _reject(String driverId, String name) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => _DriverProfileRejectionDialog(name: name),
    );
    if (reason == null || reason.isEmpty) return;
    try {
      await _db.collection('drivers').doc(driverId).set(
        {
          'profileStatus': 'rejected',
          DriverVerification.fieldStatus: DriverVerification.rejected,
          DriverVerification.fieldProfileVerified: false,
          'isPendingReview': false,
          'isActive': false,
          'profileRejectionReason': reason,
        },
        SetOptions(merge: true),
      );
      await _recomputeCanGoOnline(driverId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Driver $name profile REJECTED.'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error rejecting profile: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      stream: _queue(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const SeseListSkeleton(itemCount: 4);
        }
        if (snapshot.hasError) {
          if (isHubSessionExpiredError(snapshot.error)) {
            return const HubSessionExpiredView(
                contextLabel: 'driver profiles');
          }
          return Center(
            child: Text('Failed to load driver profiles: ${snapshot.error}'),
          );
        }
        final docs = snapshot.data ?? [];
        if (docs.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline, size: 64, color: Colors.green),
                SizedBox(height: 16),
                Text('No pending driver profiles. All queues cleared!'),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    const Text(
                      'Driver Profile Verification Queue',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    HubCountBadge(count: docs.length),
                  ],
                ),
              );
            }
            final doc = docs[index - 1];
            final data = doc.data();
            final name = (data['fullName'] ?? '').toString().isNotEmpty
                ? data['fullName'].toString()
                : doc.id;
            return _DriverProfileCard(
              key: Key('driver_profile_card_${doc.id}'),
              driverId: doc.id,
              data: data,
              firestore: _db,
              onRecomputeCanGoOnline: _recomputeCanGoOnline,
              onQuickApprove: () => _approve(doc.id, name),
              onQuickReject: () => _reject(doc.id, name),
            );
          },
        );
      },
    );
  }
}

/// Local state holder for a single field's hub review decision.
class _FieldDecision {
  final String status; // 'approved' | 'rejected'
  final String reason; // required when rejected
  const _FieldDecision({required this.status, this.reason = ''});
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';
}

/// Stateful card representing one driver pending profile review.
///
/// Renders per-field approve/reject toggles for identity fields and
/// document thumbnails, then submits a consolidated `fieldReviewStatus`
/// map to Firestore with an overall `verificationStatus` derived from
/// the individual decisions.
class _DriverProfileCard extends StatefulWidget {
  final String driverId;
  final Map<String, dynamic> data;
  final FirebaseFirestore firestore;
  final Future<void> Function(String driverId) onRecomputeCanGoOnline;
  final VoidCallback? onQuickApprove;
  final VoidCallback? onQuickReject;

  const _DriverProfileCard({
    super.key,
    required this.driverId,
    required this.data,
    required this.firestore,
    required this.onRecomputeCanGoOnline,
    this.onQuickApprove,
    this.onQuickReject,
  });

  @override
  State<_DriverProfileCard> createState() => _DriverProfileCardState();
}

class _DriverProfileCardState extends State<_DriverProfileCard> {
  /// Map of fieldId → current decision for this review session.
  final Map<String, _FieldDecision> _decisions = {};

  /// Text controllers for rejection reasons; keyed by fieldId.
  final Map<String, TextEditingController> _reasonControllers = {};

  bool _submitting = false;

  @override
  void dispose() {
    for (final c in _reasonControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _reasonCtrl(String fieldId) {
    return _reasonControllers.putIfAbsent(
        fieldId, () => TextEditingController());
  }

  void _decide(String fieldId, String status) {
    setState(() {
      _decisions[fieldId] =
          _FieldDecision(status: status, reason: _reasonCtrl(fieldId).text.trim());
    });
  }

  Future<void> _submitReview() async {
    if (_submitting) return;
    // Build fieldReviewStatus map from current decisions
    final Map<String, Map<String, dynamic>> fieldReviewStatus = {};
    for (final entry in _decisions.entries) {
      final reason = entry.value.isRejected
          ? _reasonCtrl(entry.key).text.trim()
          : null;
      if (entry.value.isRejected && (reason == null || reason.isEmpty)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Please provide a rejection reason for "${entry.key}".'),
            backgroundColor: Colors.red.shade700,
          ),
        );
        return;
      }
      fieldReviewStatus[entry.key] = {
        'status': entry.value.status,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      };
    }

    final anyRejected =
        _decisions.values.any((d) => d.isRejected);
    final allKeyFieldsApproved = ['homeAddress', 'idFront', 'selfie']
        .every((f) => _decisions[f]?.isApproved == true);

    String overallStatus;
    bool isProfileVerified;
    if (anyRejected) {
      overallStatus = DriverVerification.rejected;
      isProfileVerified = false;
    } else if (allKeyFieldsApproved && _decisions.isNotEmpty) {
      overallStatus = DriverVerification.approved;
      isProfileVerified = true;
    } else {
      overallStatus = DriverVerification.pending;
      isProfileVerified = false;
    }

    final rejectedSummary = _decisions.entries
        .where((e) => e.value.isRejected)
        .map((e) {
          final reason = _reasonCtrl(e.key).text.trim();
          return '${e.key}: $reason';
        })
        .join('; ');

    setState(() => _submitting = true);
    try {
      final update = <String, dynamic>{
        DriverVerification.fieldReviewStatus: fieldReviewStatus,
        DriverVerification.fieldStatus: overallStatus,
        DriverVerification.fieldProfileVerified: isProfileVerified,
        'isPendingReview': false,
        'isActive': isProfileVerified,
      };
      if (overallStatus == DriverVerification.approved) {
        update['profileApprovedAt'] = DateTime.now().toIso8601String();
        update['profileStatus'] = 'approved';
      } else if (overallStatus == DriverVerification.rejected) {
        update[DriverVerification.fieldProfileRejectionReason] = rejectedSummary;
        update['profileStatus'] = 'rejected';
      }
      await widget.firestore.collection('drivers').doc(widget.driverId).set(
            update,
            SetOptions(merge: true),
          );
      await widget.onRecomputeCanGoOnline(widget.driverId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Review submitted: $overallStatus'),
          backgroundColor: overallStatus == DriverVerification.approved
              ? Colors.green.shade800
              : Colors.red.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error submitting review: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _fieldReviewRow(String fieldId, String label, String value) {
    final decision = _decisions[fieldId];
    final isApproved = decision?.isApproved == true;
    final isRejected = decision?.isRejected == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 12)),
                  Text(value.isEmpty ? '—' : value,
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            // Approve toggle
            GestureDetector(
              key: Key('approve_${fieldId}_${widget.driverId}'),
              onTap: () => _decide(fieldId, 'approved'),
              child: Container(
                margin: const EdgeInsets.only(left: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isApproved
                      ? Colors.green.shade600
                      : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.green.shade300),
                ),
                child: Text('✓',
                    style: TextStyle(
                        color: isApproved ? Colors.white : Colors.green.shade700,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
              ),
            ),
            // Reject toggle
            GestureDetector(
              key: Key('reject_${fieldId}_${widget.driverId}'),
              onTap: () => _decide(fieldId, 'rejected'),
              child: Container(
                margin: const EdgeInsets.only(left: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color:
                      isRejected ? Colors.red.shade600 : Colors.red.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.red.shade300),
                ),
                child: Text('✗',
                    style: TextStyle(
                        color:
                            isRejected ? Colors.white : Colors.red.shade700,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
              ),
            ),
          ],
        ),
        if (isRejected) ...[
          const SizedBox(height: 4),
          TextField(
            controller: _reasonCtrl(fieldId),
            decoration: InputDecoration(
              hintText: 'Rejection reason for $label (required)',
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 12),
            onChanged: (v) {
              _decisions[fieldId] =
                  _FieldDecision(status: 'rejected', reason: v.trim());
            },
          ),
        ],
        const SizedBox(height: 6),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final name = (data['fullName'] ?? '').toString().isNotEmpty
        ? data['fullName'].toString()
        : widget.driverId;
    final status =
        (data[DriverVerification.fieldStatus] ?? '').toString();
    final kin = data['emergencyContact'] is Map
        ? Map<String, dynamic>.from(data['emergencyContact'] as Map)
        : <String, dynamic>{};

    return Card(
      key: Key('driver_profile_${widget.driverId}'),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                CircleAvatar(
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : 'D',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16)),
                          ),
                          if ((data['sequentialId'] ?? '').toString().isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: Colors.blue.shade300),
                              ),
                              child: Text(
                                (data['sequentialId'] ?? '').toString(),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue.shade800,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        '${data['phoneNumber'] ?? ''} • ${data['email'] ?? ''}',
                        style: const TextStyle(
                            color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(status),
                  backgroundColor: Colors.orange.shade100,
                  labelStyle: TextStyle(
                      color: Colors.orange.shade900, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Per-Field Review',
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 13)),
            const Divider(),
            _fieldReviewRow('homeAddress', 'Address',
                '${data['homeAddress'] ?? ''}'),
            _fieldReviewRow('dateOfBirth', 'Date of Birth',
                '${data['dateOfBirth'] ?? ''}'),
            _fieldReviewRow(
                'gender', 'Gender', '${data['gender'] ?? ''}'),
            _fieldReviewRow(
                'id',
                'ID',
                '${data['idType'] ?? ''}: '
                    '${data['idNumber'] ?? ''}'),
            if ((data['idExpiryDate'] ?? '').toString().isNotEmpty)
              _fieldReviewRow('idExpiry', 'ID Expiry',
                  '${data['idExpiryDate']}'),
            _fieldReviewRow(
                'emergencyContact',
                'Next of Kin',
                '${kin['name'] ?? ''} '
                    '(${kin['relationship'] ?? ''}) • '
                    '${kin['phone'] ?? ''}'),
            if ((kin['address'] ?? '').toString().isNotEmpty)
              _fieldReviewRow('kinAddress', 'Kin Address',
                  '${kin['address']}'),
            const SizedBox(height: 8),
            // Document thumbnail chips with per-field approve/reject
            if ((data['idFrontUrl'] ?? '').toString().isNotEmpty) ...[
              _fieldReviewRow('idFront', 'ID Front', ''),
              CachedDocumentThumbnailChip(
                imageUrl: data['idFrontUrl'].toString(),
                label: 'ID Front',
                fallbackIcon: Icons.badge_outlined,
              ),
              const SizedBox(height: 6),
            ],
            if ((data['idBackUrl'] ?? '').toString().isNotEmpty) ...[
              _fieldReviewRow('idBack', 'ID Back', ''),
              CachedDocumentThumbnailChip(
                imageUrl: data['idBackUrl'].toString(),
                label: 'ID Back',
                fallbackIcon: Icons.badge_outlined,
              ),
              const SizedBox(height: 6),
            ],
            if ((data['selfieUrl'] ?? '').toString().isNotEmpty) ...[
              _fieldReviewRow('selfie', 'Live Selfie', ''),
              CachedDocumentThumbnailChip(
                imageUrl: data['selfieUrl'].toString(),
                label: 'Live Selfie',
                fallbackIcon: Icons.photo_camera_outlined,
              ),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: Key('submit_review_${widget.driverId}'),
                icon: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white),
                      )
                    : const Icon(Icons.rate_review_outlined),
                label: Text(_submitting
                    ? 'Submitting…'
                    : 'Submit Field Review'),
                onPressed: _submitting ? null : _submitReview,
              ),
            ),
            if (widget.onQuickApprove != null || widget.onQuickReject != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (widget.onQuickReject != null)
                    Expanded(
                      child: OutlinedButton(
                        key: Key('quick_reject_${widget.driverId}'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red.shade700,
                        ),
                        onPressed: _submitting ? null : widget.onQuickReject,
                        child: const Text('Quick Reject'),
                      ),
                    ),
                  if (widget.onQuickReject != null && widget.onQuickApprove != null)
                    const SizedBox(width: 8),
                  if (widget.onQuickApprove != null)
                    Expanded(
                      child: OutlinedButton(
                        key: Key('quick_approve_${widget.driverId}'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.green.shade700,
                        ),
                        onPressed: _submitting ? null : widget.onQuickApprove,
                        child: const Text('Quick Approve'),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DriverProfileRejectionDialog extends StatefulWidget {  final String name;
  const _DriverProfileRejectionDialog({required this.name});

  @override
  State<_DriverProfileRejectionDialog> createState() =>
      _DriverProfileRejectionDialogState();
}

class _DriverProfileRejectionDialogState
    extends State<_DriverProfileRejectionDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Reject ${widget.name} profile?'),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          labelText: 'Rejection reason (required)',
        ),
        maxLines: 3,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Reject'),
        ),
      ],
    );
  }
}
