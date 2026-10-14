import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../../auth/hub_session_guard.dart';
import '../../customers/presentation/customer_management_screen.dart';
import '../../dashboard/presentation/hub_module_shell.dart';
import '../../drivers/presentation/driver_management_screen.dart';
import '../../staff/services/hub_access_service.dart';
import '../services/fleet_repository.dart';
import 'customer_approvals_tab.dart';
import 'dispatch_queue_screen.dart';
import 'driver_profile_approvals_tab.dart';

/// Fleet Verification & Security Pipeline Desk: 7 sub-sections behind a
/// single-section shell (side-sheet navigation, no tab bar scrolling).
///
/// RBAC context ([permissions]/[staffRole]/[isOwner]) is optional: when
/// null (tests, direct mounts) every section shows; the dashboard always
/// passes the staffer's real grants so [HubModuleShell] filters per-section
/// (see `secFleet*` codes + [canSeeSection]).
class VehicleApprovalsScreen extends StatefulWidget {
  final FirebaseFirestore? firestore;

  /// Tolerant pending-queue source. When null, one is built around
  /// [firestore]; inject a fake in tests.
  final FleetRepository? fleetRepository;

  final List<String>? permissions;
  final UserRole? staffRole;
  final bool? isOwner;

  const VehicleApprovalsScreen({
    super.key,
    this.firestore,
    this.fleetRepository,
    this.permissions,
    this.staffRole,
    this.isOwner,
  });

  @override
  State<VehicleApprovalsScreen> createState() => _VehicleApprovalsScreenState();
}

class _VehicleApprovalsScreenState extends State<VehicleApprovalsScreen> {
  FirebaseFirestore get _db => widget.firestore ?? FirebaseFirestore.instance;

  late final FleetRepository _fleet =
      widget.fleetRepository ?? FleetRepository(widget.firestore);

  /// Cached pending-queue stream: created once in [initState] so switching
  /// tabs or re-entering the Pending Vehicles tab reuses the same active
  /// Firestore `snapshots()` listeners instead of tearing them down and
  /// wiping records from view on every rebuild.
  late final Stream<List<VehicleModel>> _pendingStream;

  @override
  void initState() {
    super.initState();
    // Force-refresh the ID token BEFORE the WatchStreams open so they never
    // start with stale credentials (UNAUTHENTICATED retry-loop fix).
    ensureFreshHubIdToken();
    _pendingStream = _fleet.pendingVehiclesStream();
  }

