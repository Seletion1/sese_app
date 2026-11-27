import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sese_core/sese_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../dashboard/presentation/hub_module_shell.dart';
import '../../staff/services/hub_access_service.dart';

/// Multi-Level Active Ride & Scheduled Booking Console with Security PIN Support.
///
/// Features:
/// 1. Comprehensive Stream: all active rides (`requested`, `bidding`, `accepted`,
///    `arrived`, `in_transit`, `DRIVER_ACCEPTED`, `DRIVER_ARRIVING`, `DRIVER_ARRIVED`,
///    `IN_PROGRESS`) PLUS scheduled rides/deliveries (`scheduled`, `SCHEDULED`, `WAITING_FOR_SCHEDULED`).
/// 2. Hierarchical Geographical Filtering: Country -> State/Zone cascade.
/// 3. Robust Sorting & Stage Filtering:
///    - Filter by Status: All Active & Scheduled, Scheduled Only, Searching/Bidding, En Route/Arrived, In Transit.
///    - Sort by: Creation Date (Newest/Oldest), Scheduled Time, Fare (High/Low).
///    - Search: Trip ID, Customer Name, Phone, Customer ID, Driver Name/Phone.
/// 4. Trip Inspection & Security PIN Support:
///    - Prominently displays the 4-digit Security/Delivery PIN with one-tap copy.
///    - Hotline operator assistance guidance for providing PIN to drivers over the phone when customer is unreachable.
///    - Customer and Driver contact diallers (`url_launcher` with `tel:`).
///    - Dispute overrides: "Force Complete Trip", "Remove Trip & Refund Customer", "Manual PIN Bypass".
class ActiveRidesConsoleScreen extends StatelessWidget {
  final FirebaseFirestore? firestore;

  /// RBAC context for per-section gating (null = no gate: tests, previews).
  final List<String>? permissions;
  final UserRole? staffRole;
  final bool? isOwner;

  /// Jurisdiction lock (`global`/null/ALL = free filter). When set to a
  /// country code, both sections force that country and disable the country
  /// dropdown — staff only ever see their authorized jurisdiction.
  final String? lockedCountry;

  const ActiveRidesConsoleScreen({
    super.key,
    this.firestore,
    this.permissions,
    this.staffRole,
    this.isOwner,
    this.lockedCountry,
  });

  @override
  Widget build(BuildContext context) {
    bool canSee(HubModuleSection s) {
      final perms = permissions;
      if (perms == null) return true;
      return canSeeSection(
        isOwner: isOwner ?? false,
        role: staffRole ?? UserRole.agent,
        permissions: perms,
        modulePermission: permActiveRides,
        sectionPermission: s.permission,
      );
    }

    final db = firestore;
    return HubModuleShell(
      title: 'Active Rides & Scheduled Booking Console',
      isSectionVisible: canSee,
      sections: [
        HubModuleSection(
          id: 'live',
          title: 'Live Rides',
          icon: Icons.car_rental,
          permission: secRidesLive,
          child: _RidesConsoleBody(
            firestore: db,
            stageLock: 'live',
            lockedCountry: lockedCountry,
          ),
        ),
        HubModuleSection(
          id: 'scheduled',
          title: 'Scheduled Bookings',
          icon: Icons.calendar_month,
          permission: secRidesScheduled,
          child: _RidesConsoleBody(
            firestore: db,
            stageLock: 'scheduled',
            lockedCountry: lockedCountry,
          ),
        ),
      ],
    );
  }
}

/// The live console body (filter bar + trip stream + inspector cards),
/// shared by both shell sections. [stageLock] pins the stage filter
/// (`live` excludes scheduled trips, `scheduled` shows only them) and hides
/// the stage chips; [lockedCountry] forces the country filter and disables
/// the country dropdown for jurisdiction-scoped staff.
class _RidesConsoleBody extends StatefulWidget {
  final FirebaseFirestore? firestore;
  final String? stageLock;
  final String? lockedCountry;

  const _RidesConsoleBody({
    this.firestore,
    this.stageLock,
    this.lockedCountry,
  });

  @override
  State<_RidesConsoleBody> createState() => _RidesConsoleBodyState();
}

class _RidesConsoleBodyState extends State<_RidesConsoleBody> {
  FirebaseFirestore get _db => widget.firestore ?? FirebaseFirestore.instance;

  Stream<QuerySnapshot<Map<String, dynamic>>> _activeTripsStream() {
    try {
      return _db
          .collection('trips')
          .where('status', whereIn: _activeStatuses)
          .snapshots();
    } catch (_) {
      return const Stream.empty();
    }
  }

  /// Non-null when the staffer's jurisdiction is locked (not global/ALL).
  String? get _locked =>
      (widget.lockedCountry ?? '').trim().toUpperCase().isNotEmpty &&
              widget.lockedCountry!.trim().toUpperCase() != 'ALL' &&
              normalizeCountryScope(widget.lockedCountry) !=
                  countryScopeGlobal
          ? normalizeCountryScope(widget.lockedCountry)
          : null;

