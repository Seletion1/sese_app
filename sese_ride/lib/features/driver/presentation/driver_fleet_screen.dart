import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sese_core/sese_core.dart';
import '../services/driver_fleet_service.dart';
import 'widgets/vehicle_registration_form.dart';

class DriverFleetScreen extends StatefulWidget {
  final DriverFleetService fleetService;
  final String driverId;
  final RegionConfig? config;

  /// Test seams forwarded to the registration form.
  final Future<XFile?> Function({required ImageSource source})? pickImage;
  final Future<String> Function({
    required String docType,
    required String localPath,
  })? uploadDocument;

  const DriverFleetScreen({
    super.key,
    required this.fleetService,
    this.driverId = 'current_driver',
    this.config,
    this.pickImage,
    this.uploadDocument,
  });

  @override
  State<DriverFleetScreen> createState() => _DriverFleetScreenState();
}

class _DriverFleetScreenState extends State<DriverFleetScreen> {
  List<VehicleModel> _vehicles = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFleet();
  }

  Future<void> _loadFleet() async {
    setState(() => _loading = true);
    final list = await widget.fleetService.getDriverFleet(widget.driverId);
    setState(() {
      _vehicles = list;
      _loading = false;
    });
  }

  Future<void> _onVehicleRegistered(VehicleModel newVeh) async {
    await _loadFleet();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.orange),
            SizedBox(width: 8),
            Text('Vehicle Registered'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Registered: ${newVeh.displayTitle}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Strict Verification Guard: Vehicle status is set to PENDING VERIFICATION. Under security policy, orders cannot be accepted while your account or vehicle is under verification.',
                style: TextStyle(fontSize: 12, color: Colors.brown),
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Understood'),
          ),
        ],
      ),
    );
  }

  /// Opens the registration form in a modal sheet.
  ///
  /// The form is deliberately not inline: it is a long, always-expanded
  /// document-upload form that pushed the actual fleet list below the fold.
  /// The sheet resolves to the registered vehicle, so the list refresh and the
  /// confirmation dialog only run after a real submission.
  Future<void> _openAddVehicleSheet() async {
    final registered = await showModalBottomSheet<VehicleModel>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddVehicleSheet(
        fleetService: widget.fleetService,
        driverId: widget.driverId,
        config: widget.config,
        pickImage: widget.pickImage,
        uploadDocument: widget.uploadDocument,
      ),
    );
    if (registered == null || !mounted) return;
    await _onVehicleRegistered(registered);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Vehicle Fleet'),
        actions: [
          IconButton(
            key: const Key('add_vehicle_app_bar_action'),
            tooltip: 'Add Vehicle',
            icon: const Icon(Icons.add),
            onPressed: _openAddVehicleSheet,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_vehicle_fab'),
        onPressed: _openAddVehicleSheet,
        icon: const Icon(Icons.add),
        label: const Text('Add Vehicle'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildFleetSummaryCard(),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Registered Fleet Vehicles',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton.icon(
                  key: const Key('add_vehicle_header_button'),
                  onPressed: _openAddVehicleSheet,
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('Add Vehicle'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_vehicles.isEmpty)
              _buildEmptyState()
            else
              ..._vehicles.map((v) => _buildVehicleCard(v)),
            // Clearance for the extended FAB so the last card is never covered.
            const SizedBox(height: 72),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          const Icon(Icons.directions_car_outlined, size: 40, color: Colors.grey),
          const SizedBox(height: 12),
          const Text(
            'No vehicles registered yet',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Add your first vehicle to start receiving dispatch offers.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildFleetSummaryCard() {
    final verifiedCount = _vehicles.where((v) => v.isApproved).length;
    final pendingCount = _vehicles.length - verifiedCount;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatItem('Total Vehicles', '${_vehicles.length}'),
          _buildStatItem('Verified & Active', '$verifiedCount', color: Colors.green.shade800),
          _buildStatItem('Pending Admin Review', '$pendingCount', color: Colors.orange.shade800),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, {Color? color}) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  Widget _buildVehicleCard(VehicleModel vehicle) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: vehicle.isApproved
                      ? Colors.green.shade100
                      : Colors.orange.shade100,
                  child: Icon(
                    vehicle.category == VehicleCategory.car
                        ? Icons.directions_car
                        : Icons.two_wheeler,
                    color: vehicle.isApproved ? Colors.green.shade800 : Colors.orange.shade800,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        vehicle.displayTitle,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        'Category: ${vehicle.category.displayName} • Color: ${vehicle.color}',
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(
                    vehicle.verificationStatus.displayName,
                    style: TextStyle(
                      color: vehicle.isApproved
                          ? Colors.green.shade900
                          : Colors.orange.shade900,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                  backgroundColor: vehicle.isApproved
                      ? Colors.green.shade50
                      : Colors.orange.shade50,
                  side: BorderSide.none,
                ),
              ],
            ),
            if (vehicle.category == VehicleCategory.car && vehicle.tier != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text(
                    'Car Tier Class: ',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  Chip(
                    label: Text(
                      vehicle.tier!.defaultDisplayName,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    backgroundColor: Colors.blue.shade50,
                    side: BorderSide.none,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  vehicle.isApproved ? Icons.check_circle : Icons.lock_clock,
                  size: 16,
                  color: vehicle.isApproved ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    vehicle.isApproved
                        ? 'Eligible for session dispatch.'
                        : 'Strict Guard Active: Unverified vehicles cannot receive orders.',
                    style: TextStyle(
                      fontSize: 12,
                      color: vehicle.isApproved ? Colors.green.shade800 : Colors.brown,
                      fontStyle: vehicle.isApproved ? FontStyle.normal : FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Hosts [VehicleRegistrationForm] inside a draggable modal sheet.
///
/// The form is ~650 lines of inputs plus seven document-upload slots, so it
/// needs both its own scrolling and keyboard inset handling — hence
/// `DraggableScrollableSheet` (which supplies the scroll controller) rather
/// than a plain `SingleChildScrollView`.
class _AddVehicleSheet extends StatelessWidget {
  final DriverFleetService fleetService;
  final String driverId;
  final RegionConfig? config;
  final Future<XFile?> Function({required ImageSource source})? pickImage;
  final Future<String> Function({
    required String docType,
    required String localPath,
  })? uploadDocument;

  const _AddVehicleSheet({
    required this.fleetService,
    required this.driverId,
    this.config,
    this.pickImage,
    this.uploadDocument,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Drag handle; the sheet has no AppBar of its own so the form's
              // own "Register New Vehicle to Fleet" heading serves as title.
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 4),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: EdgeInsets.only(
                    // Lift the form above the soft keyboard.
                    bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                  ),
                  child: VehicleRegistrationForm(
                    fleetService: fleetService,
                    driverId: driverId,
                    config: config,
                    pickImage: pickImage,
                    uploadDocument: uploadDocument,
                    // Pop with the vehicle so the caller refreshes the list
                    // only on a real submission, never on a dismissal.
                    onRegistered: (vehicle) =>
                        Navigator.of(context).pop(vehicle),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
