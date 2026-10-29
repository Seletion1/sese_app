import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../auth/hub_session_guard.dart';

/// Driver Management Console & Real-Time Tracking for Sese Hub.
///
/// Features:
/// 1. Online / Offline / All Drivers filtering tabs with live driver counters.
/// 2. Real-time driver search by name, phone, email, or vehicle license plate.
/// 3. Profile & History Inspector: personal details, profile/selfie captures,
///    assigned vehicle details, ratings, and past ride/delivery history stream.
/// 4. Real-time Live Location Map Viewer: renders the driver's exact coordinates
///    on an interactive FlutterMap with CartoDB Voyager tiles, coordinates audit,
///    and external Google Maps deep-link navigation.
/// 5. Administrative Status Toggle: manually switch any driver between Online
///    and Offline with atomic server callable execution + Firestore fallback.
class DriverManagementScreen extends StatefulWidget {
  final FirebaseFirestore? firestore;

  const DriverManagementScreen({super.key, this.firestore});

  @override
  State<DriverManagementScreen> createState() => _DriverManagementScreenState();
}

class _DriverManagementScreenState extends State<DriverManagementScreen>
    with SingleTickerProviderStateMixin {
  FirebaseFirestore get _db => widget.firestore ?? FirebaseFirestore.instance;

  late final TabController _tabCtrl;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    ensureFreshHubIdToken();
    _tabCtrl = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _driversStream() {
    return _db.collection('drivers').snapshots();
  }

  Future<void> _toggleDriverOnlineStatus({
    required String driverId,
    required String driverName,
    required bool currentIsOnline,
  }) async {
    final targetState = !currentIsOnline;
    final actionLabel = targetState ? 'Go ONLINE' : 'Go OFFLINE';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Manual Status Override: $actionLabel'),
        content: Text(
          'Are you sure you want to manually switch $driverName to '
          '${targetState ? "ONLINE" : "OFFLINE"}?\n\n'
          'This will synchronize server availability mirrors and push a status '
          'notification to the driver\'s device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: targetState ? Colors.green.shade700 : Colors.red.shade700,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Confirm $actionLabel'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      // 1. Primary: Server callable with admin privilege and FCM dispatch
      try {
        final callable = FirebaseFunctions.instance.httpsCallable('hubSetDriverOnlineStatus');
        await callable.call<Map<String, dynamic>>({
          'driverId': driverId,
          'isOnline': targetState,
          'reason': 'Manually updated from Sese Hub Driver Console',
        });
      } catch (funcErr) {
        debugPrint('hubSetDriverOnlineStatus callable failed, falling back to direct write: $funcErr');
        // 2. Fallback: Direct Firestore merge
        await _db.collection('drivers').doc(driverId).set(
          {
            'isOnline': targetState,
            'lastSeen': FieldValue.serverTimestamp(),
            'statusManuallyToggledAt': DateTime.now().toIso8601String(),
          },
          SetOptions(merge: true),
        );
        try {
          await _db.collection('driver_status').doc(driverId).set(
            {
              'driverId': driverId,
              'isOnline': targetState,
              'status': targetState ? 'active' : 'offline',
              'updatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );
        } catch (_) {}
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$driverName is now ${targetState ? "ONLINE" : "OFFLINE"}.',
          ),
          backgroundColor: targetState ? Colors.green.shade800 : Colors.grey.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      debugPrint('DriverManagementScreen updateDriverStatus error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to update driver status. Please try again.'),
        ),
      );
    }
  }

  void _showDriverLocationMap({
    required BuildContext context,
    required String driverName,
    required double lat,
    required double lng,
    required bool isOnline,
    String? plateNumber,
    DateTime? lastUpdated,
  }) {
    showDialog(
      context: context,
      builder: (ctx) {
        final point = LatLng(lat, lng);
        return Dialog(
          insetPadding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: SizedBox(
            width: 600,
            height: 520,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.location_on,
                        color: isOnline ? Colors.green.shade700 : Colors.grey.shade700,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Live GPS: $driverName',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
                              '${plateNumber != null ? " • $plateNumber" : ""}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),

                // Interactive Map Canvas — Hub-managed tile config (same
                // `/system_config/remote_keys` chain as the ride apps: Hub
                // provider pin + Voyager retina spec), so no standalone map
                // instance is left unmanaged.
                Expanded(
                  child: ClipRRect(
                    child: StreamBuilder<GlobalMapConfig>(
                      stream: const RemoteKeysService()
                          .streamGlobalMapConfig(),
                      initialData: const GlobalMapConfig(),
                      builder: (context, snapshot) {
                        final tileUrl = (snapshot.data ??
                                const GlobalMapConfig())
                            .resolveTileUrl();
                        return FlutterMap(
                          options: MapOptions(
                            initialCenter: point,
                            initialZoom: 15.0,
                            interactionOptions: const InteractionOptions(
                              flags: InteractiveFlag.all,
                            ),
                          ),
                          children: [
                            TileLayer(
                              urlTemplate: tileUrl,
                              subdomains: const ['a', 'b', 'c', 'd'],
                              userAgentPackageName: 'com.sesetech.sese_hub',
                              retinaMode: true,
                            ),
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: point,
                              width: 64,
                              height: 64,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isOnline ? Colors.green.shade800 : Colors.grey.shade800,
                                      borderRadius: BorderRadius.circular(8),
                                      boxShadow: const [
                                        BoxShadow(color: Colors.black26, blurRadius: 4),
                                      ],
                                    ),
                                    child: Text(
                                      isOnline ? 'ONLINE' : 'LAST FIX',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Icon(
                                    Icons.directions_car_filled,
                                    size: 32,
                                    color: isOnline ? Colors.green.shade700 : Colors.grey.shade800,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                          ],
                        );
                      },
                    ),
                  ),
                ),

                // Bottom Action Bar
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      if (lastUpdated != null)
                        Text(
                          'Last fix: ${_formatTime(lastUpdated)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      const Spacer(),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('Open in Google Maps'),
                        onPressed: () async {
                          final uri = Uri.parse(
                            'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
                          );
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri, mode: LaunchMode.externalApplication);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showDriverInspectorModal(
    BuildContext context,
    String driverId,
    Map<String, dynamic> data,
  ) {
    final fullName = (data['fullName'] ?? data['name'] ?? 'Driver $driverId').toString();
    final phone = (data['phoneNumber'] ?? data['phone'] ?? 'N/A').toString();
    final email = (data['email'] ?? 'N/A').toString();
    final nin = (data['nin'] ?? data['nationalId'] ?? 'N/A').toString();
    final address = (data['address'] ?? data['residentialAddress'] ?? 'N/A').toString();
    final photoUrl = (data['photoUrl'] ?? data['profileImageUrl'] ?? data['selfieUrl'] ?? '').toString();
    final verificationStatus = (data['verificationStatus'] ?? 'pending').toString().toUpperCase();
    final isOnline = data['isOnline'] == true;
    final activePlate = (data['activePlateNumber'] ?? data['licensePlate'] ?? 'None registered').toString();
    final activeVehicle = (data['activeVehicleModel'] ?? data['vehicleModel'] ?? 'Vehicle').toString();

    // Coordinates
    final loc = data['lastLocation'];
    double? lat;
    double? lng;
    if (loc is Map) {
      lat = (loc['lat'] is num) ? (loc['lat'] as num).toDouble() : null;
      lng = (loc['lng'] is num) ? (loc['lng'] as num).toDouble() : null;
    }
    lat ??= (data['latitude'] is num) ? (data['latitude'] as num).toDouble() : null;
    lng ??= (data['longitude'] is num) ? (data['longitude'] as num).toDouble() : null;

    final createdAt = _parseDate(data['createdAt']);
    final lastSeen = _parseDate(data['lastSeen']);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (sheetContext, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.88,
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
                  UserAvatar(
                    photoUrl: photoUrl,
                    displayName: fullName,
                    radius: 36,
                  ),
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
                            if (verificationStatus == 'APPROVED' || verificationStatus == 'VERIFIED')
                              const Icon(Icons.verified, color: Colors.blue, size: 18),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Driver ID: $driverId',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isOnline ? Colors.green.shade100 : Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isOnline ? Colors.green.shade600 : Colors.grey.shade400,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircleAvatar(
                                    radius: 4,
                                    backgroundColor: isOnline ? Colors.green.shade700 : Colors.grey.shade600,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    isOnline ? 'ONLINE' : 'OFFLINE',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: isOnline ? Colors.green.shade900 : Colors.grey.shade800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.blue.shade300),
                              ),
                              child: Text(
                                verificationStatus,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue.shade800,
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

              // Quick Actions Row
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: Icon(
                        isOnline ? Icons.power_settings_new : Icons.flash_on,
                        color: isOnline ? Colors.red.shade700 : Colors.green.shade700,
                      ),
                      label: Text(
                        isOnline ? 'Set Offline' : 'Set Online',
                        style: TextStyle(
                          color: isOnline ? Colors.red.shade700 : Colors.green.shade700,
                        ),
                      ),
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        await _toggleDriverOnlineStatus(
                          driverId: driverId,
                          driverName: fullName,
                          currentIsOnline: isOnline,
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (lat != null && lng != null)
                    Expanded(
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.location_on),
                        label: const Text('Live Map'),
                        onPressed: () {
                          _showDriverLocationMap(
                            context: context,
                            driverName: fullName,
                            lat: lat!,
                            lng: lng!,
                            isOnline: isOnline,
                            plateNumber: activePlate,
                            lastUpdated: lastSeen,
                          );
                        },
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // Personal Information Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Personal & Contact Details',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const SizedBox(height: 10),
                      _detailRow(Icons.phone, 'Phone', phone, action: () async {
                        final uri = Uri(scheme: 'tel', path: phone);
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      }),
                      _detailRow(Icons.email, 'Email', email, action: () async {
                        final uri = Uri(scheme: 'mailto', path: email);
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      }),
                      _detailRow(Icons.badge, 'NIN / ID Number', nin),
                      _detailRow(Icons.home, 'Residential Address', address),
                      _detailRow(Icons.directions_car, 'Active Vehicle', '$activeVehicle ($activePlate)'),
                      if (createdAt != null)
                        _detailRow(Icons.calendar_today, 'Registered On', _formatDate(createdAt)),
                      if (lastSeen != null)
                        _detailRow(Icons.access_time, 'Last Seen / Pinged', _formatTime(lastSeen)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Past Rides & Delivery History Section
              Row(
                children: [
                  const Icon(Icons.history, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Trip & Delivery History',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const Spacer(),
                  Text(
                    'Recent trips',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Trip History Stream
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _db
                    .collection('trips')
                    .where('driverId', isEqualTo: driverId)
                    .limit(20)
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

                  final tripDocs = (tripSnap.data?.docs ?? []).toList()
                    ..sort((a, b) {
                      final at = _parseMillis(a.data()['createdAt']) ?? 0;
                      final bt = _parseMillis(b.data()['createdAt']) ?? 0;
                      return bt.compareTo(at);
                    });

                  if (tripDocs.isEmpty) {
                    return Container(
                      padding: const EdgeInsets.all(20),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          Icon(Icons.route_outlined, size: 36, color: Colors.grey.shade400),
                          const SizedBox(height: 6),
                          const Text(
                            'No recorded trips or deliveries for this driver yet.',
                            style: TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        ],
                      ),
                    );
                  }

                  return Column(
                    children: tripDocs.map((td) {
                      final t = td.data();
                      final tripId = td.id;
                      final status = (t['status'] ?? 'unknown').toString().toUpperCase();
                      final fare = (t['fareAmount'] is num) ? (t['fareAmount'] as num).toDouble() : 0.0;
                      final pickup = (t['pickupAddress'] ?? 'Pickup').toString();
                      final dropoff = (t['dropoffAddress'] ?? 'Dropoff').toString();
                      final date = _parseDate(t['createdAt']);
                      final customerName = (t['customerName'] ?? t['userName'] ?? 'Customer').toString();

                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 5),
                        child: ListTile(
                          dense: true,
                          title: Row(
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
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text('👤 $customerName • ${date != null ? _formatDate(date) : ""}'),
                              Text('📍 $pickup → $dropoff', maxLines: 1, overflow: TextOverflow.ellipsis),
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
        title: const Text('Driver Management & Live Tracking'),
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(icon: Icon(Icons.people_outline), text: 'All Drivers'),
            Tab(icon: Icon(Icons.circle, color: Colors.green, size: 12), text: 'Online Drivers'),
            Tab(icon: Icon(Icons.circle, color: Colors.grey, size: 12), text: 'Offline Drivers'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search drivers by name, phone, email, plate...',
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

          // Tab Content
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _driversStream(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  if (isHubSessionExpiredError(snapshot.error)) {
                    return const HubSessionExpiredView(contextLabel: 'drivers');
                  }
                  return Center(child: Text('Failed to load drivers: ${snapshot.error}'));
                }

                final docs = snapshot.data?.docs ?? [];
                final allDrivers = docs.map((d) => d).toList();

                // Apply search filter
                final filtered = allDrivers.where((d) {
                  if (_searchQuery.isEmpty) return true;
                  final data = d.data();
                  final name = (data['fullName'] ?? data['name'] ?? '').toString().toLowerCase();
                  final phone = (data['phoneNumber'] ?? data['phone'] ?? '').toString().toLowerCase();
                  final email = (data['email'] ?? '').toString().toLowerCase();
                  final plate = (data['activePlateNumber'] ?? data['licensePlate'] ?? '').toString().toLowerCase();
                  return name.contains(_searchQuery) ||
                      phone.contains(_searchQuery) ||
                      email.contains(_searchQuery) ||
                      plate.contains(_searchQuery);
                }).toList();

                final onlineDrivers = filtered.where((d) => d.data()['isOnline'] == true).toList();
                final offlineDrivers = filtered.where((d) => d.data()['isOnline'] != true).toList();

                return TabBarView(
                  controller: _tabCtrl,
                  children: [
                    _buildDriverList(filtered),
                    _buildDriverList(onlineDrivers, emptyMsg: 'No online drivers right now.'),
                    _buildDriverList(offlineDrivers, emptyMsg: 'No offline drivers found.'),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDriverList(List<QueryDocumentSnapshot<Map<String, dynamic>>> drivers, {String? emptyMsg}) {
    if (drivers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_off_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              emptyMsg ?? 'No drivers match your criteria.',
              style: const TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: drivers.length,
      itemBuilder: (context, index) {
        final doc = drivers[index];
        final data = doc.data();
        final driverId = doc.id;
        final name = (data['fullName'] ?? data['name'] ?? 'Driver $driverId').toString();
        final phone = (data['phoneNumber'] ?? data['phone'] ?? 'N/A').toString();
        final photoUrl = (data['photoUrl'] ?? data['profileImageUrl'] ?? '').toString();
        final isOnline = data['isOnline'] == true;
        final plate = (data['activePlateNumber'] ?? data['licensePlate'] ?? '').toString();
        final vehicleModel = (data['activeVehicleModel'] ?? data['vehicleModel'] ?? '').toString();

        // Location coordinates
        final loc = data['lastLocation'];
        double? lat;
        double? lng;
        if (loc is Map) {
          lat = (loc['lat'] is num) ? (loc['lat'] as num).toDouble() : null;
          lng = (loc['lng'] is num) ? (loc['lng'] as num).toDouble() : null;
        }

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _showDriverInspectorModal(context, driverId, data),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  UserAvatar(photoUrl: photoUrl, displayName: name, radius: 26),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Online/Offline pill
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isOnline ? Colors.green.shade50 : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isOnline ? Colors.green.shade600 : Colors.grey.shade400,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircleAvatar(
                                    radius: 3.5,
                                    backgroundColor: isOnline ? Colors.green.shade700 : Colors.grey.shade600,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    isOnline ? 'ONLINE' : 'OFFLINE',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: isOnline ? Colors.green.shade900 : Colors.grey.shade800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text('📞 $phone • ${plate.isNotEmpty ? plate : "No vehicle"}'),
                        if (vehicleModel.isNotEmpty)
                          Text(
                            '🚗 $vehicleModel',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),

                  // Actions
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (lat != null && lng != null)
                        IconButton(
                          icon: const Icon(Icons.location_on, color: Colors.blue),
                          tooltip: 'View Live Location',
                          onPressed: () {
                            _showDriverLocationMap(
                              context: context,
                              driverName: name,
                              lat: lat!,
                              lng: lng!,
                              isOnline: isOnline,
                              plateNumber: plate,
                            );
                          },
                        ),
                      IconButton(
                        icon: Icon(
                          isOnline ? Icons.toggle_on : Icons.toggle_off,
                          size: 30,
                          color: isOnline ? Colors.green.shade700 : Colors.grey,
                        ),
                        tooltip: isOnline ? 'Switch to Offline' : 'Switch to Online',
                        onPressed: () {
                          _toggleDriverOnlineStatus(
                            driverId: driverId,
                            driverName: name,
                            currentIsOnline: isOnline,
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
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

  static String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.day}/${dt.month} $h:$m';
  }
}
