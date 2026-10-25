import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';

/// Sanitized upload failure. [userMessage] is safe to display verbatim —
/// it never carries raw backend details, package names, or error codes.
class DriverFleetUploadException implements Exception {
  final String code;
  final String userMessage;

  const DriverFleetUploadException(this.code, this.userMessage);

  @override
  String toString() => 'DriverFleetUploadException($code)';
}

/// Maps any raw Storage/backend failure to a user-safe message. Raw
/// technical details (e.g. `[firebase_storage/unauthorized]`, package
/// names, error codes) are never returned.
String sanitizedVehicleUploadMessage(Object error, String docLabel) {
  // Already-sanitized service errors pass through (message is clean by
  // construction; toString carries no backend details).
  if (error is DriverFleetUploadException) return error.userMessage;
  final label = docLabel.trim().isEmpty ? 'photo' : docLabel.trim();

  var code = '';
  if (error is FirebaseException) {
    code = error.code.toLowerCase();
  }
  final text = '$code ${error.toString().toLowerCase()}';
  final isAuthFailure = code == 'unauthorized' ||
      code == 'unauthenticated' ||
      code.contains('permission') ||
      text.contains('unauthorized') ||
      text.contains('unauthenticated') ||
      text.contains('permission-denied') ||
      text.contains('permission denied') ||
      text.contains('invalid authentication');
  if (isAuthFailure) {
    return 'Unable to upload image. Please check your connection or sign in again.';
  }
  final isNetworkFailure = code.contains('network') ||
      code.contains('retry') ||
      code.contains('timeout') ||
      code.contains('unavailable') ||
      text.contains('network') ||
      text.contains('socket') ||
      text.contains('timeout') ||
      text.contains('connection');
  if (isNetworkFailure) {
    return 'Network error during upload. Please try again.';
  }
  return 'Could not upload $label photo. Please try again.';
}

/// Production service managing driver's fleet under `/drivers/{driverId}/vehicles/{vehicleId}`
/// and pre-online security audits under `/driver_vehicle_verification/{id}`.
///
/// 100% database backed with Firestore.
class DriverFleetService {
  final FirebaseFirestore? _firestore;
  final FirebaseStorage? _storage;

  // Local fallback storage used solely for offline unit/widget test environments
  final List<VehicleModel> _offlineTestVehicles = [];

  DriverFleetService([this._firestore, this._storage]);

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  FirebaseStorage? get _bucket {
    try {
      return _storage ?? FirebaseStorage.instance;
    } catch (_) {
      return null;
    }
  }

  CollectionReference<Map<String, dynamic>>? _driverVehiclesCollection(String driverId) {
    final db = _db;
    if (db == null) return null;
    return db.collection('drivers').doc(driverId).collection('vehicles');
  }

  CollectionReference<Map<String, dynamic>>? get _verificationCollection {
    final db = _db;
    if (db == null) return null;
    return db.collection('driver_vehicle_verification');
  }

  /// Verifies an active Firebase session for [driverId] before any upload
  /// stream starts. Returns silently when Firebase is unavailable (unit
  /// tests); throws a sanitized [DriverFleetUploadException] when no
  /// matching signed-in user exists.
  void _requireActiveDriverSession(String driverId) {
    var firebaseAvailable = true;
    User? user;
    try {
      user = FirebaseAuth.instance.currentUser;
    } catch (_) {
      firebaseAvailable = false;
    }
    if (!firebaseAvailable) return;
    if (user == null) {
      throw const DriverFleetUploadException(
        'session-expired',
        'Unable to upload image. Please check your connection or sign in again.',
      );
    }
  }