  late String _selectedCountry;
  String _selectedState = 'ALL';
  late String _selectedStageFilter;
  String _selectedSort = 'NEWEST'; // NEWEST, OLDEST, SCHEDULED_TIME, FARE_HIGH, FARE_LOW
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _selectedCountry = _locked ?? 'NG';
    _selectedStageFilter =
        widget.stageLock == 'scheduled' ? 'SCHEDULED' : 'ALL';
  }

  final _searchCtrl = TextEditingController();
  final Map<String, String> _memberIdCache = {};

  static const List<String> _activeStatuses = [
    'requested',
    'bidding',
    'accepted',
    'arrived',
    'in_transit',
    'pending_split_consent',
    'scheduled',
    'SCHEDULED',
    'SEARCHING_DRIVER',
    'WAITING_FOR_ACCEPTANCE',
    'DRIVER_ACCEPTED',
    'DRIVER_ARRIVING',
    'DRIVER_ARRIVED',
    'IN_PROGRESS',
    'pending_customer_approval',
    'PENDING_CUSTOMER_APPROVAL',
    'WAITING_FOR_SCHEDULED',
  ];

  List<String> _currentStateOptions() {
    if (_selectedCountry == 'ALL') {
      final all = <String>{};
      for (final c in SeseCountryCatalog.allCountries) {
        all.addAll(statesForCountry(c.countryCode));
      }
      final sorted = all.toList()..sort();
      return ['ALL', ...sorted];
    }
    return ['ALL', ...statesForCountry(_selectedCountry)];
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Shell owns the AppBar (streams are live; the manual refresh button
    // was redundant and is dropped). Jurisdiction lock notice renders above
    // the filters when this staffer is country-scoped.
    return Column(
      children: [
        // Filter & Search Bar
        _buildFilterBar(),

          // Active & Scheduled Trips Stream
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _activeTripsStream(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Error loading active/scheduled rides: ${snapshot.error}'),
                  );
                }
                if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
                  return const SeseListSkeleton(itemCount: 6);
                }

                final docs = snapshot.data?.docs ?? [];
                final filtered = docs.where((doc) {
                  final data = doc.data();
                  final pickupCountry = (data['pickupCountryCode'] ?? data['countryCode'] ?? 'NG').toString().toUpperCase();
                  final pickupState = (data['pickupState'] ?? data['stateOrRegion'] ?? '').toString().toUpperCase();
                  final tripId = doc.id.toLowerCase();
                  final customerName = (data['customerName'] ?? data['userName'] ?? '').toString().toLowerCase();
                  final customerPhone = (data['customerPhone'] ?? data['phoneNumber'] ?? '').toString().toLowerCase();
                  final customerId = (data['customerId'] ?? '').toString().toLowerCase();
                  final driverName = (data['driverName'] ?? data['driver']?['name'] ?? '').toString().toLowerCase();
                  final driverPhone = (data['driverPhone'] ?? '').toString().toLowerCase();
                  final status = (data['status'] ?? '').toString().toLowerCase();
                  final isScheduled = data['isScheduled'] == true || status.contains('scheduled');

                  // Country & State filters
                  if (_selectedCountry != 'ALL' && pickupCountry != _selectedCountry) {
                    return false;
                  }
                  if (_selectedState != 'ALL' && !pickupState.contains(_selectedState.toUpperCase())) {
                    return false;
                  }

                  // Stage Filter (plus shell section lock: the Live section
                  // never shows scheduled trips even on 'ALL').
                  if (widget.stageLock == 'live' && isScheduled) return false;
                  if (_selectedStageFilter == 'SCHEDULED' && !isScheduled) return false;
                  if (_selectedStageFilter == 'SEARCHING' &&
                      !(status == 'requested' || status == 'bidding' || status == 'searching_driver' || status == 'waiting_for_acceptance')) {
                    return false;
                  }
                  if (_selectedStageFilter == 'EN_ROUTE' &&
                      !(status == 'accepted' || status == 'arrived' || status == 'driver_accepted' || status == 'driver_arriving' || status == 'driver_arrived')) {
                    return false;
                  }
                  if (_selectedStageFilter == 'IN_TRANSIT' &&
                      !(status == 'in_transit' || status == 'in_progress' || status == 'pending_customer_approval')) {
                    return false;
                  }

                  // Search Query Filter
                  if (_searchQuery.isNotEmpty) {
                    final q = _searchQuery.toLowerCase();
                    return tripId.contains(q) ||
                        customerName.contains(q) ||
                        customerPhone.contains(q) ||
                        customerId.contains(q) ||
                        driverName.contains(q) ||
                        driverPhone.contains(q);
                  }
                  return true;
                }).toList();

                // Sort docs
                filtered.sort((a, b) {
                  final dataA = a.data();
                  final dataB = b.data();

                  switch (_selectedSort) {
                    case 'OLDEST':
                      final at = _parseMillis(dataA['createdAt']) ?? 0;
                      final bt = _parseMillis(dataB['createdAt']) ?? 0;
                      return at.compareTo(bt);
                    case 'SCHEDULED_TIME':
                      final at = _parseMillis(dataA['scheduledPickupTime'] ?? dataA['scheduledAt']) ?? 0;
                      final bt = _parseMillis(dataB['scheduledPickupTime'] ?? dataB['scheduledAt']) ?? 0;
                      return bt.compareTo(at);
                    case 'FARE_HIGH':
                      final af = (dataA['fareAmount'] is num) ? (dataA['fareAmount'] as num).toDouble() : 0.0;
                      final bf = (dataB['fareAmount'] is num) ? (dataB['fareAmount'] as num).toDouble() : 0.0;
                      return bf.compareTo(af);
                    case 'FARE_LOW':
                      final af = (dataA['fareAmount'] is num) ? (dataA['fareAmount'] as num).toDouble() : 0.0;
                      final bf = (dataB['fareAmount'] is num) ? (dataB['fareAmount'] as num).toDouble() : 0.0;
                      return af.compareTo(bf);
                    case 'NEWEST':
                    default:
                      final at = _parseMillis(dataA['updatedAt'] ?? dataA['createdAt']) ?? 0;
                      final bt = _parseMillis(dataB['updatedAt'] ?? dataB['createdAt']) ?? 0;
                      return bt.compareTo(at);
                  }
                });

                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.car_rental, size: 48, color: Colors.grey),
                        const SizedBox(height: 12),
                        Text(
                          'No active or scheduled rides matching scope: $_selectedCountry / $_selectedState',
                          style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final doc = filtered[index];
                    return _buildTripCard(context, doc.id, doc.data());
                  },
                );
              },
            ),
          ),
        ],
      );
  }

  Widget _buildFilterBar() {
    final countryCatalog = SeseCountryCatalog.allCountries;
    final stateOptions = _currentStateOptions();

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              // Country Selector
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedCountry,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Country',
                    helperText: _locked == null
                        ? null
                        : 'Locked to your jurisdiction ($_locked)',
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  selectedItemBuilder: (context) => [
                    const Text('🌐 ALL', overflow: TextOverflow.ellipsis),
                    for (final c in countryCatalog)
                      Text('${c.flagEmoji} ${c.countryCode}', overflow: TextOverflow.ellipsis),
                  ],
                  items: [
                    const DropdownMenuItem(
                      value: 'ALL',
                      child: Text('🌐 All Countries', overflow: TextOverflow.ellipsis),
                    ),
                    for (final c in countryCatalog)
                      DropdownMenuItem(
                        value: c.countryCode,
                        child: Text('${c.flagEmoji} ${c.countryName} (${c.countryCode})',
                            overflow: TextOverflow.ellipsis),
                      ),
                    // Locked jurisdiction outside the catalog still needs a
                    // matching item or the dropdown throws.
                    if (_locked != null &&
                        _locked != 'ALL' &&
                        countryCatalog.every(
                            (c) => c.countryCode != _locked))
                      DropdownMenuItem(
                        value: _locked,
                        child: Text('$_locked',
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: _locked == null
                      ? (val) {
                          if (val != null) {
                            setState(() {
                              _selectedCountry = val;
                              _selectedState = 'ALL';
                            });
                          }
                        }
                      : null,
                ),
              ),
              const SizedBox(width: 8),

              // State / Region Selector
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: stateOptions.contains(_selectedState) ? _selectedState : 'ALL',
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'State / Zone',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  selectedItemBuilder: (context) => [
                    for (final s in stateOptions)
                      Text(s == 'ALL' ? '📍 All' : s, overflow: TextOverflow.ellipsis),
                  ],
                  items: [
                    for (final s in stateOptions)
                      DropdownMenuItem(
                        value: s,
                        child: Text(s == 'ALL' ? '📍 All States' : s, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (val) {
                    if (val != null) setState(() => _selectedState = val);
                  },
                ),
              ),
              const SizedBox(width: 8),

              // Sort Dropdown
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedSort,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Sort By',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'NEWEST', child: Text('Newest First')),
                    DropdownMenuItem(value: 'OLDEST', child: Text('Oldest First')),
                    DropdownMenuItem(value: 'SCHEDULED_TIME', child: Text('Scheduled Time')),
                    DropdownMenuItem(value: 'FARE_HIGH', child: Text('Fare: High → Low')),
                    DropdownMenuItem(value: 'FARE_LOW', child: Text('Fare: Low → High')),
                  ],
                  onChanged: (val) {
                    if (val != null) setState(() => _selectedSort = val);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Search Field & Stage Filter Chips
          TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search by Customer ID, Trip ID, Name, Phone...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (val) => setState(() => _searchQuery = val.trim()),
          ),
          const SizedBox(height: 6),

          // Stage Chips — hidden when the shell section pins the stage
          // (Live vs Scheduled side-sheet navigation owns it instead).
          if (widget.stageLock == null)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _stageChip('ALL', 'All Active & Scheduled'),
                  _stageChip('SCHEDULED', '📅 Scheduled Only'),
                  _stageChip('SEARCHING', '🔍 Searching/Bidding'),
                  _stageChip('EN_ROUTE', '🚗 En Route/Arrived'),
                  _stageChip('IN_TRANSIT', '🚀 In Transit'),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _stageChip(String key, String label) {
    final isSelected = _selectedStageFilter == key;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label),
        selected: isSelected,
        visualDensity: VisualDensity.compact,
        onSelected: (val) {
          if (val) setState(() => _selectedStageFilter = key);
        },
      ),
    );
  }

  Widget _buildTripCard(BuildContext context, String tripId, Map<String, dynamic> data) {
    final status = (data['status'] ?? 'unknown').toString();
    final baseFare = (data['base_trip_fare'] is num)
        ? (data['base_trip_fare'] as num).toDouble()
        : (data['baseFare'] is num)
            ? (data['baseFare'] as num).toDouble()
            : (data['fareAmount'] is num)
                ? (data['fareAmount'] as num).toDouble()
                : 0.0;
    final debt = (data['outstanding_debt'] is num)
        ? (data['outstanding_debt'] as num).toDouble()
        : (data['outstandingDebt'] is num)
            ? (data['outstandingDebt'] as num).toDouble()
            : (data['recoveredDebt'] is num)
                ? (data['recoveredDebt'] as num).toDouble()
                : 0.0;
    final totalCollectible = (data['total_collectible_fare'] is num)
        ? (data['total_collectible_fare'] as num).toDouble()
        : (baseFare + debt);
    final customerId = (data['customerId'] ?? data['userId'] ?? '').toString().trim();
    final customerSeqId = (data['customerSequentialId'] ??
            data['tripBooker']?['sequentialId'] ??
            data['sequentialId'] ??
            '')
        .toString()
        .trim();
    final customerName = (data['customerName'] ?? data['userName'] ?? 'Customer').toString();

    final driverMap = data['driver'] is Map ? Map<String, dynamic>.from(data['driver'] as Map) : const <String, dynamic>{};
    final driverId = (data['driverId'] ?? driverMap['driverId'] ?? '').toString().trim();
    final driverSeqId = (data['driverSequentialId'] ?? driverMap['sequentialId'] ?? '').toString().trim();
    final rawDriverName = (data['driverName'] ?? driverMap['fullName'] ?? driverMap['name'] ?? '').toString().trim();
    final bool hasAssignedDriver = driverId.isNotEmpty;
    final driverName = rawDriverName.isNotEmpty ? rawDriverName : (hasAssignedDriver ? 'Assigned Driver' : 'Unassigned');

    final isSplit = data['isSplitPayment'] == true || data['paymentSplit'] != null;
    final requirePin = data['deliveryPinRequired'] == true || data['requireDeliveryPin'] == true || data['forceDeliveryPinSystemWide'] == true;
    final isPinVerified = data['deliveryPinVerified'] == true || data['deliveryPinSkipped'] == true;
    final isScheduled = data['isScheduled'] == true || status.toLowerCase().contains('scheduled');
    final scheduledDate = _parseDate(data['scheduledPickupTime'] ?? data['scheduledAt']);
    final pickup = (data['pickupAddress'] ?? 'Pickup').toString();
    final dropoff = (data['dropoffAddress'] ?? 'Dropoff').toString();

    final upperStatus = status.toUpperCase();
    final bool isDriverAcceptedWithoutDriver =
        !hasAssignedDriver && (upperStatus == 'DRIVER_ACCEPTED' || upperStatus == 'ACCEPTED');
    final String effectiveStatusLabel = isDriverAcceptedWithoutDriver
        ? 'AWAITING DRIVER'
        : upperStatus.replaceAll('_', ' ');

    final isClosedOrActive = status.toLowerCase().contains('completed') ||
        status.toLowerCase().contains('transit') ||
        status.toLowerCase().contains('progress') ||
        status.toLowerCase().contains('approval') ||
        (hasAssignedDriver && (status.toLowerCase().contains('accepted') || status.toLowerCase().contains('arrived')));
    final cancelSource = (data['cancellationSource'] ?? '').toString();
    final bool isSkippedByDriver = cancelSource == 'skipped_by_driver' && !isClosedOrActive;
    final bool isRejectedByDriver = cancelSource == 'rejected_by_driver' && !isClosedOrActive;
    final bool canReassign = !upperStatus.contains('COMPLETED') && !upperStatus.contains('CANCELLED');

    Color statusColor = Colors.orange;
    if (status.toLowerCase().contains('completed')) statusColor = Colors.green;
    if (status.toLowerCase().contains('transit') || status.toLowerCase().contains('progress')) statusColor = Colors.blue;
    if (status.toLowerCase().contains('approval')) statusColor = const Color(0xFFD97706);
    if (isSkippedByDriver || isRejectedByDriver) {
      statusColor = Colors.amber.shade900;
    } else if (status.toLowerCase().contains('cancel')) {
      statusColor = Colors.red;
    }
    if (isScheduled) statusColor = Colors.deepPurple;

    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isSkippedByDriver
                        ? 'SKIPPED BY DRIVER'
                        : isRejectedByDriver
                            ? 'REJECTED BY DRIVER'
                            : isScheduled && !upperStatus.contains('SCHEDULED')
                                ? 'SCHEDULED ($effectiveStatusLabel)'
                                : effectiveStatusLabel,
                    style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'ID: ${tripId.length > 12 ? tripId.substring(0, 12) : tripId}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '₦${(debt > 0 ? totalCollectible : baseFare).toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF10B981)),
                    ),
                    if (debt > 0)
                      Text(
                        'Base ₦${baseFare.toStringAsFixed(0)} + Debt ₦${debt.toStringAsFixed(0)}',
                        style: const TextStyle(fontSize: 10, color: Colors.deepOrange, fontWeight: FontWeight.w600),
                      ),
                  ],
                ),
              ],
            ),
            const Divider(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text('👤 Customer: $customerName', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          ),
                          if (customerId.isNotEmpty)
                            _MemberIdBadge(
                              uid: customerId,
                              initialId: customerSeqId,
                              cache: _memberIdCache,
                              db: _db,
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: Text('🚘 Driver: $driverName', style: const TextStyle(fontSize: 13)),
                          ),
                          if (hasAssignedDriver)
                            _MemberIdBadge(
                              uid: driverId,
                              initialId: driverSeqId,
                              isDriver: true,
                              cache: _memberIdCache,
                              db: _db,
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('📍 $pickup → $dropoff', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      if (isScheduled && scheduledDate != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.alarm, size: 13, color: Colors.deepPurple),
                              const SizedBox(width: 4),
                              Text(
                                'Scheduled for: ${_formatDateTime(scheduledDate)}',
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.deepPurple),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                // Prominent Delivery PIN Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: isPinVerified
                        ? Colors.green.shade100
                        : (requirePin ? Colors.amber.shade100 : Colors.grey.shade200),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isPinVerified
                          ? Colors.green.shade700
                          : (requirePin ? Colors.amber.shade700 : Colors.grey.shade400),
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.lock,
                            size: 14,
                            color: isPinVerified
                                ? Colors.green.shade900
                                : (requirePin ? Colors.amber.shade900 : Colors.grey.shade700),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isPinVerified
                                ? 'VERIFIED'
                                : (requirePin ? 'PIN REQ' : 'PIN OFF'),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                              color: isPinVerified
                                  ? Colors.green.shade900
                                  : (requirePin ? Colors.amber.shade900 : Colors.grey.shade700),
                            ),
                          ),
                        ],
                      ),
                      const Text('SECURITY PIN', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.brown)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (isSplit)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.purple.shade50, borderRadius: BorderRadius.circular(4)),
                    child: Text('SPLIT PAYMENT', style: TextStyle(fontSize: 10, color: Colors.purple.shade800, fontWeight: FontWeight.bold)),
                  ),
                const Spacer(),
                if (canReassign) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.swap_horiz, size: 16),
                    onPressed: () => _showReassignDriverModal(context, tripId, data),
                    label: const Text('Re-assign'),
                  ),
                  const SizedBox(width: 8),
                ],
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.shield_outlined, size: 16),
                  onPressed: () => _showTripInspectionModal(context, tripId, data),
                  label: const Text('Inspect & PIN Support'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showTripInspectionModal(BuildContext context, String tripId, Map<String, dynamic> data) {
    final customerName = (data['customerName'] ?? data['userName'] ?? 'Customer').toString();
    final customerPhone = (data['customerPhone'] ?? data['phoneNumber'] ?? 'N/A').toString();
    final customerId = (data['customerId'] ?? data['userId'] ?? '').toString().trim();
    final customerSeqId = (data['customerSequentialId'] ??
            data['tripBooker']?['sequentialId'] ??
            data['sequentialId'] ??
            '')
        .toString()
        .trim();

    final driverMap = data['driver'] is Map ? Map<String, dynamic>.from(data['driver'] as Map) : const <String, dynamic>{};
    final driverId = (data['driverId'] ?? driverMap['driverId'] ?? '').toString().trim();
    final driverSeqId = (data['driverSequentialId'] ?? driverMap['sequentialId'] ?? '').toString().trim();
    final rawDriverName = (data['driverName'] ?? driverMap['fullName'] ?? driverMap['name'] ?? '').toString().trim();
    final bool hasAssignedDriver = driverId.isNotEmpty;
    final driverName = rawDriverName.isNotEmpty ? rawDriverName : (hasAssignedDriver ? 'Assigned Driver' : 'Unassigned');
    final rawDriverPhone = (data['driverPhone'] ?? driverMap['phone'] ?? driverMap['phoneNumber'] ?? '').toString().trim();
    final driverPhone = rawDriverPhone.isNotEmpty ? rawDriverPhone : 'N/A';
    final rawVehiclePlate = (data['vehiclePlate'] ?? driverMap['plateNumber'] ?? driverMap['licensePlate'] ?? data['licensePlate'] ?? '').toString().trim();
    final vehiclePlate = rawVehiclePlate.isNotEmpty ? rawVehiclePlate : 'N/A';
    final upperStatus = (data['status'] ?? '').toString().toUpperCase();
    final bool canReassign = !upperStatus.contains('COMPLETED') && !upperStatus.contains('CANCELLED');
    final requirePin = data['deliveryPinRequired'] == true || data['requireDeliveryPin'] == true || data['forceDeliveryPinSystemWide'] == true;
    final isPinVerified = data['deliveryPinVerified'] == true || data['deliveryPinSkipped'] == true;
    final isScheduled = data['isScheduled'] == true || (data['status'] ?? '').toString().toLowerCase().contains('scheduled');
    final scheduledDate = _parseDate(data['scheduledPickupTime'] ?? data['scheduledAt']);
    final pickup = (data['pickupAddress'] ?? 'Pickup address').toString();
    final dropoff = (data['dropoffAddress'] ?? 'Dropoff address').toString();

    final isSplit = data['isSplitPayment'] == true || data['paymentSplit'] != null;
    final senderShare = (data['senderShareNaira'] is num) ? (data['senderShareNaira'] as num).toDouble() : 0.0;
    final receiverShare = (data['receiverShareNaira'] is num) ? (data['receiverShareNaira'] as num).toDouble() : 0.0;
    final senderMethod = (data['senderPaymentMethod'] ?? data['paymentMethod'] ?? 'cash').toString();
    final receiverMethod = (data['receiverPaymentMethod'] ?? 'cash').toString();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.90,
          maxChildSize: 0.96,
          expand: false,
          builder: (_, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.all(20),
            children: [
              Text('Live Trip Inspection Audit: $tripId', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),

              // 🌟 PROMINENT SECURITY / DELIVERY PIN SUPPORT CARD
              Card(
                color: Colors.amber.shade50,
                elevation: 3,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: Colors.amber.shade600, width: 1.5),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.security, size: 28, color: Colors.amber.shade900),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '4-Digit Security / Delivery PIN Gate',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                                const SizedBox(height: 2),
                                if (!requirePin)
                                  Text(
                                    'PIN Protection is not required for this trip.',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey.shade700,
                                    ),
                                  )
                                else
                                  FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                                    future: _db.collection('delivery_pins').doc(tripId).get(),
                                    builder: (context, snapshot) {
                                      final pin = (snapshot.data?.data()?['pin'] ?? '').toString();
                                      final pinDisplay = pin.isNotEmpty ? pin : (snapshot.connectionState == ConnectionState.waiting ? 'Loading...' : 'None');
                                      return Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              'CUSTOMER PIN: $pinDisplay${isPinVerified ? ' (VERIFIED)' : ''}',
                                              style: TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                                letterSpacing: 1.5,
                                                color: isPinVerified ? Colors.green.shade900 : Colors.amber.shade900,
                                              ),
                                            ),
                                          ),
                                          if (pin.isNotEmpty)
                                            IconButton.filledTonal(
                                              icon: const Icon(Icons.copy),
                                              tooltip: 'Copy Security PIN',
                                              onPressed: () {
                                                Clipboard.setData(ClipboardData(text: pin));
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  SnackBar(
                                                    content: Text('PIN $pin copied to clipboard!'),
                                                    backgroundColor: Colors.green.shade800,
                                                  ),
                                                );
                                              },
                                            ),
                                        ],
                                      );
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade100.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.support_agent, size: 18, color: Colors.amber.shade900),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Support Operator Hotline Guide: If the customer is temporarily unreachable at pickup or drop-off, verify the driver\'s registered identity and verbally provide the 4-digit PIN displayed above to authorize order handover.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.brown.shade900,
                                  height: 1.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Scheduled Booking Details (if applicable)
              if (isScheduled) ...[
                Card(
                  color: Colors.deepPurple.shade50,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.deepPurple.shade200),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        const Icon(Icons.event, color: Colors.deepPurple, size: 24),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Scheduled Ride Booking', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.deepPurple)),
                              Text(
                                scheduledDate != null
                                    ? 'Pickup Time: ${_formatDateTime(scheduledDate)}'
                                    : 'Scheduled dispatch pending',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Route & Addresses
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Trip Route & Geofence', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.trip_origin, color: Colors.green, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Pickup Address', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                Text(pickup, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.location_on, color: Colors.red, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Drop-off Address', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                Text(dropoff, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Customer & Driver Profiles
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('1. Customer Profile', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 8),
                      Text('Name: $customerName'),
                      Row(
                        children: [
                          const Text('Customer ID: '),
                          if (customerId.isNotEmpty)
                            _MemberIdBadge(
                              uid: customerId,
                              initialId: customerSeqId,
                              cache: _memberIdCache,
                              db: _db,
                            )
                          else
                            const Text('N/A'),
                        ],
                      ),
                      Row(
                        children: [
                          Text('Phone: $customerPhone'),
                          const Spacer(),
                          if (customerPhone != 'N/A')
                            IconButton(
                              icon: const Icon(Icons.phone, color: Colors.green, size: 18),
                              tooltip: 'Call Customer',
                              onPressed: () async {
                                final uri = Uri(scheme: 'tel', path: customerPhone);
                                if (await canLaunchUrl(uri)) await launchUrl(uri);
                              },
                            ),
                        ],
                      ),
                      const Divider(height: 20),
                      const Text('2. Driver Profile', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 8),
                      if (hasAssignedDriver)
                        Row(
                          children: [
                            const Text('Driver ID: '),
                            _MemberIdBadge(
                              uid: driverId,
                              initialId: driverSeqId,
                              isDriver: true,
                              cache: _memberIdCache,
                              db: _db,
                            ),
                          ],
                        ),
                      Text('Driver Name: $driverName'),
                      Text('Vehicle Plate: $vehiclePlate'),
                      Row(
                        children: [
                          Text('Driver Phone: $driverPhone'),
                          const Spacer(),
                          if (driverPhone != 'N/A')
                            IconButton(
                              icon: const Icon(Icons.phone, color: Colors.blue, size: 18),
                              tooltip: 'Call Driver',
                              onPressed: () async {
                                final uri = Uri(scheme: 'tel', path: driverPhone);
                                if (await canLaunchUrl(uri)) await launchUrl(uri);
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Financial & Payment Ledger Breakdown
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('3. Financial & Payment Ledger',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 8),
                      Text('Base Trip Fare: ₦${((data['baseFare'] is num) ? (data['baseFare'] as num).toDouble() : ((data['proposedFare'] is num) ? (data['proposedFare'] as num).toDouble() : 0.0)).toStringAsFixed(2)}'),
                      if ((data['recoveredDebt'] is num && (data['recoveredDebt'] as num) > 0) ||
                          (data['outstandingBalanceIncluded'] is num && (data['outstandingBalanceIncluded'] as num) > 0)) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Recovered Debt (Negative Balance): ₦${((data['recoveredDebt'] is num) ? (data['recoveredDebt'] as num).toDouble() : ((data['outstandingBalanceIncluded'] is num) ? (data['outstandingBalanceIncluded'] as num).toDouble() : 0.0)).toStringAsFixed(2)}',
                          style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.bold),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        'Total Cash to Collect: ₦${((data['cashToCollect'] is num) ? (data['cashToCollect'] as num).toDouble() : 0.0).toStringAsFixed(2)}',
                        style: const TextStyle(color: Color(0xFFD97706), fontWeight: FontWeight.bold),
                      ),
                      const Divider(height: 16),
                      if (isSplit) ...[
                        Text('Sender Share: ₦${senderShare.toStringAsFixed(2)} ($senderMethod)'),
                        Text('Receiver Share: ₦${receiverShare.toStringAsFixed(2)} ($receiverMethod)'),
                      ] else ...[
                        Text('Payment Method: $senderMethod'),
                      ],
                    ],
                  ),
                ),
              ),
              if (data['rejections'] is List && (data['rejections'] as List).isNotEmpty) ...[
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('4. Dispatch Rejection & Skip Audit Trail',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        const SizedBox(height: 8),
                        ...((data['rejections'] as List).map((r) {
                          final rMap = r is Map ? r : {};
                          final isSuperseded = rMap['superseded'] == true;
                          final baseAction = rMap['action'] == 'skipped'
                              ? 'Skipped by Driver'
                              : 'Rejected by Driver';
                          final action = isSuperseded ? '$baseAction (Superseded)' : baseAction;
                          final dId = rMap['driverId']?.toString() ?? 'Unknown';
                          final ts = _parseDate(rMap['timestamp']);
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Icon(
                                  rMap['action'] == 'skipped' ? Icons.skip_next : Icons.close,
                                  size: 16,
                                  color: Colors.orange.shade800,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text('Driver $dId: $action',
                                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                                ),
                                if (ts != null)
                                  Text(_formatDateTime(ts),
                                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                              ],
                            ),
                          );
                        })),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),

              // Hub Action Overrides
              const Text('Administrative Override Actions', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.green.shade800),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Force Complete Trip'),
                    onPressed: () async {
                      try {
                        await FirebaseFunctions.instance.httpsCallable('hubForceCompleteTrip').call({'tripId': tripId});
                        if (context.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Trip force completed.')));
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                        }
                      }
                    },
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Remove Trip & Refund Customer'),
                    onPressed: () async {
                      try {
                        await FirebaseFunctions.instance.httpsCallable('hubCancelRefundTrip').call({'tripId': tripId, 'reason': 'Removed by Support/Admin'});
                        if (context.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Trip removed and customer refunded.')));
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                        }
                      }
                    },
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Manual PIN Bypass'),
                    onPressed: () async {
                      try {
                        await FirebaseFunctions.instance.httpsCallable('hubManualPinBypass').call({'tripId': tripId});
                        if (context.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Delivery PIN bypassed by agent.')));
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                        }
                      }
                    },
                  ),
                  if (canReassign)
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.swap_horiz),
                      label: const Text('Re-assign Drivers'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showReassignDriverModal(context, tripId, data);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showReassignDriverModal(
    BuildContext context,
    String tripId,
    Map<String, dynamic> tripData,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => _ReassignDriversSheet(
        db: _db,
        tripId: tripId,
        tripData: tripData,
        memberIdCache: _memberIdCache,
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

  static String _formatDateTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.day}/${dt.month}/${dt.year} $h:$m';
  }
}

