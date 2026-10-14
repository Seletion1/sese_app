import 'package:cloud_firestore/cloud_firestore.dart';
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
///    - Dispute overrides: "Force Complete Trip", "Cancel & Refund Escrow", "Manual PIN Bypass".
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
    super.key,
    this.firestore,
    this.stageLock,
    this.lockedCountry,
  });

  @override
  State<_RidesConsoleBody> createState() => _RidesConsoleBodyState();
}

class _RidesConsoleBodyState extends State<_RidesConsoleBody> {
  FirebaseFirestore get _db => widget.firestore ?? FirebaseFirestore.instance;

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
              stream: _db
                  .collection('trips')
                  .where('status', whereIn: _activeStatuses)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Error loading active/scheduled rides: ${snapshot.error}'),
                  );
                }
                if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
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
                      !(status == 'in_transit' || status == 'in_progress')) {
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
      ),
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
    final fareAmount = (data['fareAmount'] is num) ? (data['fareAmount'] as num).toDouble() : 0.0;
    final customerName = (data['customerName'] ?? data['userName'] ?? 'Customer').toString();
    final driverName = (data['driverName'] ?? data['driver']?['name'] ?? 'Unassigned').toString();
    final deliveryPin = (data['deliveryPin'] ?? data['order']?['deliveryPin'] ?? '').toString();
    final isSplit = data['isSplitPayment'] == true || data['paymentSplit'] != null;
    final requirePin = data['requireDeliveryPin'] == true || data['forceDeliveryPinSystemWide'] == true;
    final isScheduled = data['isScheduled'] == true || status.toLowerCase().contains('scheduled');
    final scheduledDate = _parseDate(data['scheduledPickupTime'] ?? data['scheduledAt']);
    final pickup = (data['pickupAddress'] ?? 'Pickup').toString();
    final dropoff = (data['dropoffAddress'] ?? 'Dropoff').toString();

    Color statusColor = Colors.orange;
    if (status.toLowerCase().contains('completed')) statusColor = Colors.green;
    if (status.toLowerCase().contains('transit') || status.toLowerCase().contains('progress')) statusColor = Colors.blue;
    if (status.toLowerCase().contains('cancel')) statusColor = Colors.red;
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
                    isScheduled && !status.toUpperCase().contains('SCHEDULED')
                        ? 'SCHEDULED (${status.toUpperCase().replaceAll("_", " ")})'
                        : status.toUpperCase().replaceAll('_', ' '),
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
                Text(
                  '₦${fareAmount.toStringAsFixed(2)}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF10B981)),
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
                      Text('👤 Customer: $customerName', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 2),
                      Text('🚘 Driver: $driverName', style: const TextStyle(fontSize: 13)),
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
                    color: requirePin || deliveryPin.isNotEmpty ? Colors.amber.shade100 : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: requirePin || deliveryPin.isNotEmpty ? Colors.amber.shade700 : Colors.grey.shade400),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.lock, size: 14, color: Colors.amber.shade900),
                          const SizedBox(width: 4),
                          Text(
                            deliveryPin.isNotEmpty ? deliveryPin : (requirePin ? 'PIN REQ' : 'PIN OFF'),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                              color: Colors.amber.shade900,
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
    final customerId = (data['customerId'] ?? 'N/A').toString();
    final driverName = (data['driverName'] ?? data['driver']?['name'] ?? 'Unassigned').toString();
    final driverPhone = (data['driverPhone'] ?? 'N/A').toString();
    final vehiclePlate = (data['vehiclePlate'] ?? data['licensePlate'] ?? 'N/A').toString();
    final deliveryPin = (data['deliveryPin'] ?? data['order']?['deliveryPin'] ?? 'None').toString();
    final requirePin = data['requireDeliveryPin'] == true || data['forceDeliveryPinSystemWide'] == true;
    final isScheduled = data['isScheduled'] == true || (data['status'] ?? '').toString().toLowerCase().contains('scheduled');
    final scheduledDate = _parseDate(data['scheduledPickupTime'] ?? data['scheduledAt']);
    final pickup = (data['pickupAddress'] ?? 'Pickup address').toString();
    final dropoff = (data['dropoffAddress'] ?? 'Dropoff address').toString();

    final isSplit = data['isSplitPayment'] == true || data['paymentSplit'] != null;
    final senderShare = (data['senderShareNaira'] is num) ? (data['senderShareNaira'] as num).toDouble() : 0.0;
    final receiverShare = (data['receiverShareNaira'] is num) ? (data['receiverShareNaira'] as num).toDouble() : 0.0;
    final senderMethod = (data['senderPaymentMethod'] ?? 'wallet').toString();
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
                                Text(
                                  requirePin || deliveryPin != 'None'
                                      ? 'CUSTOMER PIN: $deliveryPin'
                                      : 'PIN Protection is not required for this trip.',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 2.0,
                                    color: Colors.amber.shade900,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (deliveryPin.isNotEmpty && deliveryPin != 'None')
                            IconButton.filledTonal(
                              icon: const Icon(Icons.copy),
                              tooltip: 'Copy Security PIN',
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: deliveryPin));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('PIN $deliveryPin copied to clipboard!'),
                                    backgroundColor: Colors.green.shade800,
                                  ),
                                );
                              },
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
                                'Support Operator Hotline Guide: If the customer is temporarily unreachable at pickup or drop-off, verify the driver\'s registered identity and verbally provide this 4-digit PIN ($deliveryPin) to authorize order handover.',
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
                      Text('Customer ID: $customerId'),
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

              // Split Payment Ledger
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('3. Split Payment Ledger', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 8),
                      if (isSplit) ...[
                        Text('Sender Share: ₦${senderShare.toStringAsFixed(2)} ($senderMethod)'),
                        Text('Receiver Share: ₦${receiverShare.toStringAsFixed(2)} ($receiverMethod)'),
                      ] else ...[
                        Text('Single Payer Order (100% $senderMethod)'),
                      ],
                    ],
                  ),
                ),
              ),
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
                      await _db.collection('trips').doc(tripId).update({'status': 'completed'});
                      if (context.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Trip force completed.')));
                      }
                    },
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel & Refund Escrow'),
                    onPressed: () async {
                      await _db.collection('trips').doc(tripId).update({'status': 'cancelled', 'cancelledBy': 'admin'});
                      if (context.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Trip cancelled and escrow refunded.')));
                      }
                    },
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Manual PIN Bypass'),
                    onPressed: () async {
                      await _db.collection('trips').doc(tripId).update({'pinVerified': true, 'pinBypassedByAdmin': true});
                      if (context.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Delivery PIN bypassed by agent.')));
                      }
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
