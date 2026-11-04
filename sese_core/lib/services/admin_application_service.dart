import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/models/admin_application.dart';

/// Service managing Agent ("Become an Admin / Work With Us") submissions,
/// storage uploads, device fingerprinting, and hub approval workflows.
class AdminApplicationService {
  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;

  AdminApplicationService({
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance;

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection('admin_applications');

  /// Streams the application status for a given user [uid].
  Stream<AdminApplication?> applicationStream(String uid) {
    if (uid.isEmpty) return Stream.value(null);
    return _collection.doc(uid).snapshots().map((snap) {
      if (!snap.exists || snap.data() == null) return null;
      return AdminApplication.fromMap(snap.id, snap.data()!);
    });
  }

  /// Streams all applications for sese_hub administrative review.
  Stream<List<AdminApplication>> allApplicationsStream() {
    return _collection
        .orderBy('submittedAt', descending: true)
        .snapshots()
        .map((snap) {
      return snap.docs
          .map((doc) => AdminApplication.fromMap(doc.id, doc.data()))
          .toList();
    });
  }

  /// Uploads a document (File or Uint8List) to Firebase Storage under
  /// `admin_applications/$uid/$fileName` and returns its public download URL.
  Future<String> uploadDocument({
    required String uid,
    required String fileName,
    required dynamic fileData, // File or Uint8List
  }) async {
    final ref = _storage.ref().child('admin_applications/$uid/$fileName');
    final metadata = SettableMetadata(contentType: 'image/jpeg');
    UploadTask task;

    if (fileData is Uint8List) {
      task = ref.putData(fileData, metadata);
    } else if (fileData is File) {
      task = ref.putFile(fileData, metadata);
    } else {
      throw ArgumentError('Unsupported file format for document upload.');
    }

    final snap = await task;
    return await snap.ref.getDownloadURL();
  }

  /// Submits a candidate's Agent onboarding application.
  Future<AdminApplication> submitApplication({
    required String uid,
    required String firstName,
    String middleName = '',
    required String lastName,
    required String email,
    required String phoneNumber,
    required String dob,
    required String idType,
    required dynamic idFile,
    required dynamic proofOfAddressFile,
    required dynamic selfieFile,
    Map<String, dynamic> deviceMetadata = const {},
  }) async {
    final fullName = [firstName, middleName, lastName]
        .where((s) => s.trim().isNotEmpty)
        .join(' ')
        .trim();

    // 1. Upload required verification photos/documents
    final idUrl = await uploadDocument(
      uid: uid,
      fileName: 'id_document.jpg',
      fileData: idFile,
    );

    final proofOfAddressUrl = await uploadDocument(
      uid: uid,
      fileName: 'proof_of_address.jpg',
      fileData: proofOfAddressFile,
    );

    final selfieUrl = await uploadDocument(
      uid: uid,
      fileName: 'live_selfie.jpg',
      fileData: selfieFile,
    );

    final now = DateTime.now();
    final app = AdminApplication(
      uid: uid,
      fullName: fullName,
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      email: email.trim().toLowerCase(),
      phoneNumber: phoneNumber,
      dob: dob,
      idType: idType,
      idUrl: idUrl,
      proofOfAddressUrl: proofOfAddressUrl,
      selfieUrl: selfieUrl,
      deviceMetadata: deviceMetadata,
      status: 'pending',
      submittedAt: now,
      updatedAt: now,
    );

    await _collection.doc(uid).set(app.toMap(), SetOptions(merge: true));
    return app;
  }

  /// Approves an application, sets status, and provisions/activates `hub_staff`.
  Future<void> approveApplication({
    required String uid,
    required String email,
    required String reviewerEmail,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final now = DateTime.now();

    // 1. Update application status
    await _collection.doc(uid).update({
      'status': 'approved',
      'reviewedBy': reviewerEmail,
      'reviewedAt': now.toIso8601String(),
      'updatedAt': now.toIso8601String(),
    });

    // 2. Ensure candidate email is present and active in `hub_staff`
    final staffRef = _firestore.collection('hub_staff').doc(cleanEmail);
    final staffSnap = await staffRef.get();

    final defaultPermissions = [
      'user_onboarding',
      'document_review',
      'support_chat',
      'fleet_verify',
    ];

    if (staffSnap.exists) {
      await staffRef.update({
        'active': true,
        'role': 'Agent',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } else {
      await staffRef.set({
        'email': cleanEmail,
        'role': 'Agent',
        'assignedPermissions': defaultPermissions,
        'countryScope': 'global',
        'assignedBy': reviewerEmail,
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }

    // 3. Update user profile role tag
    try {
      await _firestore.collection('users').doc(uid).set({
        'isAgent': true,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('AdminApplicationService.approveApplication user flag update: $e');
    }
  }

  /// Rejects an application with a specified reason.
  Future<void> rejectApplication({
    required String uid,
    required String reviewerEmail,
    required String reason,
  }) async {
    final now = DateTime.now();
    await _collection.doc(uid).update({
      'status': 'rejected',
      'rejectionReason': reason,
      'reviewedBy': reviewerEmail,
      'reviewedAt': now.toIso8601String(),
      'updatedAt': now.toIso8601String(),
    });
  }

  /// Explicitly whitelists/provisions a candidate email in `hub_staff`.
  Future<void> provisionHubStaff({
    required String candidateEmail,
    required String provisionerEmail,
    List<String>? permissions,
  }) async {
    final clean = candidateEmail.trim().toLowerCase();
    final staffRef = _firestore.collection('hub_staff').doc(clean);
    final defaultPerms = permissions ?? [
      'user_onboarding',
      'document_review',
      'support_chat',
      'fleet_verify',
    ];

    await staffRef.set({
      'email': clean,
      'role': 'Agent',
      'assignedPermissions': defaultPerms,
      'countryScope': 'global',
      'assignedBy': provisionerEmail,
      'active': true,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
