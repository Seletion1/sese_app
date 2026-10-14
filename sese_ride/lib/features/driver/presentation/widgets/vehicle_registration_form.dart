import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../../services/driver_fleet_service.dart';
import 'photo_guide_modal.dart';

/// Per-slot upload state for one required document/inspection slot.
class _SlotUpload {
  String? localPath;
  String? url;
  bool uploading = false;
  String? error;
}

/// Dynamic vehicle registration form (the Deploy-form overhaul).
///
/// - All fields start empty with hint placeholders; the Register CTA stays
///   disabled until every field validates AND every category-required
///   upload completes.
/// - Make/Model/Color/Year are cascading dropdowns with an "Other" escape
///   hatch into free text.
/// - Required slots come from [VehicleDocumentRequirements.forCategory]:
///   bicycles skip plate/license/insurance (receipt + gov ID + 1 photo),
///   bikes/keke need 2 plate photos, cars/vans/trucks need 5 photos.
/// - Uploads go through `image_picker` (Camera/Gallery chooser) into
///   Firebase Storage; [pickImage]/[uploadDocument] seams exist for tests.
class VehicleRegistrationForm extends StatefulWidget {
  final DriverFleetService fleetService;
  final String driverId;
  final RegionConfig? config;

  /// Test seam: pick an image for [source] (defaults to ImagePicker).
  final Future<XFile?> Function({required ImageSource source})? pickImage;

  /// Test seam: upload a picked file (defaults to Storage upload).
  final Future<String> Function({
    required String docType,
    required String localPath,
  })? uploadDocument;

  final void Function(VehicleModel vehicle)? onRegistered;

  const VehicleRegistrationForm({
    super.key,
    required this.fleetService,
    required this.driverId,
    this.config,
    this.pickImage,
    this.uploadDocument,
    this.onRegistered,
  });

  @override
  State<VehicleRegistrationForm> createState() =>
      VehicleRegistrationFormState();
}

/// Exposed for widget tests (validity, effective values).
class VehicleRegistrationFormState extends State<VehicleRegistrationForm> {
  VehicleCategory _category = VehicleCategory.car;

  String? _make;
  final _makeCustomCtrl = TextEditingController();
  String? _model;
  final _modelCustomCtrl = TextEditingController();
  String? _color;
  final _colorCustomCtrl = TextEditingController();
  int? _year;
  bool _yearOther = false;
  final _yearCustomCtrl = TextEditingController();
  final _plateCtrl = TextEditingController();

  final Map<String, _SlotUpload> _uploads = {};
  bool _submitting = false;

  VehicleDocumentRequirements get _req =>
      VehicleDocumentRequirements.forCategory(_category);

  List<String> get _makes => catalogMakes[catalogGroupFor(_category)] ?? [];

  /// Null when the model must be free text (custom/unknown make).
  List<String>? get _models =>
      _make == null ? null : catalogModels[_make];

  bool get _makeIsOther => _make == otherOption;
  bool get _modelIsOther => _model == otherOption;
  bool get _colorIsOther => _color == otherOption;

  String get effectiveMake =>
      _makeIsOther ? _makeCustomCtrl.text.trim() : (_make ?? '');
  String get effectiveModel {
    if (_models == null) return _modelCustomCtrl.text.trim();
    return _modelIsOther ? _modelCustomCtrl.text.trim() : (_model ?? '');
  }

  String get effectiveColor =>
      _colorIsOther ? _colorCustomCtrl.text.trim() : (_color ?? '');

  int? get effectiveYear {
    if (_year != null) return _year;
    if (!_yearOther) return null;
    final y = int.tryParse(_yearCustomCtrl.text.trim());
    if (y == null) return null;
    final max = DateTime.now().year + 1;
    if (y < 1995 || y > max) return null;
    return y;
  }

  bool get _plateValid =>
      !_req.requiresLicensePlate || _plateCtrl.text.trim().length >= 5;