/// Resolves and displays formatted Member IDs (`SCxxxx`, `SDxxxx`, `SAxxxx`)
/// without ever showing raw Firebase Auth UIDs as the primary ID.
class _MemberIdBadge extends StatefulWidget {
  final String uid;
  final String initialId;
  final bool isDriver;
  final Map<String, String> cache;
  final FirebaseFirestore db;

  const _MemberIdBadge({
    required this.uid,
    this.initialId = '',
    this.isDriver = false,
    required this.cache,
    required this.db,
  });

  @override
  State<_MemberIdBadge> createState() => _MemberIdBadgeState();
}

class _MemberIdBadgeState extends State<_MemberIdBadge> {
  String? _resolvedId;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant _MemberIdBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid || oldWidget.initialId != widget.initialId) {
      _init();
    }
  }

  void _init() {
    if (widget.initialId.isNotEmpty) {
      widget.cache[widget.uid] = widget.initialId;
      _resolvedId = widget.initialId;
      return;
    }
    final cached = widget.cache[widget.uid];
    if (cached != null && cached.isNotEmpty) {
      _resolvedId = cached;
      return;
    }
    _fetchId();
  }

  Future<void> _fetchId() async {
    try {
      String found = '';
      if (widget.isDriver) {
        final dDoc = await widget.db.collection('drivers').doc(widget.uid).get();
        found = (dDoc.data()?['sequentialId'] ?? '').toString().trim();
      }
      if (found.isEmpty) {
        final uDoc = await widget.db.collection('users').doc(widget.uid).get();
        found = (uDoc.data()?['sequentialId'] ?? '').toString().trim();
      }
      if (found.isNotEmpty) {
        widget.cache[widget.uid] = found;
        if (mounted) setState(() => _resolvedId = found);
      } else {
        if (mounted) setState(() => _resolvedId = 'Pending ID');
      }
    } catch (_) {
      if (mounted) setState(() => _resolvedId = 'Pending ID');
    }
  }

  @override
  Widget build(BuildContext context) {
    final display = (_resolvedId ?? '').isNotEmpty ? _resolvedId! : 'Resolving...';
    final isFormatted = display.startsWith('S') && display.length >= 4 && !display.contains(' ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isFormatted
            ? (widget.isDriver ? Colors.amber.shade100 : Colors.blue.shade50)
            : Colors.grey.shade200,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        display,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: isFormatted
              ? (widget.isDriver ? Colors.amber.shade900 : Colors.blue.shade900)
              : Colors.grey.shade700,
        ),
      ),
    );
  }
}

