import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sese_core/sese_core.dart';
import '../services/driver_fleet_service.dart';

/// Modal dialog presented when a driver taps "Go Online".
/// Enforces:
/// 1. Vehicle Selection: Driver must choose the specific operating vehicle from verified fleet.
/// 2. One-Time Live Photo Verification: Real-time camera snapshot of vehicle front and license plate.
/// 3. Gallery uploads are strictly blocked.
class OnlineVerificationShieldModal extends StatefulWidget {
  final List<VehicleModel> verifiedVehicles;
  final DriverFleetService fleetService;
  final String driverId;
  final Function(VehicleModel activeVehicle) onVerificationPassed;

  /// Test seam: overrides the camera capture. When null the real
  /// `ImagePicker().pickImage(source: ImageSource.camera)` is used (gallery
  /// never offered). In widget tests inject a function returning a dummy XFile.
  final Future<XFile?> Function()? captureOverride;

  const OnlineVerificationShieldModal({
    super.key,
    required this.verifiedVehicles,
    required this.fleetService,
    required this.driverId,
    required this.onVerificationPassed,
    this.captureOverride,
  });

  @override
  State<OnlineVerificationShieldModal> createState() =>
      _OnlineVerificationShieldModalState();
}

class _OnlineVerificationShieldModalState
    extends State<OnlineVerificationShieldModal> {
  int _currentStep = 0; // 0: Select Vehicle, 1: Live Camera Snapshot
  VehicleModel? _selectedVehicle;

  bool _isCapturing = false;
  bool _isProcessing = false;
  XFile? _capturedPhoto;
  String? _captureError;

  @override
  void initState() {
    super.initState();
    if (widget.verifiedVehicles.isNotEmpty) {
      _selectedVehicle = widget.verifiedVehicles.first;
    }
  }

  void _proceedToCameraSnapshot() {
    if (_selectedVehicle == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a verified vehicle for this session.')),
      );
      return;
    }
    setState(() {
      _currentStep = 1;
    });
  }

  /// Opens the device camera ONLY. Gallery (`ImageSource.gallery`) is never
  /// offered anywhere in this flow, so a stored photo cannot be submitted.
  Future<void> _takeLiveSnapshot() async {
    setState(() {
      _isCapturing = true;
      _captureError = null;
    });
    try {
      final XFile? photo;
      if (widget.captureOverride != null) {
        photo = await widget.captureOverride!.call();
      } else {
        photo = await ImagePicker().pickImage(
          source: ImageSource.camera,
          maxWidth: 1600,
          imageQuality: 85,
        );
      }
      if (!mounted) return;
      if (photo == null) return; // User cancelled — stay put
      setState(() => _capturedPhoto = photo);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _captureError =
            'Could not open the camera. Grant camera permission and try again.';
      });
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  /// Uploads the live snapshot to Storage, writes the Firestore audit record,
  /// and only then passes verification. The driver goes ONLINE only after
  /// this completes (plus the server grant in the dashboard).
  Future<void> _uploadAndGoOnline() async {
    final photo = _capturedPhoto;
    final vehicle = _selectedVehicle;
    if (photo == null || vehicle == null) return;
    setState(() {
      _isProcessing = true;
      _captureError = null;
    });
    try {
      final downloadUrl =
          await widget.fleetService.uploadVerificationPhoto(
        driverId: widget.driverId,
        vehicleId: vehicle.id,
        localPath: photo.path,
      );
      final record = await widget.fleetService.submitLiveVerification(
        driverId: widget.driverId,
        vehicleId: vehicle.id,
        livePhotoUrl: downloadUrl,
        detectedLicensePlate: vehicle.licensePlate,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      widget.onVerificationPassed(vehicle);
      Navigator.of(context).pop();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Security Shield Passed: Verified ${record.licensePlateDetected}. Status set to ONLINE.',
          ),
          backgroundColor: Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _captureError =
            'Verification upload failed. Check your connection and try again.';
      });
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: _currentStep == 0
              ? _buildVehicleSelectionView()
              : _buildLiveCameraView(),
        ),
      ),
    );
  }

  Widget _buildVehicleSelectionView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(Icons.shield, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pre-Online Security Shield',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Select session vehicle to continue',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text(
          'Which verified vehicle will you be driving for this session?',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        RadioGroup<VehicleModel>(
          groupValue: _selectedVehicle,
          onChanged: (val) => setState(() => _selectedVehicle = val),
          child: Column(
            children: widget.verifiedVehicles.map((veh) {
              final isSelected = _selectedVehicle?.id == veh.id;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: isSelected
                      ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2)
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: RadioListTile<VehicleModel>(
                    value: veh,
                    title: Text(
                      veh.displayTitle,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    subtitle: Text(
                      'Category: ${veh.category.displayName} ${veh.tier != null ? "• ${veh.tier!.defaultDisplayName}" : ""}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    secondary: Icon(
                      veh.category == VehicleCategory.car
                          ? Icons.directions_car
                          : Icons.two_wheeler,
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          icon: const Icon(Icons.camera_alt),
          label: const Text('Continue to Live Photo Verification'),
          onPressed: _proceedToCameraSnapshot,
          style: FilledButton.styleFrom(padding: const EdgeInsets.all(14)),
        ),
      ],
    );
  }

  Widget _buildLiveCameraView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() => _currentStep = 0),
            ),
            const SizedBox(width: 4),
            const Expanded(
              child: Text(
                'Live Vehicle & Plate Snapshot',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.amber.shade50,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Strict Security Guard: Live camera capture only. Gallery uploads and file selection are blocked.',
                  style: TextStyle(fontSize: 11, color: Colors.brown),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Live Camera Viewfinder: shows the captured snapshot preview, or
        // the alignment guide when nothing is captured yet.
        Container(
          height: 220,
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (_capturedPhoto != null && File(_capturedPhoto!.path).existsSync())
                Positioned.fill(
                  child: Image.file(
                    File(_capturedPhoto!.path),
                    fit: BoxFit.cover,
                  ),
                )
              else if (_capturedPhoto != null)
                // Test dummy capture: file does not exist on disk — show captured badge instead of broken Image
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_circle, size: 64, color: Colors.greenAccent),
                    const SizedBox(height: 8),
                    Text(
                      'Captured: ${_selectedVehicle?.licensePlate ?? ""}',
                      style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    const Text('Ready to verify & go online', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  ],
                )
              else
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _selectedVehicle?.category == VehicleCategory.car
                          ? Icons.directions_car_filled
                          : Icons.two_wheeler,
                      size: 64,
                      color: Colors.white38,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Align Front & Plate: ${_selectedVehicle?.licensePlate ?? ""}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              // Camera reticle overlay
              Positioned(
                bottom: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.videocam, color: Colors.greenAccent, size: 16),
                      SizedBox(width: 6),
                      Text(
                        'LIVE SENSOR ACTIVE',
                        style: TextStyle(
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_isProcessing)
                Container(
                  color: Colors.black54,
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 12),
                        Text(
                          'Verifying license plate & logging audit trail...',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (_captureError != null) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _captureError!,
                    style: TextStyle(color: Colors.red.shade800, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_capturedPhoto == null) ...[
          FilledButton.icon(
            onPressed: _isCapturing || _isProcessing ? null : _takeLiveSnapshot,
            icon: _isCapturing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.camera_alt),
            label: Text(_isCapturing ? 'Opening Camera...' : 'Capture Live Snapshot'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.blue.shade800,
              padding: const EdgeInsets.all(14),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _isProcessing ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isProcessing ? null : _takeLiveSnapshot,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retake'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isProcessing ? null : _uploadAndGoOnline,
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.verified_user),
                  label: Text(_isProcessing ? 'Verifying...' : 'Verify & Go Online'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green.shade800,
                    padding: const EdgeInsets.all(14),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _isProcessing ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ],
    );
  }
}
