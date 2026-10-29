import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sese_core/sese_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../auth/hub_session_guard.dart';
import '../../dashboard/presentation/hub_user_wallet_card.dart';

/// Customer Directory & Emergency Lookup Console for Sese Hub.
///
/// Features:
/// 1. Directory of all registered customers with real-time search by name, phone, email, or UID.
/// 2. Verification status filtering (All, Verified KYC, Pending Review, Unverified).
/// 3. Customer Profile & Emergency Lookup Inspector:
///    - Full account details & KYC verification audit.
///    - Dedicated Emergency Contact card with direct dialler launcher.
///    - Account suspension / unsuspension administrative controls.
/// 4. Complete Historical Record:
///    - Past rides, courier deliveries, and scheduled trips stream with delivery PINs.
///    - Live wallet card and financial transaction ledger.
class CustomerManagementScreen extends StatefulWidget {
  final FirebaseFirestore? firestore;

  const CustomerManagementScreen({super.key, this.firestore});

  @override
  State<CustomerManagementScreen> createState() => _CustomerManagementScreenState();
}

class _CustomerManagementScreenState extends State<CustomerManagementScreen> {
  FirebaseFirestore get _db => widget.firestore ?? FirebaseFirestore.instance;

  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String _selectedKycFilter = 'ALL'; // ALL, VERIFIED, PENDING, UNVERIFIED