/// Multi-driver selection sheet for Hub order re-assignment.
/// Lists drivers in the order's area/zone with both positive and negative wallet
/// balances, displays Name, Driver ID (`SDxxxx`), area/distance, and wallet status,
/// and dispatches first-to-pick via `hubReassignTrip`.
class _ReassignDriversSheet extends StatefulWidget {
  final FirebaseFirestore db;
  final String tripId;
  final Map<String, dynamic> tripData;
  final Map<String, String> memberIdCache;

  const _ReassignDriversSheet({
    required this.db,
    required this.tripId,
    required this.tripData,
    required this.memberIdCache,
  });

  @override
  State<_ReassignDriversSheet> createState() => _ReassignDriversSheetState();
}

class _ReassignDriversSheetState extends State<_ReassignDriversSheet> {
  final Set<String> _selectedIds = <String>{};
  bool _onlyOnline = false;
  bool _onlyZone = true;
  bool _submitting = false;
  String _search = '';

  double? get _pickupLat {
    final p = widget.tripData['pickupLocation'];
    if (p is Map && p['lat'] is num) return (p['lat'] as num).toDouble();
    if (widget.tripData['pickupLat'] is num) return (widget.tripData['pickupLat'] as num).toDouble();
    return null;
  }

  double? get _pickupLng {
    final p = widget.tripData['pickupLocation'];
    if (p is Map && p['lng'] is num) return (p['lng'] as num).toDouble();
    if (widget.tripData['pickupLng'] is num) return (widget.tripData['pickupLng'] as num).toDouble();
    return null;
  }

