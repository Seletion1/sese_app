import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../customer/services/location_service.dart';

/// Saved Places — customers store up to two favourite addresses
/// (Home and Work) that are auto-suggested during booking.
///
/// Addresses are persisted at `users/{uid}.savedPlaces` as a sub-map:
/// ```json
/// {
///   "home": {
///     "address": "12 Main Street, Abuja",
///     "lat": 9.0765,
///     "lng": 7.3986
///   },
///   "work": {
///     "address": "Maitama, Abuja",
///     "lat": 9.0600,
///     "lng": 7.4900
///   }
/// }
/// ```
///
/// **Legacy compatibility:** the old schema stored plain strings
/// (`"home": "12 Main Street"`). The loader handles both forms: when the
/// value is a String it treats it as the address with null coordinates
/// (the chips still appear, tapping triggers a geocode fallback).
///
/// Reads and writes are wrapped in try/catch so the screen degrades
/// gracefully in widget tests without a real Firestore instance.
class SavedPlacesScreen extends StatefulWidget {
  final String uid;

  const SavedPlacesScreen({super.key, required this.uid});

  @override
  State<SavedPlacesScreen> createState() => _SavedPlacesScreenState();
}

/// Lightweight model for one saved place within this screen.
class _SavedPlace {
  String address;
  double? lat;
  double? lng;

  _SavedPlace({required this.address, this.lat, this.lng});

  bool get hasCoords => lat != null && lng != null;

  Map<String, dynamic> toFirestore() => {
        'address': address.trim(),
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
      };

  static _SavedPlace fromFirestore(dynamic raw) {
    if (raw == null) return _SavedPlace(address: '');
    // Legacy: plain string value.
    if (raw is String) return _SavedPlace(address: raw);
    final m = raw as Map<String, dynamic>;
    return _SavedPlace(
      address: (m['address'] as String?) ?? '',
      lat: (m['lat'] as num?)?.toDouble(),
      lng: (m['lng'] as num?)?.toDouble(),
    );
  }
}

class _SavedPlacesScreenState extends State<SavedPlacesScreen> {
  final _homeCtrl = TextEditingController();
  final _workCtrl = TextEditingController();
  _SavedPlace _home = _SavedPlace(address: '');
  _SavedPlace _work = _SavedPlace(address: '');
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _homeCtrl.dispose();
    _workCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .get();
      final raw =
          (doc.data()?['savedPlaces'] as Map<String, dynamic>?) ?? {};
      _home = _SavedPlace.fromFirestore(raw['home']);
      _work = _SavedPlace.fromFirestore(raw['work']);
      _homeCtrl.text = _home.address;
      _workCtrl.text = _work.address;
    } catch (_) {
      // Degrade gracefully in tests or offline.
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Resolves an address typed in [ctrl] to coordinates via the geocoding
  /// service and returns an updated [_SavedPlace]. Called when the user
  /// finishes editing a field (onEditingComplete / focus-lost).
  Future<_SavedPlace> _geocode(TextEditingController ctrl) async {
    final text = ctrl.text.trim();
    if (text.isEmpty) return _SavedPlace(address: '');
    try {
      final suggestions =
          await LocationAutocompleteService.fetchSuggestions(text);
      if (suggestions.isEmpty) return _SavedPlace(address: text);
      final top = suggestions.first;
      final placeId = top.placeId;
      if (placeId != null && placeId.isNotEmpty) {
        final resolved = await LocationService.resolvePrediction(top);
        if (resolved != null) {
          return _SavedPlace(
            address: resolved.description,
            lat: resolved.lat,
            lng: resolved.lng,
          );
        }
      }
      // Prediction already had coords (seam/legacy).
      return _SavedPlace(
        address: top.description,
        lat: top.lat,
        lng: top.lng,
      );
    } catch (_) {
      return _SavedPlace(address: text);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    // Show progress while geocoding both fields in parallel.
    if (_homeCtrl.text.trim().isNotEmpty &&
        _homeCtrl.text.trim() != _home.address) {
      _home = await _geocode(_homeCtrl);
      _homeCtrl.text = _home.address;
    }
    if (_workCtrl.text.trim().isNotEmpty &&
        _workCtrl.text.trim() != _work.address) {
      _work = await _geocode(_workCtrl);
      _workCtrl.text = _work.address;
    }

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .set(
        {
          'savedPlaces': {
            'home': _homeCtrl.text.trim().isEmpty
                ? null
                : _home.toFirestore(),
            'work': _workCtrl.text.trim().isEmpty
                ? null
                : _work.toFirestore(),
          },
        },
        SetOptions(merge: true),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved places updated.')),
        );
      }
    } catch (e) {
      debugPrint('SavedPlacesScreen save error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Unable to save places right now. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SeseAppBar(title: 'Saved Places'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                32 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              children: [
                Text(
                  'Save your frequently used addresses for one-tap booking.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey),
                ),
                const SizedBox(height: 20),

                // ── Home ─────────────────────────────────────────────────────
                ListTile(
                  leading: const Icon(Icons.home_outlined,
                      color: AppColors.seseGold),
                  title: const Text('Home'),
                  subtitle: const Text(
                    'Auto-suggests as a destination chip during booking',
                    style: TextStyle(fontSize: 11),
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
                TextField(
                  key: const Key('saved_place_home_field'),
                  controller: _homeCtrl,
                  decoration: InputDecoration(
                    hintText: 'e.g. 12 Main Street, Abuja',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.place_outlined),
                    suffixIcon: _home.hasCoords
                        ? const Icon(Icons.check_circle,
                            color: Colors.green, size: 20)
                        : null,
                  ),
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) {
                    // Invalidate cached coords when text changes.
                    setState(() => _home = _SavedPlace(address: _homeCtrl.text));
                  },
                ),
                if (_home.hasCoords)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 4),
                    child: Text(
                      '${_home.lat!.toStringAsFixed(4)}, ${_home.lng!.toStringAsFixed(4)}',
                      style: const TextStyle(
                          fontSize: 10, color: Colors.grey),
                    ),
                  ),
                const SizedBox(height: 24),

                // ── Work ─────────────────────────────────────────────────────
                ListTile(
                  leading: const Icon(Icons.work_outline,
                      color: AppColors.seseGold),
                  title: const Text('Work'),
                  subtitle: const Text(
                    'Auto-suggests as a destination chip during booking',
                    style: TextStyle(fontSize: 11),
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
                TextField(
                  key: const Key('saved_place_work_field'),
                  controller: _workCtrl,
                  decoration: InputDecoration(
                    hintText: 'e.g. Maitama, Abuja',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.place_outlined),
                    suffixIcon: _work.hasCoords
                        ? const Icon(Icons.check_circle,
                            color: Colors.green, size: 20)
                        : null,
                  ),
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) {
                    setState(() => _work = _SavedPlace(address: _workCtrl.text));
                  },
                ),
                if (_work.hasCoords)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 4),
                    child: Text(
                      '${_work.lat!.toStringAsFixed(4)}, ${_work.lng!.toStringAsFixed(4)}',
                      style: const TextStyle(
                          fontSize: 10, color: Colors.grey),
                    ),
                  ),
                const SizedBox(height: 32),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('saved_places_save_button'),
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_outlined),
                    label: const Text('Save Places'),
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.seseGold,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
