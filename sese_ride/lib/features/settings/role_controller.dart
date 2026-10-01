import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';

/// Driver onboarding status scenarios when a Customer attempts to switch to Driver Mode.
enum DriverOnboardingScenario {
  /// Scenario A: Fully Onboarded.
  /// User has submitted personal verification documents and vehicle details.
  /// Allowed to switch directly to Driver View.
  scenarioA,

  /// Scenario B: Missing Vehicle Only.
  /// Personal ID details are verified or submitted, but vehicle details are missing.
  /// Direct user to Add Vehicle / Manage Fleet before unlocking active driver status.
  scenarioB,

  /// Scenario C: Unverified / New.
  /// Has not completed Step 2 personal information and verification form.
  /// Prompts dialog: "Complete Driver Profile to start earning" and routes to Step 2.
  scenarioC,
}

/// Global controller managing Dual Role Switching, Cross-Onboarding, and
/// the 10-Minute Active Trip Protection Countdown.
class RoleController extends ChangeNotifier {
  static final RoleController instance = RoleController._();

  RoleController._();

  UserRole _currentRole = UserRole.customer;
  UserRole get currentRole => _currentRole;

  bool _hasActiveTripProtection = false;
  bool get hasActiveTripProtection => _hasActiveTripProtection;

  int _remainingCountdownSeconds = 600; // 10 minutes (600 seconds)
  int get remainingCountdownSeconds => _remainingCountdownSeconds;

  Timer? _countdownTimer;
  VoidCallback? _onCountdownExpired;

  /// Human-readable countdown display (e.g., "09:59").
  String get countdownDisplay {
    final minutes = (_remainingCountdownSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_remainingCountdownSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void setCurrentRole(UserRole role) {
    if (_currentRole != role) {
      _currentRole = role;
      notifyListeners();
    }
  }

  /// Checks user profile state in Firestore to determine cross-onboarding scenario
  /// when switching from Customer to Driver.
  Future<DriverOnboardingScenario> evaluateDriverEligibility(
    String uid, {
    FirebaseFirestore? firestore,
  }) async {
    if (uid.isEmpty) return DriverOnboardingScenario.scenarioC;
    final db = firestore ?? FirebaseFirestore.instance;

    try {
      final doc = await db.collection('drivers').doc(uid).get();
      if (!doc.exists || doc.data() == null) {
        return DriverOnboardingScenario.scenarioC;
      }

      final data = doc.data()!;
      final status = (data[DriverVerification.fieldStatus] ?? '').toString().toLowerCase();
      final isProfileVerified = data[DriverVerification.fieldProfileVerified] == true;
      final isVehicleVerified = data[DriverVerification.fieldVehicleVerified] == true;
      final step2Done = data['onboardingStep2CompletedAt'] != null ||
          status == DriverVerification.pending ||
          status == DriverVerification.approved;

      if (!step2Done || status == DriverVerification.pendingOnboarding) {
        return DriverOnboardingScenario.scenarioC;
      }

      // Check vehicles
      bool hasVehicles = isVehicleVerified;
      if (!hasVehicles) {
        try {
          final vehiclesSnap = await db
              .collection('drivers')
              .doc(uid)
              .collection('vehicles')
              .limit(1)
              .get();
          hasVehicles = vehiclesSnap.docs.isNotEmpty;
        } catch (_) {}
      }

      if (isProfileVerified && hasVehicles) {
        return DriverOnboardingScenario.scenarioA;
      }

      if (isProfileVerified || step2Done) {
        if (!hasVehicles) {
          return DriverOnboardingScenario.scenarioB;
        }
        return DriverOnboardingScenario.scenarioA;
      }

      return DriverOnboardingScenario.scenarioC;
    } catch (e) {
      debugPrint('RoleController.evaluateDriverEligibility error: $e');
      return DriverOnboardingScenario.scenarioC;
    }
  }

  /// Active Trip Protection Rule:
  /// Check if driver has an active order status (`accepted`, `arrived`, `in_transit`).
  ///
  /// Trips carry the assignee nested at `driver.driverId` (see
  /// `DriverStreakService.activeTripStream` and the `trips` rules) — the
  /// query must use the nested path or it never matches.
  Future<bool> checkDriverHasActiveTrip(
    String driverId, {
    FirebaseFirestore? firestore,
  }) async {
    if (driverId.isEmpty) return false;
    final db = firestore ?? FirebaseFirestore.instance;

    const activeStatuses = [
      'DRIVER_ACCEPTED',
      'DRIVER_ARRIVING',
      'DRIVER_ARRIVED',
      'IN_PROGRESS',
      'accepted',
      'arrived',
      'in_transit',
    ];

    try {
      final snap = await db
          .collection('trips')
          .where('driver.driverId', isEqualTo: driverId)
          .where('status', whereIn: activeStatuses)
          .limit(1)
          .get();

      return snap.docs.isNotEmpty;
    } catch (e) {
      debugPrint('RoleController.checkDriverHasActiveTrip error: $e');
      return false;
    }
  }

  /// Starts the 10-Minute countdown for active trip protection.
  void startActiveTripCountdown({required VoidCallback onExpired}) {
    cancelActiveTripCountdown();
    _hasActiveTripProtection = true;
    _remainingCountdownSeconds = 600; // 10 minutes
    _onCountdownExpired = onExpired;
    notifyListeners();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingCountdownSeconds > 0) {
        _remainingCountdownSeconds--;
        notifyListeners();
      } else {
        cancelActiveTripCountdown();
        _onCountdownExpired?.call();
      }
    });
  }

  /// Cancels any active countdown timer.
  void cancelActiveTripCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _hasActiveTripProtection = false;
    _remainingCountdownSeconds = 600;
    notifyListeners();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }
}