  String get _tripCountry =>
      (widget.tripData['pickupCountryCode'] ?? widget.tripData['countryCode'] ?? '')
          .toString()
          .trim()
          .toUpperCase();

  String get _tripState =>
      (widget.tripData['pickupState'] ?? widget.tripData['stateOrRegion'] ?? '')
          .toString()
          .trim()
          .toUpperCase();

  static double? _haversineKm(double? lat1, double? lng1, double? lat2, double? lng2) {
    if (lat1 == null || lng1 == null || lat2 == null || lng2 == null) return null;
    const r = 6371.0;
    final dLat = (lat2 - lat1) * math.pi / 180.0;
    final dLng = (lng2 - lng1) * math.pi / 180.0;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static (double?, double?) _extractCoords(Map<String, dynamic> d) {
    for (final key in ['lastLocation', 'lastFix', 'location', 'currentLocation']) {
      final raw = d[key];
      if (raw is GeoPoint) return (raw.latitude, raw.longitude);
      if (raw is Map) {
        final lat = raw['lat'] ?? raw['latitude'];
        final lng = raw['lng'] ?? raw['longitude'];
        if (lat is num && lng is num) return (lat.toDouble(), lng.toDouble());
      }
    }
    if (d['latitude'] is num && d['longitude'] is num) {
      return ((d['latitude'] as num).toDouble(), (d['longitude'] as num).toDouble());
    }
    return (null, null);
  }

  Future<void> _dispatchSelected() async {
    if (_selectedIds.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    try {
      await FirebaseFunctions.instance.httpsCallable('hubReassignTrip').call({
        'tripId': widget.tripId,
        'driverIds': _selectedIds.toList(),
        'reason': 'Manual Hub multi-driver re-assignment',
      });
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Order dispatched to ${_selectedIds.length} driver(s) on a first-to-pick basis.',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to re-assign order: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      maxChildSize: 0.96,
      expand: false,
      builder: (_, scrollCtrl) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Re-assign Order (${widget.tripId.length > 10 ? widget.tripId.substring(0, 10) : widget.tripId})',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  'Select one or more drivers (first-to-pick wins). Negative-balance drivers must top up before accepting.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 10),
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search driver by name, SD ID, or area...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: Text(_tripState.isNotEmpty ? 'Zone: $_tripState' : 'Same Area'),
                      selected: _onlyZone,
                      onSelected: (v) => setState(() => _onlyZone = v),
                    ),
                    FilterChip(
                      label: const Text('Online Only'),
                      selected: _onlyOnline,
                      onSelected: (v) => setState(() => _onlyOnline = v),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: widget.db.collection('drivers').snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
                  return const SeseListSkeleton(itemCount: 5);
                }
                if (snap.hasError) {
                  return Center(child: Text('Error loading drivers: ${snap.error}'));
                }
                final allDocs = snap.data?.docs ?? [];
                final entries = allDocs.where((doc) {
                  final d = doc.data();
                  if (_onlyOnline && d['isOnline'] != true) return false;
                  if (_onlyZone) {
                    final dCountry = (d['countryCode'] ?? '').toString().trim().toUpperCase();
                    final dState = (d['stateOrRegion'] ?? d['state'] ?? '').toString().trim().toUpperCase();
                    if (_tripCountry.isNotEmpty && dCountry.isNotEmpty && dCountry != _tripCountry) {
                      return false;
                    }
                    if (_tripState.isNotEmpty && dState.isNotEmpty && !dState.contains(_tripState)) {
                      return false;
                    }
                  }
                  if (_search.isNotEmpty) {
                    final name = (d['fullName'] ?? d['name'] ?? '').toString().toLowerCase();
                    final seq = (d['sequentialId'] ?? '').toString().toLowerCase();
                    final state = (d['stateOrRegion'] ?? d['state'] ?? '').toString().toLowerCase();
                    if (!name.contains(_search) && !seq.contains(_search) && !state.contains(_search)) {
                      return false;
                    }
                  }
                  return true;
                }).toList();

                entries.sort((a, b) {
                  final da = a.data();
                  final dbMap = b.data();
                  final onA = da['isOnline'] == true ? 0 : 1;
                  final onB = dbMap['isOnline'] == true ? 0 : 1;
                  if (onA != onB) return onA.compareTo(onB);
                  final ca = _extractCoords(da);
                  final cb = _extractCoords(dbMap);
                  final distA = _haversineKm(_pickupLat, _pickupLng, ca.$1, ca.$2) ?? 99999.0;
                  final distB = _haversineKm(_pickupLat, _pickupLng, cb.$1, cb.$2) ?? 99999.0;
                  return distA.compareTo(distB);
                });

                if (entries.isEmpty) {
                  return const Center(
                    child: Text('No matching drivers found. Try toggling Zone or Online filter.'),
                  );
                }

                return ListView.separated(
                  controller: scrollCtrl,
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final doc = entries[index];
                    final d = doc.data();
                    final driverId = doc.id;
                    final name = (d['fullName'] ?? d['name'] ?? 'Driver').toString();
                    final seqId = (d['sequentialId'] ?? '').toString().trim();
                    final isOnline = d['isOnline'] == true;
                    final area = (d['stateOrRegion'] ?? d['state'] ?? d['countryCode'] ?? 'Area N/A').toString();
                    final coords = _extractCoords(d);
                    final distKm = _haversineKm(_pickupLat, _pickupLng, coords.$1, coords.$2);
                    final distLabel = distKm != null ? '${distKm.toStringAsFixed(1)} km' : area;
                    final selected = _selectedIds.contains(driverId);

                    return CheckboxListTile(
                      value: selected,
                      onChanged: (checked) {
                        setState(() {
                          if (checked == true) {
                            _selectedIds.add(driverId);
                          } else {
                            _selectedIds.remove(driverId);
                          }
                        });
                      },
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          _MemberIdBadge(
                            uid: driverId,
                            initialId: seqId,
                            isDriver: true,
                            cache: widget.memberIdCache,
                            db: widget.db,
                          ),
                        ],
                      ),
                      subtitle: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: isOnline ? Colors.green.shade50 : Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              isOnline ? 'ONLINE' : 'OFFLINE',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: isOnline ? Colors.green.shade800 : Colors.grey.shade700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('$area • $distLabel', style: const TextStyle(fontSize: 12)),
                          const Spacer(),
                          _DriverWalletStatusBadge(db: widget.db, driverId: driverId),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: _submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send),
                  label: Text(
                    _submitting
                        ? 'Dispatching...'
                        : 'Dispatch to Selected Drivers (${_selectedIds.length})',
                  ),
                  onPressed: _selectedIds.isEmpty || _submitting ? null : _dispatchSelected,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DriverWalletStatusBadge extends StatelessWidget {
  final FirebaseFirestore db;
  final String driverId;

  const _DriverWalletStatusBadge({required this.db, required this.driverId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: db.collection('wallets').doc(driverId).get(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Text('...', style: TextStyle(fontSize: 11, color: Colors.grey));
        }
        final w = snap.data?.data() ?? const <String, dynamic>{};
        final double bal = w['mainWalletBalance'] is num
            ? (w['mainWalletBalance'] as num).toDouble()
            : (w['balance'] is num ? (w['balance'] as num).toDouble() / 100.0 : 0.0);
        final isLow = bal < 1.0;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: isLow ? Colors.red.shade50 : Colors.green.shade50,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: isLow ? Colors.red.shade300 : Colors.green.shade300,
            ),
          ),
          child: Text(
            '₦${bal.toStringAsFixed(0)}${isLow ? ' (Low)' : ''}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: isLow ? Colors.red.shade800 : Colors.green.shade800,
            ),
          ),
        );
      },
    );
  }
}