  /// Register CTA enablement: every field valid + every required slot
  /// uploaded + nothing in flight.
  bool get canSubmit {
    if (_submitting) return false;
    if (effectiveMake.isEmpty ||
        effectiveModel.isEmpty ||
        effectiveColor.isEmpty) {
      return false;
    }
    if (effectiveYear == null) return false;
    if (!_plateValid) return false;
    for (final slot in _req.slots) {
      final up = _uploads[slot.key];
      if (up == null || up.url == null || up.uploading) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _makeCustomCtrl.dispose();
    _modelCustomCtrl.dispose();
    _colorCustomCtrl.dispose();
    _yearCustomCtrl.dispose();
    _plateCtrl.dispose();
    super.dispose();
  }

  void _onCategoryChanged(VehicleCategory? v) {
    if (v == null || v == _category) return;
    setState(() {
      _category = v;
      _make = null;
      _model = null;
      _makeCustomCtrl.clear();
      _modelCustomCtrl.clear();
      // Required upload set changes shape per category — reset it so a
      // stale car photo can never satisfy a bicycle slot (and vice versa).
      _uploads.clear();
    });
  }

  RideTier? _previewCarTier() {
    if (_category != VehicleCategory.car) return null;
    final year = effectiveYear;
    if (year == null) return null;
    final thresholds =
        widget.config?.carTierThresholds ?? const CarTierThresholds();
    return VehicleTierClassifier(thresholds)
        .classify(category: VehicleCategory.car, manufactureYear: year);
  }

  Future<void> _pickSlot(VehicleDocSlot slot) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Take Photo (Camera)'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    // Runtime permission handshake BEFORE the native picker (applies to
    // the test seam too — the service is a no-op without a plugin).
    final permission = await MediaPermissionService.ensureFor(source);
    if (!mounted) return;
    if (permission != MediaPermissionOutcome.granted) {
      await MediaPermissionService.promptIfPermanentlyDenied(context);
      return;
    }
    final up = _uploads.putIfAbsent(slot.key, () => _SlotUpload());
    try {
      final file = await (widget.pickImage != null
          ? widget.pickImage!(source: source)
          : ImageCompressionService.pickAndCompressImage(source: source));
      if (file == null || !mounted) return;
      setState(() {
        up.localPath = file.path;
        up.uploading = true;
        up.error = null;
      });
      final url = await (widget.uploadDocument != null
          ? widget.uploadDocument!(
              docType: slot.label, localPath: file.path)
          : widget.fleetService.uploadVehicleDocument(
              driverId: widget.driverId,
              docType: slot.label,
              localPath: file.path,
            ));
      if (!mounted) return;
      setState(() {
        up.uploading = false;
        up.url = url;
      });
    } catch (e) {
      if (!mounted) return;
      // Never surface raw backend details (e.g.
      // `[firebase_storage/unauthorized]`) — show a sanitized message.
      final message = sanitizedVehicleUploadMessage(e, slot.label);
      setState(() {
        up.uploading = false;
        up.error = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Future<void> _register() async {
    if (!canSubmit) return;
    setState(() => _submitting = true);
    try {
      final vehicle = await widget.fleetService.registerVehicle(
        driverId: widget.driverId,
        category: _category,
        make: effectiveMake,
        model: effectiveModel,
        year: effectiveYear!,
        licensePlate: _plateCtrl.text.trim().toUpperCase(),
        color: effectiveColor,
        documents: {
          for (final slot in _req.slots) slot.label: _uploads[slot.key]!.url!,
        },
        thresholds:
            widget.config?.carTierThresholds ?? const CarTierThresholds(),
      );
      if (!mounted) return;
      widget.onRegistered?.call(vehicle);
      _reset();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _reset() {
    setState(() {
      _make = null;
      _model = null;
      _color = null;
      _year = null;
      _yearOther = false;
      _makeCustomCtrl.clear();
      _modelCustomCtrl.clear();
      _colorCustomCtrl.clear();
      _yearCustomCtrl.clear();
      _plateCtrl.clear();
      _uploads.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final previewTier = _previewCarTier();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Register New Vehicle to Fleet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'All newly registered vehicles will undergo administrative verification.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<VehicleCategory>(
              initialValue: _category,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Vehicle Scope Category',
              ),
              items: VehicleCategory.values
                  .map((cat) => DropdownMenuItem(
                        value: cat,
                        child: Text(
                          cat.displayName,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              onChanged: _onCategoryChanged,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                // isExpanded + ellipsized items keep long make/model names
                // inside the half-width cell (no right-edge pixel overflow).
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _make,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Vehicle Make',
                      hintText: 'Select make',
                    ),
                    items: [
                      for (final m in _makes)
                        DropdownMenuItem(
                          value: m,
                          child: Text(m, overflow: TextOverflow.ellipsis),
                        ),
                      const DropdownMenuItem(
                          value: otherOption, child: Text(otherOption)),
                    ],
                    onChanged: (v) => setState(() {
                      _make = v;
                      _model = null;
                      _modelCustomCtrl.clear();
                    }),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: _buildModelField()),
              ],
            ),
            if (_makeIsOther) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _makeCustomCtrl,
                decoration: const InputDecoration(
                  labelText: 'Custom Make',
                  hintText: 'e.g. Innoson',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            if (_modelIsOther) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _modelCustomCtrl,
                decoration: const InputDecoration(
                  labelText: 'Custom Model',
                  hintText: 'e.g. Fox RS',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _buildYearField()),
                const SizedBox(width: 12),
                Expanded(child: _buildColorField()),
              ],
            ),
            if (_colorIsOther) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _colorCustomCtrl,
                decoration: const InputDecoration(
                  labelText: 'Custom Color',
                  hintText: 'e.g. Champagne',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            if (_req.requiresLicensePlate) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _plateCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'License Plate Number',
                  hintText: 'e.g. LAG-123-XY',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            if (_category == VehicleCategory.car &&
                previewTier != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.auto_awesome, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Auto-Assigned Ride-Hailing Tier: ${previewTier.defaultDisplayName} (Year $effectiveYear)',
                        style: TextStyle(
                          color: Colors.blue.shade900,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            const Text(
              'Required Documentation Upload:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final slot in _req.documents)
                  _buildDocChip(slot),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Inspection Photos:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.help_outline, size: 18),
                  label: const Text('View Photo Guide'),
                  onPressed: () =>
                      showVehiclePhotoGuide(context, _category),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_req.inspections.length} angle${_req.inspections.length == 1 ? '' : 's'} required for ${categoryLabel(_category)}.',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final slot in _req.inspections)
                  _buildDocChip(slot),
              ],
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: canSubmit ? _register : null,
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.add_circle_outline),
              label: const Text('Register Vehicle to Fleet'),
              style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
            ),
            if (!canSubmit && !_submitting)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Complete every field and required upload to enable registration.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String categoryLabel(VehicleCategory c) => c.displayName;

  Widget _buildModelField() {
    final models = _models;
    if (models == null) {
      // No make chosen yet — or custom make: free text.
      if (_make == null) {
        return const TextField(
          enabled: false,
          decoration: InputDecoration(
            labelText: 'Vehicle Model',
            hintText: 'Select make first',
          ),
        );
      }
      return TextFormField(
        controller: _modelCustomCtrl,
        decoration: const InputDecoration(
          labelText: 'Vehicle Model',
          hintText: 'e.g. Fox RS',
        ),
        onChanged: (_) => setState(() {}),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: _model,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Vehicle Model',
        hintText: 'Select model',
      ),
      items: [
        for (final m in models)
          DropdownMenuItem(
            value: m,
            child: Text(m, overflow: TextOverflow.ellipsis),
          ),
        const DropdownMenuItem(value: otherOption, child: Text(otherOption)),
      ],
      onChanged: (v) => setState(() {
        _model = v;
        _modelCustomCtrl.clear();
      }),
    );
  }

  Widget _buildYearField() {
    final years = catalogYears();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _yearOther ? otherOption : _year?.toString(),
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Manufacture Year',
          ),
          items: [
            for (final y in years)
              DropdownMenuItem(value: '$y', child: Text('$y')),
            const DropdownMenuItem(
                value: otherOption, child: Text(otherOption)),
          ],
          onChanged: (v) => setState(() {
            if (v == otherOption) {
              _year = null;
              _yearOther = true;
            } else {
              _year = int.tryParse(v ?? '');
              _yearOther = false;
              _yearCustomCtrl.clear();
            }
          }),
        ),
        if (_yearOther) ...[
          const SizedBox(height: 12),
          TextFormField(
            controller: _yearCustomCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Custom Year',
              hintText: 'e.g. 1990',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ],
    );
  }

  Widget _buildColorField() {
    return DropdownButtonFormField<String>(
      initialValue: _color,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Color',
        hintText: 'Select color',
      ),
      items: [
        for (final c in catalogColors)
          DropdownMenuItem(value: c, child: Text(c)),
        const DropdownMenuItem(value: otherOption, child: Text(otherOption)),
      ],
      onChanged: (v) => setState(() {
        _color = v;
        _colorCustomCtrl.clear();
      }),
    );
  }

  Widget _buildDocChip(VehicleDocSlot slot) {
    final up = _uploads[slot.key];
    final attached = up?.url != null;
    Widget? thumb;
    final path = up?.localPath;
    if (path != null && File(path).existsSync()) {
      thumb = ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(path),
          width: 20,
          height: 20,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              const Icon(Icons.image, size: 18, color: Colors.grey),
        ),
      );
    }
    return ActionChip(
      avatar: up?.uploading == true
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : thumb ??
              Icon(
                attached ? Icons.check_circle : Icons.upload_file,
                color: attached ? Colors.green : Colors.grey,
                size: 18,
              ),
      label: Text(
        attached
            ? '${slot.label} (Attached)'
            : up?.uploading == true
                ? 'Uploading ${slot.label}…'
                : 'Upload ${slot.label}',
        style: TextStyle(
          color: attached ? Colors.green.shade800 : Colors.black87,
          fontWeight: attached ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      onPressed: up?.uploading == true ? null : () => _pickSlot(slot),
    );
  }
}
