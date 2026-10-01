import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../home/customer_home_shell.dart';
import '../../home/driver_home_shell.dart';
import '../../settings/role_controller.dart';
import '../../../widgets/location_picker_map.dart';
import '../../../widgets/document_upload_card.dart';

/// Step 2 of driver registration: Driver Personal Information Form.
///
/// Reached immediately after driver "Create Account" (email/password or
/// Google) with `drivers/{uid}.verificationStatus == 'pending_onboarding'`.
///
/// Sections:
/// 1. Personal information — first/last name, phone, date of birth
///    (18+ age verification), gender.
/// 2. Home address — OpenStreetMap/Nominatim autocomplete + interactive
///    flutter_map view (search, tap to pin) producing `latitude/longitude`.
/// 3. Government ID — country-aware document type (Nigeria: NIN / Driver's
///    License / Voter's Card / International Passport; other countries:
///    Government Issued ID / Passport), front + back uploads, and a
///    camera-only live selfie (no gallery) for face verification, plus
///    emergency (next of kin) contact details.
/// 4. Submission writes `drivers/{driverId}` with
///    `verificationStatus: 'pending'`, `isProfileVerified: false`,
///    `isVehicleVerified: false`, `canGoOnline: false`, then routes to
///    Driver Home (persistent pending-verification banner).
class DriverOnboardingScreen extends StatefulWidget {
  final AppUser user;
  final AuthRepository auth;

  /// Injectable seams for tests / offline previews.
  final DriverOnboardingService? onboardingService;
  final ImagePicker? imagePicker;

  const DriverOnboardingScreen({
    super.key,
    required this.user,
    required this.auth,
    this.onboardingService,
    this.imagePicker,
  });

  @override
  State<DriverOnboardingScreen> createState() => _DriverOnboardingScreenState();
}