  /// Approves a vehicle: sets the canonical `verificationStatus` AND the
  /// legacy alias fields (`isVerified: true`, `status: 'active'`) so every
  /// sese_ride client — old or new — flips to verified live.
  ///
  /// Also marks `drivers/{driverId}.isVehicleVerified = true` and recomputes
  /// `canGoOnline` (true only when the profile is hub-approved too).
  Future<void> _approveVehicle(VehicleModel vehicle) async {
    try {
      await _db
          .collection('drivers')
          .doc(vehicle.driverId)
          .collection('vehicles')
          .doc(vehicle.id)
          .update({
        'verificationStatus': VehicleVerificationStatus.approved.toDbString(),
        'isVerified': true,
        'status': 'active',
        'updatedAt': DateTime.now().toIso8601String(),
      });
      await _db.collection('drivers').doc(vehicle.driverId).set(
        {'isVehicleVerified': true},
        SetOptions(merge: true),
      );
      await _recomputeCanGoOnline(vehicle.driverId);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Vehicle ${vehicle.displayTitle} APPROVED.'),
          backgroundColor: Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error approving vehicle: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  /// Rejects a vehicle after prompting for a mandatory reason: canonical
  /// status plus legacy aliases (`isVerified: false`, `status:
  /// 'rejected'`) for old clients, plus `rejectionReason` for the audit
  /// trail. Returns true when a rejection was recorded.
  Future<bool> _rejectVehicle(VehicleModel vehicle) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) =>
          _RejectionReasonDialog(vehicleTitle: vehicle.displayTitle),
    );
    if (reason == null || reason.isEmpty) return false;
    try {
      await _db
          .collection('drivers')
          .doc(vehicle.driverId)
          .collection('vehicles')
          .doc(vehicle.id)
          .update({
        'verificationStatus': VehicleVerificationStatus.rejected.toDbString(),
        'isVerified': false,
        'status': 'rejected',
        'rejectionReason': reason,
        'updatedAt': DateTime.now().toIso8601String(),
      });

      if (!mounted) return true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Vehicle ${vehicle.displayTitle} REJECTED.'),
          backgroundColor: Colors.red.shade800,
        ),
      );
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error rejecting vehicle: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
      return false;
    }
  }

  /// Recomputes `drivers/{driverId}.canGoOnline` from the two hub audit
  /// flags: true only when BOTH `isProfileVerified` and `isVehicleVerified`
  /// are true. Drivers cannot switch Online until both hold.
  Future<void> _recomputeCanGoOnline(String driverId) async {
    try {
      final doc = await _db.collection('drivers').doc(driverId).get();
      final data = doc.data();
      if (data == null) return;
      final canGoOnline = data['isProfileVerified'] == true &&
          data['isVehicleVerified'] == true;
      await _db.collection('drivers').doc(driverId).set(
        {'canGoOnline': canGoOnline},
        SetOptions(merge: true),
      );
    } catch (_) {}
  }

  /// Full-screen tap-to-expand viewer for any uploaded document/photo.
  void _showImageModal(String title, String imageUrl) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            InteractiveViewer(
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
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.contain,
                      loadingBuilder: (c, child, progress) =>
                          progress == null
                              ? child
                              : const Padding(
                                  padding: EdgeInsets.all(48),
                                  child: Center(
                                      child: CircularProgressIndicator()),
                                ),
                      errorBuilder: (_, _, _) => const Padding(
                        padding: EdgeInsets.all(48),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.broken_image_outlined,
                                size: 64, color: Colors.grey),
                            SizedBox(height: 12),
                            Text(
                              'Preview unavailable — open the URL directly '
                              'from the document chip.',
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      imageUrl,
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Full operational actions for every staffer who can see this desk —
    // no read-only states exist in the unified permission model.
    // Sections mirror the former 7-tab layout one-to-one (same widgets,
    // same order); the shell keeps them mounted so streams survive
    // section switches.
    bool canSee(HubModuleSection s) {
      final perms = widget.permissions;
      if (perms == null) return true;
      return canSeeSection(
        isOwner: widget.isOwner ?? false,
        role: widget.staffRole ?? UserRole.agent,
        permissions: perms,
        modulePermission: permFleetVerify,
        sectionPermission: s.permission,
      );
    }

    final firestore = widget.firestore;
    return HubModuleShell(
      title: 'Fleet Verification & Security Pipeline Desk',
      isSectionVisible: canSee,
      sections: [
        HubModuleSection(
          id: 'pending_vehicles',
          title: 'Pending Vehicle Registrations',
          icon: Icons.verified_user,
          permission: secFleetVehicles,
          child: _buildPendingVehiclesTab(),
        ),
        HubModuleSection(
          id: 'driver_directory',
          title: 'Driver Directory & Tracking',
          icon: Icons.drive_eta,
          permission: secFleetDrivers,
          child: DriverManagementScreen(firestore: firestore),
        ),
        HubModuleSection(
          id: 'customer_directory',
          title: 'Customer Directory & Lookup',
          icon: Icons.people_alt,
          permission: secFleetCustomers,
          child: CustomerManagementScreen(firestore: firestore),
        ),
        HubModuleSection(
          id: 'driver_kyc',
          title: 'Driver KYC Approvals',
          icon: Icons.person_search,
          permission: secFleetDriverKyc,
          child: DriverProfileApprovalsTab(firestore: firestore),
        ),
        HubModuleSection(
          id: 'customer_kyc',
          title: 'Customer KYC Approvals',
          icon: Icons.how_to_reg,
          permission: secFleetCustomerKyc,
          child: CustomerApprovalsTab(firestore: firestore),
        ),
        HubModuleSection(
          id: 'camera_audit',
          title: 'Pre-Online Live Camera Audit Logs',
          icon: Icons.camera_alt,
          permission: secFleetCameraAudit,
          child: _buildLiveAuditLogsTab(),
        ),
        HubModuleSection(
          id: 'dispatch_queue',
          title: 'Dispatch Queue Inspector',
          icon: Icons.monitor_heart_outlined,
          permission: secFleetDispatchQueue,
          child: DispatchQueueTab(firestore: firestore),
        ),
      ],
    );
  }

  Widget _buildPendingVehiclesTab() {
    // Tolerant queue: verificationStatus == PENDING OR isVerified == false,
    // rejected excluded — legacy-alias docs render instead of vanishing.
    // Single unified source: collectionGroup('vehicles') real-time snapshots.
    return StreamBuilder<List<VehicleModel>>(
      stream: _pendingStream,
      builder: (context, snapshot) {
        // Preserve rendered records across tab switches / re-subscribes:
        // only show the spinner on first load with no data yet.
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          if (isHubSessionExpiredError(snapshot.error)) {
            return const HubSessionExpiredView(
                contextLabel: 'pending vehicles');
          }
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 12),
                  Text('Failed to load pending vehicles: ${snapshot.error}',
                      textAlign: TextAlign.center),
                ],
              ),
            ),
          );
        }

        final pendingVehicles = snapshot.data ?? [];
        if (pendingVehicles.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline, size: 64, color: Colors.green),
                SizedBox(height: 16),
                Text('No pending vehicle registrations. All queues cleared!'),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: pendingVehicles.length,
          itemBuilder: (context, index) {
            final veh = pendingVehicles[index];
            return Card(
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor:
                              Theme.of(context).colorScheme.primaryContainer,
                          child: Icon(
                            veh.category == VehicleCategory.car
                                ? Icons.directions_car
                                : Icons.two_wheeler,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                veh.displayTitle,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              Text(
                                'Driver ID: ${veh.driverId} • Category: ${veh.category.displayName}',
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        Chip(
                          label: Text(veh.verificationStatus.displayName),
                          backgroundColor: Colors.orange.shade100,
                          labelStyle: TextStyle(
                              color: Colors.orange.shade900, fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    if (veh.category == VehicleCategory.car &&
                        veh.tier != null) ...[
                      Row(
                        children: [
                          const Text(
                            'Auto-Assigned Ride Tier: ',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Chip(
                            label: Text(
                              veh.tier!.defaultDisplayName,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            backgroundColor: veh.tier == RideTier.luxe
                                ? Colors.purple.shade100
                                : veh.tier == RideTier.premium
                                    ? Colors.blue.shade100
                                    : Colors.grey.shade200,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    _buildPlateCrossCheck(veh),
                    _buildCategoryDocuments(veh),
                    // Full operational actions: anyone who can see this desk
                    // may adjudicate — no read-only states exist.
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.close, color: Colors.red),
                          label: const Text('Reject',
                              style: TextStyle(color: Colors.red)),
                          onPressed: () => _rejectVehicle(veh),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          icon: const Icon(Icons.check),
                          label: const Text('Approve Vehicle'),
                          style: FilledButton.styleFrom(
                              backgroundColor: Colors.green.shade800),
                          onPressed: () => _approveVehicle(veh),
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

  /// Plate ↔ Vehicle License cross-check banner. Bicycles carry no
  /// plate, so the banner is skipped for them.
  Widget _buildPlateCrossCheck(VehicleModel veh) {
    final req = VehicleDocumentRequirements.forCategory(veh.category);
    if (!req.requiresLicensePlate) return const SizedBox.shrink();
    String? licenseUrl;
    for (final slot in req.documents) {
      if (slot.key == 'vehicle_license') {
        licenseUrl = veh.documents[slot.label];
        break;
      }
    }
    licenseUrl ??= veh.documents['Vehicle License'];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.teal.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      // Text keeps word-wrap (softWrap) so a narrow phone never stacks it
      // letter-by-letter beside the trailing action.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.fact_check_outlined, color: Colors.teal.shade800),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Plate entered: ${veh.licensePlate.isEmpty ? '—' : veh.licensePlate}',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.teal.shade900),
                  softWrap: true,
                ),
                const Text(
                  'Cross-check against the Vehicle License photo before approving.',
                  style: TextStyle(fontSize: 11, color: Colors.black54),
                  softWrap: true,
                ),
              ],
            ),
          ),
          if (licenseUrl != null && licenseUrl.isNotEmpty)
            Flexible(
              child: TextButton(
                onPressed: () =>
                    _showImageModal('Vehicle License — ${veh.licensePlate}',
                        licenseUrl!),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text(
                  'View License',
                  softWrap: false,
                  overflow: TextOverflow.visible,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Category-aware document preview: ownership/paperwork section first
  /// (Proof of Ownership & Gov ID for bicycles; License & Insurance for
  /// motor vehicles), then the required inspection angles, then any
  /// extra uploads, then missing-slot warnings.
  Widget _buildCategoryDocuments(VehicleModel veh) {
    final req = VehicleDocumentRequirements.forCategory(veh.category);
    final docs = veh.documents;
    final inspectionLabels =
        req.inspections.map((s) => s.label).toSet();
    final ownershipEntries = <MapEntry<String, String>>[];
    final inspectionEntries = <MapEntry<String, String>>[];
    final extraEntries = <MapEntry<String, String>>[];
    for (final e in docs.entries) {
      if (inspectionLabels.contains(e.key)) {
        inspectionEntries.add(e);
      } else if (req.documents.any((s) => s.label == e.key)) {
        ownershipEntries.add(e);
      } else {
        extraEntries.add(e);
      }
    }
    final missing = req.slots
        .where((s) => !docs.containsKey(s.label))
        .map((s) => s.label)
        .toList();

    Widget sectionTitle(String title) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(title,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        );

    Widget docWrap(List<MapEntry<String, String>> entries) => Wrap(
          spacing: 8,
          runSpacing: 6,
          children: entries.map((e) {
            return ActionChip(
              avatar: const Icon(Icons.image_outlined, size: 16),
              label: Text(e.key),
              onPressed: () => _showImageModal(
                  '${veh.displayTitle} — ${e.key}', e.value),
            );
          }).toList(),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sectionTitle(
          veh.category == VehicleCategory.bicycle
              ? 'Proof of Ownership & ID:'
              : 'Licenses & Certificates:',
        ),
        if (ownershipEntries.isEmpty)
          const Text('No ownership documents uploaded.',
              style: TextStyle(color: Colors.grey, fontSize: 12))
        else
          docWrap(ownershipEntries),
        const SizedBox(height: 10),
        sectionTitle(
          'Inspection Photos '
          '(${inspectionEntries.length}/${req.inspections.length} required):',
        ),
        if (inspectionEntries.isEmpty)
          const Text('No inspection photos uploaded.',
              style: TextStyle(color: Colors.grey, fontSize: 12))
        else
          docWrap(inspectionEntries),
        if (extraEntries.isNotEmpty) ...[
          const SizedBox(height: 10),
          sectionTitle('Additional Uploads:'),
          docWrap(extraEntries),
        ],
        if (missing.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: missing
                .map((m) => Chip(
                      avatar: const Icon(Icons.warning_amber_outlined,
                          size: 16, color: Colors.red),
                      label: Text('Missing: $m',
                          style: const TextStyle(fontSize: 11)),
                      backgroundColor: Colors.red.shade50,
                    ))
                .toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildLiveAuditLogsTab() {
    FirebaseFirestore? db;
    try {
      db = _db;
    } catch (_) {
      db = null;
    }
    if (db == null) {
      return const Center(child: Text('Firestore unavailable.'));
    }
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db
          .collection('driver_vehicle_verification')
          .orderBy('capturedAt', descending: true)
          .limit(50)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          if (isHubSessionExpiredError(snapshot.error)) {
            return const HubSessionExpiredView(contextLabel: 'audit logs');
          }
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Failed to load audit logs: ${snapshot.error}'),
            ),
          );
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Center(
            child: Text('No pre-online verification logs recorded yet.'),
          );
        }

        final auditLogs = docs
            .map((d) => VehicleVerificationRecord.fromMap(d.data(), id: d.id))
            .toList();

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: auditLogs.length,
          itemBuilder: (context, index) {
            final log = auditLogs[index];
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Colors.blueAccent,
                  child: Icon(Icons.camera_alt, color: Colors.white),
                ),
                title: Text(
                    'Verification ${log.id} • Plate: ${log.licensePlateDetected ?? "N/A"}'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Driver: ${log.driverId} • Vehicle: ${log.vehicleId}'),
                    Text('Mode: ${log.captureMode} (Enforced live camera)'),
                    if (log.auditNotes != null) Text('Notes: ${log.auditNotes}'),
                    Text('Captured: ${log.capturedAt.toLocal()}'),
                  ],
                ),
                trailing: Chip(
                  label: Text(log.status.toUpperCase()),
                  backgroundColor: Colors.green.shade100,
                  labelStyle: TextStyle(color: Colors.green.shade900),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Rejection-reason prompt. Owns its [TextEditingController] so disposal
/// happens with the route (after the exit animation) — disposing it from
/// the caller right after pop would break the still-mounted TextField and
/// poison subsequent frames.
class _RejectionReasonDialog extends StatefulWidget {
  final String vehicleTitle;

  const _RejectionReasonDialog({required this.vehicleTitle});

  @override
  State<_RejectionReasonDialog> createState() => _RejectionReasonDialogState();
}

class _RejectionReasonDialogState extends State<_RejectionReasonDialog> {
  final _reasonCtrl = TextEditingController();

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reject Vehicle'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.vehicleTitle,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reasonCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Rejection reason (required)',
              hintText: 'e.g. Plate number unreadable in photos',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
          onPressed: () {
            final r = _reasonCtrl.text.trim();
            if (r.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('A rejection reason is required.')),
              );
              return;
            }
            Navigator.pop(context, r);
          },
          child: const Text('Confirm Reject'),
        ),
      ],
    );
  }
}