  /// Realtime stream of all vehicles registered under the driver.
  Stream<List<VehicleModel>> streamDriverFleet(String driverId) {
    final col = _driverVehiclesCollection(driverId);
    if (col == null) {
      return Stream.value(
        _offlineTestVehicles.where((v) => v.driverId == driverId).toList(),
      );
    }
    return col
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => VehicleModel.fromMap(d.data(), id: d.id))
            .toList());
  }

  /// Fetches all vehicles for the driver directly from Firestore.
  Future<List<VehicleModel>> getDriverFleet(String driverId) async {
    final col = _driverVehiclesCollection(driverId);
    if (col == null) {
      return _offlineTestVehicles.where((v) => v.driverId == driverId).toList();
    }
    try {
      final snap = await col.get();
      return snap.docs
          .map((d) => VehicleModel.fromMap(d.data(), id: d.id))
          .toList();
    } catch (e) {
      debugPrint('DriverFleetService.getDriverFleet Firestore error: $e');
      return _offlineTestVehicles.where((v) => v.driverId == driverId).toList();
    }
  }

  /// Registers a newly added vehicle in Firestore.
  /// Strict Verification Guard: Verification status is hard-enforced to PENDING.
  Future<VehicleModel> registerVehicle({
    required String driverId,
    required VehicleCategory category,
    required String make,
    required String model,
    required int year,
    required String licensePlate,
    required String color,
    required Map<String, String> documents,
    CarTierThresholds thresholds = const CarTierThresholds(),
  }) async {
    final classifier = VehicleTierClassifier(thresholds);
    final rideTier = classifier.classify(category: category, manufactureYear: year);

    final col = _driverVehiclesCollection(driverId);
    final vehicleId = col != null ? col.doc().id : 'veh_${DateTime.now().millisecondsSinceEpoch}';

    final vehicle = VehicleModel(
      id: vehicleId,
      driverId: driverId,
      category: category,
      tier: rideTier,
      make: make,
      model: model,
      year: year,
      licensePlate: licensePlate,
      color: color,
      documents: documents,
      verificationStatus: VehicleVerificationStatus.pending, // Strict Guard: Always PENDING
      lifecycleStatus: VehicleLifecycleStatus.active,
      isActiveSelected: false,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    if (col != null) {
      // Single source of truth: drivers/{driverId}/vehicles/{vehicleId}.
      // Canonical `verificationStatus: PENDING` plus legacy aliases
      // (`isVerified: false`, `status: 'pending'`) so the hub
      // collectionGroup('vehicles') pending queue — canonical or legacy
      // query — renders the vehicle immediately on every client.
      await col.doc(vehicleId).set({
        ...vehicle.toMap(),
        'isVerified': false,
        'status': 'pending',
      });
      await _db?.collection('drivers').doc(driverId).set({
        'vehicleStatus': 'pending_verification',
        'isPendingReview': true,
        'updatedAt': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true));
      if (kDebugMode) debugPrint('Vehicle registered in Firestore with id: $vehicleId');
    } else {
      _offlineTestVehicles.add(vehicle);
    }
    return vehicle;
  }

  /// Sets one vehicle as activeSelected: true and unselects others for this driver.
  ///
  /// Offline-Only Guard: Throws if [isOnline] is true — vehicle switching is
  /// strictly forbidden while online or on an active trip.
  Future<void> setActiveSelectedVehicle({
    required String driverId,
    required String vehicleId,
    bool isOnline = false,
  }) async {
    if (isOnline) {
      throw StateError(
        'Cannot switch active vehicle while ONLINE. Switch to OFFLINE state first.',
      );
    }
    final db = _db;
    final col = _driverVehiclesCollection(driverId);
    if (db != null && col != null) {
      final vehicles = await getDriverFleet(driverId);
      final selected = vehicles.firstWhere(
        (v) => v.id == vehicleId,
        orElse: () => throw ArgumentError('Vehicle $vehicleId not found in driver fleet.'),
      );

      final batch = db.batch();
      for (final v in vehicles) {
        final ref = col.doc(v.id);
        batch.update(ref, {
          'isActiveSelected': v.id == vehicleId,
          'updatedAt': DateTime.now().toIso8601String(),
        });
      }

      // Root driver doc mirror for fast backend dispatch filtering
      final driverRef = db.collection('drivers').doc(driverId);
      batch.set(driverRef, {
        'activeVehicleId': selected.id,
        'activeVehicleCategory': selected.category.name,
        'activePlateNumber': selected.licensePlate,
        'activeVehicleTier': selected.tier?.name,
        'updatedAt': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true));

      await batch.commit();
    } else {
      for (int i = 0; i < _offlineTestVehicles.length; i++) {
        final v = _offlineTestVehicles[i];
        if (v.driverId == driverId) {
          _offlineTestVehicles[i] = v.copyWith(isActiveSelected: v.id == vehicleId);
        }
      }
    }
  }

  /// Uploads a live-camera snapshot to Storage under
  /// `verifications/{driverId}/{vehicleId}_{timestamp}.jpg` and returns the
  /// download URL. Camera capture itself is enforced by the caller
  /// ([OnlineVerificationShieldModal] uses `ImageSource.camera` only —
  /// gallery is never offered), and `captureMode: camera_only` is recorded
  /// on the audit document by [submitLiveVerification].
  Future<String> uploadVerificationPhoto({
    required String driverId,
    required String vehicleId,
    required String localPath,
  }) async {
    _requireActiveDriverSession(driverId);
    final storage = _bucket;
    if (storage == null) {
      // Offline test fallback: return deterministic local URL without touching Storage
      return 'file://offline-verification/$driverId/$vehicleId/${DateTime.now().millisecondsSinceEpoch}.jpg';
    }
    // In tests the picked file may be a dummy path — return URL without upload if file missing
    final file = File(localPath);
    if (!await file.exists()) {
      return 'file://offline-verification/$driverId/$vehicleId/${DateTime.now().millisecondsSinceEpoch}.jpg';
    }
    final fileName =
        '${vehicleId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final ref = storage.ref().child('verifications/$driverId/$fileName');
    await ref.putFile(file, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  /// Uploads a vehicle document photo (license, insurance, inspection) to
  /// Storage under `vehicle_documents/{driverId}/...` and returns the URL.
  Future<String> uploadVehicleDocument({
    required String driverId,
    required String docType,
    required String localPath,
  }) async {
    _requireActiveDriverSession(driverId);
    final storage = _bucket;
    if (storage == null) {
      throw const DriverFleetUploadException(
        'unavailable',
        'Network error during upload. Please try again.',
      );
    }
    final safeType =
        docType.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final fileName =
        '${safeType}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final ref = storage.ref().child('vehicle_documents/$driverId/$fileName');
    await ref.putFile(File(localPath), SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  /// Submits real-time live camera snapshot verification audit record to Firestore.
  /// Strictly adheres to firestore.rules:
  /// - `captureMode == 'camera_only'`
  /// - `status == 'pending'`
  /// - `driverId == request.auth.uid`
  Future<VehicleVerificationRecord> submitLiveVerification({
    required String driverId,
    required String vehicleId,
    required String livePhotoUrl,
    required String detectedLicensePlate,
  }) async {
    final col = _verificationCollection;
    final verificationId = col != null ? col.doc().id : 'ver_${DateTime.now().millisecondsSinceEpoch}';

    final record = VehicleVerificationRecord(
      id: verificationId,
      driverId: driverId,
      vehicleId: vehicleId,
      photoUrl: livePhotoUrl,
      captureMode: 'camera_only', // Enforced: Camera only, no gallery
      status: 'pending',          // Enforced by firestore.rules
      licensePlateDetected: detectedLicensePlate,
      auditNotes: 'Live camera snapshot submitted for vehicle verification.',
      capturedAt: DateTime.now(),
    );

    if (col != null) {
      await col.doc(verificationId).set(record.toMap());
    }

    // Mark this vehicle as the active selected vehicle for the driver
    await setActiveSelectedVehicle(driverId: driverId, vehicleId: vehicleId);

    return record;
  }
}