class _DriverOnboardingScreenState extends State<DriverOnboardingScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _firstName;
  late final TextEditingController _lastName;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _idNumber;
  late final TextEditingController _kinName;
  late final TextEditingController _kinRelationship;
  late final TextEditingController _kinRelationshipOther;
  late final TextEditingController _kinPhone;

  static const List<String> _kinRelationshipOptions = [
    'Spouse (Wife / Husband)',
    'Parent (Mother / Father)',
    'Sibling (Brother / Sister)',
    'Sponsor / Employer',
    'Child',
    'Relative / Extended Family',
    'Other',
  ];
  String? _selectedKinRelationship;

  DateTime? _dob;
  String _gender = 'Male';
  String _country = 'Nigeria';
  String? _stateOrRegion; // Dynamically dependent on _country
  String _idType = 'NIN';

  static const _nigeriaIdTypes = [
    'NIN',
    "Driver's License",
    "Voter's Card",
    'International Passport',
  ];
  static const _otherIdTypes = ['Government Issued ID', 'Passport'];
  static const _nonExpiringIdTypes = {'NIN', "Voter's Card"};

  String get _effectiveKinRelationship {
    if (_selectedKinRelationship == 'Other') {
      return _kinRelationshipOther.text.trim().isNotEmpty
          ? _kinRelationshipOther.text.trim()
          : 'Other';
    }
    return _selectedKinRelationship ?? _kinRelationship.text.trim();
  }

  List<String> get _idOptions =>
      _country == 'Nigeria' ? _nigeriaIdTypes : _otherIdTypes;

  // Map pin state (default: Lagos).
  LatLng _pin = const LatLng(6.5244, 3.3792);

  // Nominatim autocomplete state.
  List<NominatimResult> _suggestions = [];
  Timer? _debounce;
  bool _searching = false;

  XFile? _idFront;
  XFile? _idBack;
  XFile? _selfie;

  bool _submitting = false;

  late final DriverOnboardingService _service;
  ImagePicker get _picker => widget.imagePicker ?? ImagePicker();

  String _phoneNumberE164 = '';

  @override
  void initState() {
    super.initState();
    final parts = widget.user.fullName.trim().split(RegExp(r'\s+'));
    _firstName = TextEditingController(
        text: parts.isEmpty ? '' : parts.first);
    _lastName = TextEditingController(
        text: parts.length < 2 ? '' : parts.sublist(1).join(' '));
    final initialClean = SesePhoneSanitizer.cleanPhoneNumber(
      widget.user.phoneNumber,
      SesePhoneSanitizer.getDialCode('NG'),
    );
    _phone = TextEditingController(text: initialClean);
    _address = TextEditingController();
    _idNumber = TextEditingController();
    _kinName = TextEditingController();
    _kinRelationship = TextEditingController();
    _kinRelationshipOther = TextEditingController();
    _kinPhone = TextEditingController();
    _kinAddress = TextEditingController();
    _idExpiry = TextEditingController();
    _service = widget.onboardingService ?? DriverOnboardingService();
  }

  late final TextEditingController _kinAddress;
  late final TextEditingController _idExpiry;
  DateTime? _idExpiryDate;

  @override
  void dispose() {
    _debounce?.cancel();
    _firstName.dispose();
    _lastName.dispose();
    _phone.dispose();
    _address.dispose();
    _idNumber.dispose();
    _kinName.dispose();
    _kinRelationship.dispose();
    _kinRelationshipOther.dispose();
    _kinPhone.dispose();
    _kinAddress.dispose();
    _idExpiry.dispose();
    super.dispose();
  }

  // ─── Address search (Nominatim) ──────────────────────────────────────────

  void _onAddressChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 3) {
      setState(() {
        _suggestions = [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        final results = await _service.searchAddress(query.trim());
        if (!mounted) return;
        setState(() {
          _suggestions = results;
          _searching = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _suggestions = [];
          _searching = false;
        });
      }
    });
  }

  void _selectSuggestion(NominatimResult result) {
    setState(() {
      _address.text = result.displayName;
      _pin = LatLng(result.lat, result.lng);
      _suggestions = [];
    });
  }

  // ─── Image capture ───────────────────────────────────────────────────────

  Future<void> _pickIdDocument(bool isFront) async {
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(isFront ? 'ID document — front' : 'ID document — back'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ImageSource.camera),
            child: const Row(
              children: [
                Icon(Icons.photo_camera_outlined),
                SizedBox(width: 12),
                Text('Take photo'),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ImageSource.gallery),
            child: const Row(
              children: [
                Icon(Icons.photo_library_outlined),
                SizedBox(width: 12),
                Text('Choose from gallery'),
              ],
            ),
          ),
        ],
      ),
    );
    if (source == null) return;
    final file = await _picker.pickImage(source: source, imageQuality: 80);
    if (file == null) return;
    setState(() {
      if (isFront) {
        _idFront = file;
      } else {
        _idBack = file;
      }
    });
  }

  /// Live selfie is camera-only by policy (no gallery upload) so hub
  /// reviewers get a genuine face-verification capture.
  Future<void> _captureSelfie() async {
    final file =
        await _picker.pickImage(source: ImageSource.camera, imageQuality: 80);
    if (file == null) return;
    setState(() => _selfie = file);
  }

  Future<void> _pickIdExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 365)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365 * 10)),
      helpText: 'Select Document Expiry Date',
    );
    if (picked == null) return;
    setState(() {
      _idExpiryDate = picked;
      _idExpiry.text =
          '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    });
  }

  // ─── Submit ──────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_dob == null) {
      _snack('Select your date of birth.', isError: true);
      return;
    }
    if (!DriverOnboardingService.isAdult(_dob!)) {
      _snack('Drivers must be at least 18 years old.', isError: true);
      return;
    }
    if (_selfie == null) {
      _snack('Capture a live selfie for face verification.',
          isError: true);
      return;
    }
    setState(() => _submitting = true);
    try {
      final dial = SesePhoneSanitizer.getDialCode(_country == 'Nigeria' ? 'NG' : 'US');
      final cleanDigits = SesePhoneSanitizer.cleanPhoneNumber(_phone.text.trim(), dial);
      final normalizedPhone = _phoneNumberE164.isNotEmpty
          ? _phoneNumberE164
          : SesePhoneSanitizer.normalize(cleanDigits, defaultIsoCode: _country == 'Nigeria' ? 'NG' : 'US');

      await _service.submitOnboarding(
        driverId: widget.user.uid,
        firstName: _firstName.text.trim(),
        lastName: _lastName.text.trim(),
        phone: normalizedPhone,
        dateOfBirth: _dob!,
        gender: _gender,
        country: _country,
        stateOrRegion: _stateOrRegion,
        homeAddress: _address.text.trim(),
        latitude: _pin.latitude,
        longitude: _pin.longitude,
        idType: _idType,
        idNumber: _idNumber.text.trim(),
        idExpiryDate: _nonExpiringIdTypes.contains(_idType) ? null : _idExpiryDate,
        idFront: _idFront,
        idBack: _idBack,
        selfie: _selfie,
        kinName: _kinName.text.trim(),
        kinRelationship: _effectiveKinRelationship,
        kinPhone: SesePhoneSanitizer.normalize(_kinPhone.text.trim()),
        kinAddress: _kinAddress.text.trim(),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 28),
              SizedBox(width: 10),
              Expanded(child: Text('Submission Successful')),
            ],
          ),
          content: const Text(
            'Your driver profile details and KYC verification documents have been successfully submitted to Cloud Firestore.\n\n'
            'Our team will review your submission. You will be notified once your profile is verified.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Continue to Home'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => DriverHomeShell(
            user: widget.user,
            auth: widget.auth,
          ),
        ),
      );
    } on DriverOnboardingException catch (e) {
      _snack(e.userMessage, isError: true);
    } on FirebaseException catch (e) {
      final message = e.code == 'permission-denied'
          ? 'Unable to save profile details. Please try again or contact support.'
          : 'Submission failed. Please check your network connection.';
      _snack(message, isError: true);
    } catch (e) {
      _snack('Submission failed. Please check your network connection.', isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _snack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : null,
      ),
    );
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 20, now.month, now.day),
      firstDate: DateTime(now.year - 100),
      lastDate: now,
    );
    if (picked != null) setState(() => _dob = picked);
  }

  Future<void> _handleBackToAuth([BuildContext? ctx]) async {
    final choice = await showDialog<String>(
      context: ctx ?? context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Exit Registration?'),
        content: const Text(
          'Your entered details will remain saved. What would you like to do?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('cancel'),
            child: const Text('Continue Registration'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('customer'),
            child: const Text('Switch to Customer Mode'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('sign_out'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (!mounted || choice == null || choice == 'cancel') return;

    if (choice == 'customer') {
      RoleController.instance.setCurrentRole(UserRole.customer);
      final customerUser = widget.user.copyWith(role: UserRole.customer);
      final nav = Navigator.of(context);
      if (nav.canPop()) {
        nav.pop();
      } else {
        nav.pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => CustomerHomeShell(user: customerUser, auth: widget.auth),
          ),
          (route) => false,
        );
      }
    } else if (choice == 'sign_out') {
      await widget.auth.signOut();
      if (!mounted) return;
      final nav = Navigator.of(context);
      if (nav.canPop()) {
        nav.pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _handleBackToAuth(context);
        }
      },
      child: Scaffold(
        appBar: SeseAppBar(
          title: 'Step 2: Personal Information',
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _handleBackToAuth(context),
          ),
          actions: [
            TextButton(
              onPressed: () => _handleBackToAuth(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _sectionHeader('1 · Personal information', Icons.person_outline),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _firstName,
                      decoration: const InputDecoration(
                        labelText: 'First Name',
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _lastName,
                      decoration: const InputDecoration(
                        labelText: 'Last Name',
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SesePhoneInputField(
                controller: _phone,
                labelText: 'Phone Number',
                initialValue: _phone.text,
                onChanged: (e164) {
                  _phoneNumberE164 = e164;
                },
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Phone is required';
                  final normalized = SesePhoneSanitizer.normalize(v);
                  if (!SesePhoneSanitizer.isValidE164(normalized)) {
                    return 'Enter a valid international phone number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.cake_outlined),
                      label: Text(
                        _dob == null
                            ? 'Date of Birth'
                            : '${_dob!.day}/${_dob!.month}/${_dob!.year}',
                      ),
                      onPressed: _submitting ? null : _pickDob,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _gender,
                      decoration: const InputDecoration(
                        labelText: 'Gender',
                      ),
                      items: const ['Male', 'Female', 'Other']
                          .map((g) => DropdownMenuItem(
                                value: g,
                                child: Text(g),
                              ))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _gender = v ?? _gender),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _sectionHeader(
                  '2 · Home address (search or tap map)', Icons.map_outlined),
              TextFormField(
                controller: _address,
                decoration: InputDecoration(
                  labelText: 'Address',
                  hintText: 'Search street, area, city…',
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : const Icon(Icons.search),
                ),
                onChanged: _onAddressChanged,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              if (_suggestions.isNotEmpty)
                Card(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final s in _suggestions)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.place_outlined),
                          title: Text(
                            s.displayName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          onTap: () => _selectSuggestion(s),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () async {
                  final result = await Navigator.push<LocationResult>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => FullScreenLocationPickerScreen(
                        initialCenter: _pin,
                        initialAddress: _address.text,
                      ),
                    ),
                  );
                  if (result != null) {
                    setState(() {
                      _address.text = result.address;
                      _pin = result.latLng;
                    });
                  }
                },
                child: AbsorbPointer(
                  child: Stack(
                    children: [
                      SizedBox(
                        height: 180,
                        child: LocationPickerMap(
                          initialCenter: _pin,
                          initialZoom: 13,
                          initialAddress:
                              _address.text.isNotEmpty ? _address.text : null,
                        ),
                      ),
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Chip(
                            avatar: const Icon(Icons.touch_app, size: 18),
                            label: const Text('Tap map to pin exact location'),
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surface
                                .withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _sectionHeader(
                  '3 · Government ID & photo verification',
                  Icons.badge_outlined),
              Row(
                children: [
                  Expanded(
                    child: SeseCountryDropdownFormField(
                      initialValue: _country,
                      labelText: 'Country',
                      decoration: const InputDecoration(
                        labelText: 'Country',
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      ),
                      onChanged: (info) {
                        final v = info?.countryName;
                        if (v == null) return;
                        setState(() {
                          _country = v;
                          _stateOrRegion = null; // reset when country changes
                          _idType =
                              v == 'Nigeria' ? 'NIN' : 'Government Issued ID';
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _idType,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'ID Document',
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      ),
                      items: _idOptions
                          .map((t) => DropdownMenuItem(
                                value: t,
                                child: Text(
                                  t,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12.5),
                                ),
                              ))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _idType = v ?? _idType),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // State / Region — dynamically populated from selected country.
              Builder(builder: (context) {
                final iso = SeseCountryCatalog.allCountries
                    .firstWhere(
                      (c) => c.countryName == _country,
                      orElse: () => SeseCountryCatalog.allCountries.first,
                    )
                    .countryCode;
                return SeseStateDropdownFormField(
                  countryCode: iso,
                  value: _stateOrRegion,
                  labelText: 'State / Region',
                  onChanged: (v) => setState(() => _stateOrRegion = v),
                );
              }),
              const SizedBox(height: 12),
              TextFormField(
                controller: _idNumber,
                decoration: InputDecoration(
                  labelText: '$_idType Number',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              if (!_nonExpiringIdTypes.contains(_idType)) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _idExpiry,
                  readOnly: true,
                  onTap: _pickIdExpiry,
                  decoration: InputDecoration(
                    labelText: '$_idType Expiry Date',
                    suffixIcon: const Icon(Icons.calendar_today_outlined),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Column(
                children: [
                  DocumentUploadCard(
                    label: 'ID Front',
                    file: _idFront,
                    placeholderIcon: Icons.badge_outlined,
                    disabled: _submitting,
                    onPick: () => _pickIdDocument(true),
                    onRetake: () => _pickIdDocument(true),
                  ),
                  const SizedBox(height: 12),
                  DocumentUploadCard(
                    label: 'ID Back',
                    file: _idBack,
                    placeholderIcon: Icons.badge_outlined,
                    disabled: _submitting,
                    onPick: () => _pickIdDocument(false),
                    onRetake: () => _pickIdDocument(false),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DocumentUploadCard(
                label: 'Live Selfie',
                file: _selfie,
                placeholderIcon: Icons.camera_alt_outlined,
                isCameraOnly: true,
                disabled: _submitting,
                onPick: _captureSelfie,
                onRetake: _captureSelfie,
              ),
              const SizedBox(height: 4),
              Text(
                'Selfie must be taken with the camera now — gallery uploads are not accepted.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              _sectionHeader(
                  '4 · Emergency contact (next of kin)',
                  Icons.contact_phone_outlined),
              TextFormField(
                controller: _kinName,
                decoration: const InputDecoration(
                  labelText: 'Next of Kin Name',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _selectedKinRelationship,
                decoration: const InputDecoration(
                  labelText: 'Relationship',
                ),
                items: _kinRelationshipOptions
                    .map((r) => DropdownMenuItem(
                          value: r,
                          child: Text(r, overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: (v) {
                  setState(() {
                    _selectedKinRelationship = v;
                    _kinRelationship.text = v ?? '';
                  });
                },
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Please select a relationship' : null,
              ),
              if (_selectedKinRelationship == 'Other') ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _kinRelationshipOther,
                  decoration: const InputDecoration(
                    labelText: 'Specify Relationship',
                  ),
                  validator: (v) =>
                      (_selectedKinRelationship == 'Other' && (v == null || v.trim().isEmpty))
                          ? 'Please specify relationship'
                          : null,
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _kinPhone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone Number',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _kinAddress,
                decoration: const InputDecoration(
                  labelText: 'Residential Address',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Submit for Verification',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
  );
}

  Widget _sectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}

/// Nominatim / OpenStreetMap autocomplete result.
class NominatimResult {
  final String displayName;
  final double lat;
  final double lng;

  const NominatimResult({
    required this.displayName,
    required this.lat,
    required this.lng,
  });

  factory NominatimResult.fromJson(Map<String, dynamic> json) {
    return NominatimResult(
      displayName: (json['display_name'] ?? '').toString(),
      lat: double.tryParse(json['lat']?.toString() ?? '') ?? 0,
      lng: double.tryParse(json['lon']?.toString() ?? '') ?? 0,
    );
  }
}

class DriverOnboardingException implements Exception {
  final String code;
  final String userMessage;

  const DriverOnboardingException(this.code, this.userMessage);

  @override
  String toString() => 'DriverOnboardingException($code): $userMessage';
}

/// Writes the Step 2 onboarding payload to `drivers/{driverId}`.
class DriverOnboardingService {
  final FirebaseFirestore? _firestore;
  final FirebaseStorage? _storage;
  final http.Client? _httpClient;

  /// Test seam: replaces the storage upload (returns a download URL).
  final Future<String> Function(XFile file, String path)? uploadOverride;

  DriverOnboardingService(
      {this._firestore,
      this._storage,
      this._httpClient,
      this.uploadOverride});

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  /// Minimum-age rule: drivers must be at least 18 years old.
  static bool isAdult(DateTime dob, {DateTime? now}) {
    final today = now ?? DateTime.now();
    var age = today.year - dob.year;
    if (today.month < dob.month ||
        (today.month == dob.month && today.day < dob.day)) {
      age--;
    }
    return age >= 18;
  }

  /// OpenStreetMap Nominatim address autocomplete.
  Future<List<NominatimResult>> searchAddress(String query) async {
    final client = _httpClient ?? http.Client();
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'format': 'jsonv2',
      'q': query,
      'limit': '5',
      'addressdetails': '0',
    });
    final closeClient = _httpClient == null;
    try {
      final response = await client.get(uri, headers: {
        'User-Agent': 'sese_ride-driver-onboarding/1.0',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return [];
      final decoded = jsonDecode(response.body);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((m) =>
              NominatimResult.fromJson(Map<String, dynamic>.from(m)))
          .where((r) => r.displayName.isNotEmpty)
          .toList();
    } finally {
      if (closeClient) client.close();
    }
  }

  Future<String> _upload(XFile file, String path) async {
    if (uploadOverride != null) return uploadOverride!(file, path);
    try {
      final storage = _storage ?? FirebaseStorage.instance;
      final data = await file.readAsBytes();
      final ref = storage.ref().child(path);
      await ref.putData(data);
      return await ref.getDownloadURL();
    } catch (_) {
      throw const DriverOnboardingException(
        'upload-failed',
        'Unable to upload document. Please check your network connection and try again.',
      );
    }
  }

  /// Submits Step 2: uploads ID/selfie captures (when provided) and merges
  /// the personal-info payload into `drivers/{driverId}` with
  /// `verificationStatus: 'pending'`, `isProfileVerified: false`,
  /// `isVehicleVerified: false`, `canGoOnline: false`.
  Future<void> submitOnboarding({
    required String driverId,
    required String firstName,
    required String lastName,
    required String phone,
    required DateTime dateOfBirth,
    required String gender,
    required String country,
    String? stateOrRegion,
    required String homeAddress,
    required double latitude,
    required double longitude,
    required String idType,
    required String idNumber,
    DateTime? idExpiryDate,
    XFile? idFront,
    XFile? idBack,
    XFile? selfie,
    required String kinName,
    required String kinRelationship,
    required String kinPhone,
    String kinAddress = '',
  }) async {
    if (driverId.isEmpty) {
      throw const DriverOnboardingException(
          'invalid-driver', 'Missing driver account reference.');
    }
    if (!isAdult(dateOfBirth)) {
      throw const DriverOnboardingException(
          'underage', 'Drivers must be at least 18 years old.');
    }
    if (selfie == null) {
      throw const DriverOnboardingException(
          'selfie-required', 'A live camera selfie is required.');
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    String idFrontUrl = '';
    String idBackUrl = '';
    String selfieUrl = '';
    try {
      if (idFront != null) {
        idFrontUrl = await _upload(
            idFront, 'driver_onboarding/$driverId/id_front_$stamp.jpg');
      }
      if (idBack != null) {
        idBackUrl = await _upload(
            idBack, 'driver_onboarding/$driverId/id_back_$stamp.jpg');
      }
      selfieUrl = await _upload(
          selfie, 'driver_onboarding/$driverId/selfie_$stamp.jpg');
    } on DriverOnboardingException {
      rethrow;
    }

    final db = _db;
    if (db == null) {
      throw const DriverOnboardingException(
          'firestore-unavailable', 'Could not reach the database.');
    }
    final fullName = '$firstName $lastName'.trim();
    final payload = <String, dynamic>{
      'fullName': fullName,
      'firstName': firstName,
      'lastName': lastName,
      'phoneNumber': phone,
      'phoneNumberE164': phone,
      'dateOfBirth': dateOfBirth.toIso8601String(),
      'gender': gender,
      'country': country,
      'stateOrRegion': stateOrRegion,
      'homeAddress': homeAddress,
      'address': homeAddress,
      'latitude': latitude,
      'longitude': longitude,
      'idType': idType,
      'idNumber': idNumber,
      if (idExpiryDate != null)
        'idExpiryDate': idExpiryDate.toIso8601String(),
      'idFrontUrl': idFrontUrl,
      'idBackUrl': idBackUrl,
      'selfieUrl': selfieUrl,
      'emergencyContact': {
        'name': kinName,
        'relationship': kinRelationship,
        'phone': kinPhone,
        'address': kinAddress,
      },
      'profileStatus': 'pending_verification',
      'verificationStatus': DriverVerification.pending,
      'isPendingReview': true,
      DriverVerification.fieldProfileVerified: false,
      DriverVerification.fieldVehicleVerified: false,
      DriverVerification.fieldCanGoOnline: false,
      'isActive': false,
      'onboardingStep2CompletedAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
    };

    await db.collection('drivers').doc(driverId).set(
      payload,
      SetOptions(merge: true),
    );

    try {
      await db.collection('users').doc(driverId).set(
        payload,
        SetOptions(merge: true),
      );
    } catch (_) {
      // Fallback if users collection is inaccessible or unused
    }
  }
}

/// Result returned from [FullScreenLocationPickerScreen].
class LocationResult {
  final LatLng latLng;
  final String address;

  const LocationResult(this.latLng, this.address);
}

/// Fullscreen interactive location picker screen.
class FullScreenLocationPickerScreen extends StatefulWidget {
  final LatLng initialCenter;
  final String initialAddress;

  const FullScreenLocationPickerScreen({
    super.key,
    required this.initialCenter,
    required this.initialAddress,
  });

  @override
  State<FullScreenLocationPickerScreen> createState() =>
      _FullScreenLocationPickerScreenState();
}

class _FullScreenLocationPickerScreenState
    extends State<FullScreenLocationPickerScreen> {
  late LatLng _selectedCenter;
  late String _selectedAddress;

  @override
  void initState() {
    super.initState();
    _selectedCenter = widget.initialCenter;
    _selectedAddress = widget.initialAddress;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pin Home Location'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(
                context,
                LocationResult(_selectedCenter, _selectedAddress),
              );
            },
            child: const Text(
              'Done',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          LocationPickerMap(
            initialCenter: _selectedCenter,
            initialZoom: 15,
            initialAddress: _selectedAddress,
            onLocationChanged: (pos, addr) {
              setState(() {
                _selectedCenter = pos;
                if (addr.isNotEmpty) _selectedAddress = addr;
              });
            },
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: FilledButton.icon(
              icon: const Icon(Icons.check_circle_outline),
              label: const Text(
                'Confirm Selected Location',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: () {
                Navigator.pop(
                  context,
                  LocationResult(_selectedCenter, _selectedAddress),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

