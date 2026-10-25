import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../../auth/hub_session_guard.dart';
import '../../dashboard/presentation/hub_user_wallet_card.dart';

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
        final data = doc.data();
        final status = (data[DriverVerification.fieldStatus] ?? '').toString().toLowerCase();
        final profileStatus = (data['profileStatus'] ?? '').toString().toLowerCase();
        if ((status == 'approved' || status == 'verified') && profileStatus != 'pending_verification') {
          continue;
        }
        if (status == 'rejected' && profileStatus != 'pending_verification') {
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
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final doc = docs[index];
            final data = doc.data();
            final name = (data['fullName'] ?? '').toString().isNotEmpty
                ? data['fullName'].toString()
                : doc.id;
            final status =
                (data[DriverVerification.fieldStatus] ?? '').toString();
            final kin = data['emergencyContact'] is Map
                ? Map<String, dynamic>.from(data['emergencyContact'] as Map)
                : <String, dynamic>{};
            return Card(
              key: Key('driver_profile_${doc.id}'),
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .primaryContainer,
                          child: Text(
                            name.isNotEmpty ? name[0].toUpperCase() : 'D',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold),
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
                    const SizedBox(height: 24),
                    _fact('Address', '${data['homeAddress'] ?? ''}'),
                    _fact('Date of Birth', '${data['dateOfBirth'] ?? ''}'),
                    _fact('Gender', '${data['gender'] ?? ''}'),
                    _fact(
                        'ID',
                        '${data['idType'] ?? ''}: '
                        '${data['idNumber'] ?? ''}'),
                    if ((data['idExpiryDate'] ?? '').toString().isNotEmpty)
                      _fact('ID Expiry', '${data['idExpiryDate']}'),
                    _fact(
                        'Next of Kin',
                        '${kin['name'] ?? ''} '
                        '(${kin['relationship'] ?? ''}) • '
                        '${kin['phone'] ?? ''}'),
                    if ((kin['address'] ?? '').toString().isNotEmpty)
                      _fact('Kin Address', '${kin['address']}'),
                    const SizedBox(height: 8),
                    HubUserWalletCard(userId: doc.id, firestore: _db),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if ((data['idFrontUrl'] ?? '').toString().isNotEmpty)
                          ActionChip(
                            avatar: const Icon(Icons.badge_outlined,
                                size: 16),
                            label: const Text('ID Front'),
                            onPressed: () => _showImage('ID Front',
                                data['idFrontUrl'].toString()),
                          ),
                        if ((data['idBackUrl'] ?? '').toString().isNotEmpty)
                          ActionChip(
                            avatar: const Icon(Icons.badge_outlined,
                                size: 16),
                            label: const Text('ID Back'),
                            onPressed: () => _showImage('ID Back',
                                data['idBackUrl'].toString()),
                          ),
                        if ((data['selfieUrl'] ?? '').toString().isNotEmpty)
                          ActionChip(
                            avatar: const Icon(
                                Icons.photo_camera_outlined,
                                size: 16),
                            label: const Text('Live Selfie'),
                            onPressed: () => _showImage('Live Selfie',
                                data['selfieUrl'].toString()),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
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
                            child: const Text('Approve Profile'),
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

  Widget _fact(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
          ),
          Expanded(
            child: Text(value.isEmpty ? '—' : value,
                style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _DriverProfileRejectionDialog extends StatefulWidget {
  final String name;

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
