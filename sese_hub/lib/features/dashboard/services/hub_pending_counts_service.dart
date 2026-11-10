import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';
import '../../verification/services/fleet_repository.dart';

/// Centralized real-time pending queue & review count service for SeSe Hub.
///
/// Streams live counts for pending items across all verification desks,
/// requests, and approval pipelines. Handles error states gracefully by
/// returning 0 or cached counts.
class HubPendingCountsService {
  final FirebaseFirestore? _db;
  final FleetRepository? _fleetRepository;

  static HubPendingCountsService? _instance;

  factory HubPendingCountsService({FirebaseFirestore? firestore}) {
    if (firestore != null) {
      return HubPendingCountsService._(
        firestore: firestore,
        fleetRepository: FleetRepository(firestore),
      );
    }
    try {
      _instance ??= HubPendingCountsService._(
        firestore: FirebaseFirestore.instance,
        fleetRepository: FleetRepository(FirebaseFirestore.instance),
      );
      return _instance!;
    } catch (_) {
      // Fallback for widget tests where Firebase is uninitialized.
      return HubPendingCountsService._(
        firestore: null,
        fleetRepository: null,
      );
    }
  }

  HubPendingCountsService._({
    FirebaseFirestore? firestore,
    FleetRepository? fleetRepository,
  })  : // ignore: prefer_initializing_formals
        _db = firestore,
        // ignore: prefer_initializing_formals
        _fleetRepository = fleetRepository;

  /// Stream of pending vehicle registration counts.
  Stream<int> get pendingVehiclesCountStream {
    final repo = _fleetRepository;
    if (repo == null) return Stream.value(0);
    try {
      return repo
          .pendingVehiclesStream()
          .map((list) => list.length)
          .handleError((e) {
        debugPrint('HubPendingCountsService: pendingVehiclesStream error: $e');
        return 0;
      });
    } catch (_) {
      return Stream.value(0);
    }
  }

  /// Stream of pending driver KYC approval counts (deduplicated).
  Stream<int> get pendingDriverKycCountStream {
    final db = _db;
    if (db == null) return Stream.value(0);
    try {
      final s1 = db
          .collection('drivers')
          .where('profileStatus', isEqualTo: 'pending_verification')
          .snapshots();
      final s2 = db
          .collection('drivers')
          .where('isPendingReview', isEqualTo: true)
          .snapshots();
      final s3 = db
          .collection('drivers')
          .where(DriverVerification.fieldStatus, whereIn: [
            DriverVerification.pending,
            'submitted',
            DriverVerification.pendingOnboarding,
            'PENDING',
          ])
          .snapshots();

      late StreamController<int> controller;
      Set<String> set1 = {};
      Set<String> set2 = {};
      Set<String> set3 = {};

      StreamSubscription? sub1;
      StreamSubscription? sub2;
      StreamSubscription? sub3;

      void emit() {
        final combined = {...set1, ...set2, ...set3};
        if (!controller.isClosed) {
          controller.add(combined.length);
        }
      }

      controller = StreamController<int>.broadcast(
        onListen: () {
          sub1 = s1.listen(
            (snap) {
              set1 = snap.docs.map((d) => d.id).toSet();
              emit();
            },
            onError: (_) {},
          );
          sub2 = s2.listen(
            (snap) {
              set2 = snap.docs.map((d) => d.id).toSet();
              emit();
            },
            onError: (_) {},
          );
          sub3 = s3.listen(
            (snap) {
              set3 = snap.docs.map((d) => d.id).toSet();
              emit();
            },
            onError: (_) {},
          );
        },
        onCancel: () {
          sub1?.cancel();
          sub2?.cancel();
          sub3?.cancel();
        },
      );

      return controller.stream;
    } catch (_) {
      return Stream.value(0);
    }
  }

  /// Stream of pending customer KYC approval counts.
  Stream<int> get pendingCustomerKycCountStream {
    final db = _db;
    if (db == null) return Stream.value(0);
    try {
      return db
          .collection('users')
          .where(CustomerVerification.fieldStatus, whereIn: [
            CustomerVerification.pendingReview,
            CustomerVerification.pending,
          ])
          .snapshots()
          .map((snap) => snap.docs.length)
          .handleError((_) => 0);
    } catch (_) {
      return Stream.value(0);
    }
  }