  @override
  void initState() {
    super.initState();
    ensureFreshHubIdToken();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _customersStream() {
    return _db.collection('users').where('role', isEqualTo: 'customer').snapshots();
  }

  Future<void> _toggleSuspension(String uid, String name, bool currentlySuspended) async {
    final targetState = !currentlySuspended;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(targetState ? 'Suspend Customer Account' : 'Reactivate Customer Account'),
        content: Text(
          'Are you sure you want to ${targetState ? "suspend" : "reactivate"} $name\'s account?\n\n'
          '${targetState ? "Suspended customers cannot log in, request rides, or make payments." : "Reactivating will restore full ride-hailing and wallet permissions."}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: targetState ? Colors.red.shade700 : Colors.green.shade700,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(targetState ? 'Confirm Suspend' : 'Confirm Reactivate'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await _db.collection('users').doc(uid).set(
        {
          'isSuspended': targetState,
          'suspendedAt': targetState ? FieldValue.serverTimestamp() : null,
          'suspensionReason': targetState ? 'Administrative suspension from Hub' : null,
        },
        SetOptions(merge: true),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$name\'s account has been ${targetState ? "suspended" : "reactivated"}.'),
          backgroundColor: targetState ? Colors.red.shade800 : Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      debugPrint('CustomerManagementScreen updateSuspension error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Unable to update suspension status. Please try again.'),
        ),
      );
    }
  }

  void _showCustomerInspectorModal(
    BuildContext context,
    String customerId,
    Map<String, dynamic> data,
  ) {
    final fullName = (data['fullName'] ?? data['name'] ?? 'Customer $customerId').toString();
    final phone = (data['phoneNumber'] ?? data['phoneNumberE164'] ?? data['phone'] ?? 'N/A').toString();
    final email = (data['email'] ?? 'N/A').toString();
    final photoUrl = (data['photoUrl'] ?? data['photoURL'] ?? '').toString();
    final isSuspended = data['isSuspended'] == true;
    final createdAt = _parseDate(data['createdAt']);

    // KYC Status
    final kycStatus = (data['customerVerificationStatus'] ??
            (data['isVerifiedCustomer'] == true ? 'verified' : 'unverified'))
        .toString()
        .toLowerCase();

    // Emergency Contact
    final emergency = data['emergencyContact'];
    String emergencyName = '';
    String emergencyPhone = '';
    String emergencyRel = '';
    if (emergency is Map) {
      emergencyName = (emergency['name'] ?? emergency['fullName'] ?? '').toString();
      emergencyPhone = (emergency['phone'] ?? emergency['phoneNumber'] ?? '').toString();
      emergencyRel = (emergency['relationship'] ?? '').toString();
    }
    if (emergencyName.isEmpty) {
      emergencyName = (data['emergencyContactName'] ?? '').toString();
    }
    if (emergencyPhone.isEmpty) {
      emergencyPhone = (data['emergencyContactPhone'] ?? '').toString();
    }
    if (emergencyRel.isEmpty) {
      emergencyRel = (data['emergencyContactRelationship'] ?? 'Contact').toString();
    }

    final hasEmergencyContact = emergencyPhone.isNotEmpty || emergencyName.isNotEmpty;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (sheetContext, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.90,
          maxChildSize: 0.96,
          expand: false,
          builder: (_, scrollCtrl) => ListView(
            controller: scrollCtrl,
            padding: const EdgeInsets.all(20),
            children: [
              // Header Card
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UserAvatar(photoUrl: photoUrl, displayName: fullName, radius: 36),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                fullName,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            if (kycStatus == 'verified')
                              const Icon(Icons.verified, color: Colors.blue, size: 18),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              'UID: ${customerId.length > 10 ? customerId.substring(0, 10) : customerId}...',
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, size: 14),
                              visualDensity: VisualDensity.compact,
                              tooltip: 'Copy UID',
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: customerId));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Customer UID copied to clipboard')),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isSuspended ? Colors.red.shade100 : Colors.green.shade100,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSuspended ? Colors.red.shade600 : Colors.green.shade600,
                                ),
                              ),
                              child: Text(
                                isSuspended ? 'SUSPENDED' : 'ACTIVE',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isSuspended ? Colors.red.shade900 : Colors.green.shade900,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: kycStatus == 'verified' ? Colors.blue.shade50 : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: kycStatus == 'verified' ? Colors.blue.shade400 : Colors.grey.shade400,
                                ),
                              ),
                              child: Text(
                                kycStatus.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: kycStatus == 'verified' ? Colors.blue.shade800 : Colors.grey.shade800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Account Controls Row
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: Icon(
                        isSuspended ? Icons.check_circle_outline : Icons.block,
                        color: isSuspended ? Colors.green.shade700 : Colors.red.shade700,
                      ),
                      label: Text(
                        isSuspended ? 'Reactivate Account' : 'Suspend Account',
                        style: TextStyle(
                          color: isSuspended ? Colors.green.shade700 : Colors.red.shade700,
                        ),
                      ),
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        await _toggleSuspension(customerId, fullName, isSuspended);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 🚨 Emergency Contact Card (Prominent Callout)
              Card(
                color: hasEmergencyContact ? Colors.red.shade50 : Colors.grey.shade100,
                elevation: hasEmergencyContact ? 2 : 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: hasEmergencyContact ? Colors.red.shade300 : Colors.grey.shade300,
                    width: 1.2,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.emergency,
                            color: hasEmergencyContact ? Colors.red.shade700 : Colors.grey.shade600,
                            size: 24,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Emergency Contact Information',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: hasEmergencyContact ? Colors.red.shade900 : Colors.grey.shade800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (hasEmergencyContact) ...[
                        Text(
                          'Name: $emergencyName ($emergencyRel)',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Phone: $emergencyPhone',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
                          icon: const Icon(Icons.phone_in_talk),
                          label: const Text('Call Emergency Contact Now'),
                          onPressed: () async {
                            final uri = Uri(scheme: 'tel', path: emergencyPhone);
                            if (await canLaunchUrl(uri)) await launchUrl(uri);
                          },
                        ),
                      ] else ...[
                        Text(
                          'No emergency contact registered for this customer.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade700,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Personal & Account Information Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Account & Profile Information',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const SizedBox(height: 10),
                      _detailRow(Icons.phone, 'Phone Number', phone, action: () async {
                        final uri = Uri(scheme: 'tel', path: phone);
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      }),
                      _detailRow(Icons.email, 'Email Address', email, action: () async {
                        final uri = Uri(scheme: 'mailto', path: email);
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      }),
                      if (createdAt != null)
                        _detailRow(Icons.calendar_today, 'Registered On', _formatDate(createdAt)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Live Wallet Card
              HubUserWalletCard(
                userId: customerId,
                firestore: widget.firestore,
              ),
              const SizedBox(height: 16),

              // Complete Ride & Courier History Section
              Row(
                children: [
                  const Icon(Icons.directions_car_outlined, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Trip & Delivery History',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'All orders',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Customer Trips Stream
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _db
                    .collection('trips')
                    .where('customerId', isEqualTo: customerId)
                    .limit(25)
                    .snapshots(),
                builder: (context, tripSnap) {
                  if (tripSnap.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('Failed to load trips: ${tripSnap.error}'),
                    );
                  }
                  if (tripSnap.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }

                  final trips = (tripSnap.data?.docs ?? []).toList()
                    ..sort((a, b) {
                      final at = _parseMillis(a.data()['createdAt']) ?? 0;
                      final bt = _parseMillis(b.data()['createdAt']) ?? 0;
                      return bt.compareTo(at);
                    });

                  if (trips.isEmpty) {
                    return Container(
                      padding: const EdgeInsets.all(20),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.route_outlined, size: 36, color: Colors.grey),
                          SizedBox(height: 6),
                          Text(
                            'No recorded trips or deliveries for this customer yet.',
                            style: TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        ],
                      ),
                    );
                  }

                  return Column(
                    children: trips.map((td) {
                      final t = td.data();
                      final tripId = td.id;
                      final status = (t['status'] ?? 'unknown').toString().toUpperCase();
                      final fare = (t['fareAmount'] is num) ? (t['fareAmount'] as num).toDouble() : 0.0;
                      final pickup = (t['pickupAddress'] ?? 'Pickup').toString();
                      final dropoff = (t['dropoffAddress'] ?? 'Dropoff').toString();
                      final date = _parseDate(t['createdAt']);
                      final driverName = (t['driverName'] ?? t['driver']?['name'] ?? 'Unassigned').toString();
                      final pin = (t['deliveryPin'] ?? t['order']?['deliveryPin'] ?? '').toString();

                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 5),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: _statusColor(status).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      status.replaceAll('_', ' '),
                                      style: TextStyle(
                                        color: _statusColor(status),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'ID: ${tripId.length > 8 ? tripId.substring(0, 8) : tripId}',
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Text(
                                    '₦${fare.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF10B981),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text('📍 $pickup → $dropoff', maxLines: 1, overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '🚘 Driver: $driverName',
                                      style: const TextStyle(fontSize: 12),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (pin.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.amber.shade100,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(color: Colors.amber.shade600),
                                      ),
                                      child: Text(
                                        'PIN: $pin',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.amber.shade900,
                                        ),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(width: 6),
                                  if (date != null)
                                    Text(
                                      _formatDate(date),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String val, {VoidCallback? action}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          Expanded(
            child: Text(
              val,
              style: TextStyle(
                fontSize: 13,
                color: action != null ? Colors.blue.shade700 : null,
                decoration: action != null ? TextDecoration.underline : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (action != null)
            InkWell(
              onTap: action,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.arrow_outward, size: 14, color: Colors.blue),
              ),
            ),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'COMPLETED':
        return Colors.green.shade700;
      case 'CANCELLED':
        return Colors.red.shade700;
      case 'IN_PROGRESS':
      case 'DRIVER_ARRIVED':
      case 'DRIVER_ARRIVING':
      case 'DRIVER_ACCEPTED':
        return Colors.blue.shade700;
      default:
        return Colors.amber.shade800;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customer Directory & Emergency Lookup'),
      ),
      body: Column(
        children: [
          // Search & Filter Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search customers by name, phone, email, UID...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
            ),
          ),

          // KYC Filter Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                _filterChip('ALL', 'All Customers'),
                _filterChip('VERIFIED', 'Verified KYC'),
                _filterChip('PENDING', 'Pending KYC'),
                _filterChip('UNVERIFIED', 'Unverified'),
              ],
            ),
          ),

          // Customer Directory Stream
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _customersStream(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  if (isHubSessionExpiredError(snapshot.error)) {
                    return const HubSessionExpiredView(contextLabel: 'customers');
                  }
                  return Center(child: Text('Failed to load customers: ${snapshot.error}'));
                }

                final docs = snapshot.data?.docs ?? [];
                final filtered = docs.where((doc) {
                  final data = doc.data();
                  final name = (data['fullName'] ?? data['name'] ?? '').toString().toLowerCase();
                  final phone = (data['phoneNumber'] ?? data['phoneNumberE164'] ?? '').toString().toLowerCase();
                  final email = (data['email'] ?? '').toString().toLowerCase();
                  final uid = doc.id.toLowerCase();
                  final kyc = (data['customerVerificationStatus'] ??
                          (data['isVerifiedCustomer'] == true ? 'verified' : 'unverified'))
                      .toString()
                      .toUpperCase();

                  if (_selectedKycFilter != 'ALL') {
                    if (_selectedKycFilter == 'VERIFIED' && kyc != 'VERIFIED') return false;
                    if (_selectedKycFilter == 'PENDING' && kyc != 'PENDING') return false;
                    if (_selectedKycFilter == 'UNVERIFIED' && kyc != 'UNVERIFIED') return false;
                  }

                  if (_searchQuery.isNotEmpty) {
                    return name.contains(_searchQuery) ||
                        phone.contains(_searchQuery) ||
                        email.contains(_searchQuery) ||
                        uid.contains(_searchQuery);
                  }
                  return true;
                }).toList();

                if (filtered.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person_search_outlined, size: 48, color: Colors.grey),
                        SizedBox(height: 12),
                        Text('No customers found matching criteria.', style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final doc = filtered[index];
                    final data = doc.data();
                    final customerId = doc.id;
                    final name = (data['fullName'] ?? data['name'] ?? 'Customer $customerId').toString();
                    final phone = (data['phoneNumber'] ?? data['phoneNumberE164'] ?? 'N/A').toString();
                    final email = (data['email'] ?? 'N/A').toString();
                    final photoUrl = (data['photoUrl'] ?? data['photoURL'] ?? '').toString();
                    final isSuspended = data['isSuspended'] == true;
                    final isVerified = data['isVerifiedCustomer'] == true ||
                        data['customerVerificationStatus'] == 'verified';

                    // Check emergency contact
                    final emergency = data['emergencyContact'];
                    final hasEmergency = (emergency is Map && (emergency['phone'] ?? '').toString().isNotEmpty) ||
                        (data['emergencyContactPhone'] ?? '').toString().isNotEmpty;

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: ListTile(
                        onTap: () => _showCustomerInspectorModal(context, customerId, data),
                        leading: UserAvatar(photoUrl: photoUrl, displayName: name, radius: 24),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isVerified) ...[
                              const SizedBox(width: 4),
                              const Icon(Icons.verified, size: 16, color: Colors.blue),
                            ],
                            if (isSuspended) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade100,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'SUSPENDED',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red.shade900,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 2),
                            Text('📞 $phone • ✉️ $email', maxLines: 1, overflow: TextOverflow.ellipsis),
                            if (hasEmergency) ...[
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Icon(Icons.emergency, size: 13, color: Colors.red.shade700),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Emergency contact on file',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.red.shade800,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                        trailing: const Icon(Icons.chevron_right),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String key, String label) {
    final isSelected = _selectedKycFilter == key;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (val) {
          if (val) setState(() => _selectedKycFilter = key);
        },
      ),
    );
  }

  static DateTime? _parseDate(dynamic val) {
    if (val == null) return null;
    if (val is DateTime) return val;
    if (val is int) return DateTime.fromMillisecondsSinceEpoch(val);
    if (val is String) return DateTime.tryParse(val);
    try {
      final dynamic dyn = val;
      return dyn.toDate() as DateTime?;
    } catch (_) {
      return null;
    }
  }

  static int? _parseMillis(dynamic val) {
    if (val == null) return null;
    if (val is num) return val.toInt();
    if (val is String) {
      final dt = DateTime.tryParse(val);
      if (dt != null) return dt.millisecondsSinceEpoch;
    }
    try {
      final dynamic dyn = val;
      final dt = dyn.toDate() as DateTime;
      return dt.millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  static String _formatDate(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