  /// Stream of pending user onboarding counts.
  Stream<int> get pendingUserOnboardingCountStream {
    final db = _db;
    if (db == null) return Stream.value(0);
    try {
      return db
          .collection('users')
          .where('customerVerificationStatus', isEqualTo: 'pending')
          .snapshots()
          .map((snap) => snap.docs.length)
          .handleError((_) => 0);
    } catch (_) {
      return Stream.value(0);
    }
  }

  /// Stream of pending agent application counts ("Work With Us").
  Stream<int> get pendingAgentApplicationsCountStream {
    final db = _db;
    if (db == null) return Stream.value(0);
    try {
      return db
          .collection('agent_applications')
          .where('status', isEqualTo: 'pending')
          .snapshots()
          .map((snap) => snap.docs.length)
          .handleError((_) => 0);
    } catch (_) {
      return Stream.value(0);
    }
  }

  /// Stream of pending support chat counts awaiting an agent.
  Stream<int> get pendingSupportChatsCountStream {
    final db = _db;
    if (db == null) return Stream.value(0);
    try {
      return db
          .collection('support_chats')
          .where('status', isEqualTo: 'pending_agent')
          .snapshots()
          .map((snap) => snap.docs.length)
          .handleError((_) => 0);
    } catch (_) {
      return Stream.value(0);
    }
  }

  /// Stream of pending payout request counts.
  Stream<int> get pendingPayoutsCountStream {
    final db = _db;
    if (db == null) return Stream.value(0);
    try {
      return db
          .collection('payout_requests')
          .where('status', isEqualTo: 'pending')
          .snapshots()
          .map((snap) => snap.docs.length)
          .handleError((_) => 0);
    } catch (_) {
      return Stream.value(0);
    }
  }

  /// Combined total pending count for the Fleet & Security module
  /// (Pending Vehicles + Driver KYC + Customer KYC).
  Stream<int> get fleetTotalPendingCountStream {
    late StreamController<int> controller;
    int c1 = 0;
    int c2 = 0;
    int c3 = 0;

    StreamSubscription? sub1;
    StreamSubscription? sub2;
    StreamSubscription? sub3;

    void emit() {
      if (!controller.isClosed) {
        controller.add(c1 + c2 + c3);
      }
    }

    controller = StreamController<int>.broadcast(
      onListen: () {
        sub1 = pendingVehiclesCountStream.listen((n) {
          c1 = n;
          emit();
        });
        sub2 = pendingDriverKycCountStream.listen((n) {
          c2 = n;
          emit();
        });
        sub3 = pendingCustomerKycCountStream.listen((n) {
          c3 = n;
          emit();
        });
      },
      onCancel: () {
        sub1?.cancel();
        sub2?.cancel();
        sub3?.cancel();
      },
    );

    return controller.stream;
  }

  /// Combined total pending count for the User Onboarding module
  /// (Pending User Onboarding + Agent Applications).
  Stream<int> get onboardingTotalPendingCountStream {
    late StreamController<int> controller;
    int c1 = 0;
    int c2 = 0;

    StreamSubscription? sub1;
    StreamSubscription? sub2;

    void emit() {
      if (!controller.isClosed) {
        controller.add(c1 + c2);
      }
    }

    controller = StreamController<int>.broadcast(
      onListen: () {
        sub1 = pendingUserOnboardingCountStream.listen((n) {
          c1 = n;
          emit();
        });
        sub2 = pendingAgentApplicationsCountStream.listen((n) {
          c2 = n;
          emit();
        });
      },
      onCancel: () {
        sub1?.cancel();
        sub2?.cancel();
      },
    );

    return controller.stream;
  }

  /// Helper utility combining multiple integer count streams into a single sum stream.
  static Stream<int> combineStreams(Iterable<Stream<int>> streams) {
    final list = streams.toList();
    if (list.isEmpty) return Stream.value(0);
    if (list.length == 1) return list.first;

    late StreamController<int> controller;
    final counts = List<int>.filled(list.length, 0);
    final subs = <StreamSubscription>[];

    void emit() {
      if (!controller.isClosed) {
        controller.add(counts.fold(0, (acc, c) => acc + c));
      }
    }

    controller = StreamController<int>.broadcast(
      onListen: () {
        for (int i = 0; i < list.length; i++) {
          final index = i;
          subs.add(list[index].listen((val) {
            counts[index] = val;
            emit();
          }, onError: (_) {}));
        }
      },
      onCancel: () {
        for (final sub in subs) {
          sub.cancel();
        }
      },
    );

    return controller.stream;
  }
}
