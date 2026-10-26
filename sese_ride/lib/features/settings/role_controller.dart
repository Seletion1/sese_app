import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String? _countdownUserId;
  int? _countdownExpiresAtMs;

  static const String _sessionStateField = 'sessionState';
  static const String _activeModeField = 'activeMode';
  static const String _activeModeUpdatedAtField = 'activeModeUpdatedAtMs';
  static const String _activeTripProtectionExpiryField =
      'activeTripProtectionExpiresAtMs';

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

  /// Restores the last user-selected ride mode, choosing the newest local or
  /// server snapshot so offline mode changes survive relaunch and later sync.
  Future<UserRole> restoreSession({
    required String userId,
    required UserRole fallbackRole,
    required VoidCallback onProtectionExpired,
  }) async {
    if (userId.isEmpty) return fallbackRole;

    String? localMode;
    var localUpdatedAtMs = 0;
    int? localProtectionExpiryMs;
    try {
      final prefs = await SharedPreferences.getInstance();
      localMode = prefs.getString(_localModeKey(userId));
      localUpdatedAtMs = prefs.getInt(_localModeUpdatedAtKey(userId)) ?? 0;
      localProtectionExpiryMs =
          prefs.getInt(_localProtectionExpiryKey(userId));
    } catch (e) {
      debugPrint('RoleController.restoreSession local state failed: $e');
    }

    String? serverMode;
    var serverUpdatedAtMs = 0;
    int? serverProtectionExpiryMs;
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get()
          .timeout(const Duration(seconds: 4));
      final state = snapshot.data()?[_sessionStateField];
      if (state is Map) {
        serverMode = state[_activeModeField]?.toString();
        serverUpdatedAtMs = _asMillis(state[_activeModeUpdatedAtField]) ?? 0;
        serverProtectionExpiryMs =
            _asMillis(state[_activeTripProtectionExpiryField]);
      }
    } catch (e) {
      debugPrint('RoleController.restoreSession server state unavailable: $e');
    }

    final useServer = serverUpdatedAtMs >= localUpdatedAtMs &&
        _modeFromString(serverMode) != null;
    final restoredRole = useServer
        ? _modeFromString(serverMode)!
        : _modeFromString(localMode) ?? fallbackRole;
    setCurrentRole(restoredRole);

    if (restoredRole == UserRole.customer) {
      final expiry = (useServer
              ? serverProtectionExpiryMs
              : localProtectionExpiryMs) ??
          (useServer ? localProtectionExpiryMs : serverProtectionExpiryMs);
      if (expiry != null) {
        final remainingMs = expiry - DateTime.now().millisecondsSinceEpoch;
        if (remainingMs > 0) {
          startActiveTripCountdown(
            userId: userId,
            expiresAtMs: expiry,
            duration: Duration(milliseconds: remainingMs),
            onExpired: onProtectionExpired,
          );
        } else {
          await activateMode(userId, UserRole.driver);
          await _clearActiveTripProtection(userId);
          return UserRole.driver;
        }
      }
    }

    return restoredRole;
  }

  /// Updates the active mode in memory and writes it to both local storage
  /// and the user's server session snapshot.
  Future<void> activateMode(String userId, UserRole role) async {
    setCurrentRole(role);
    if (userId.isEmpty) return;

    if (role == UserRole.driver) {
      _cancelCountdownTimer();
      _hasActiveTripProtection = false;
      _remainingCountdownSeconds = 600;
      _countdownUserId = null;
      _countdownExpiresAtMs = null;
      _onCountdownExpired = null;
      notifyListeners();
    }

    final updatedAtMs = DateTime.now().millisecondsSinceEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_localModeKey(userId), role.name);
      await prefs.setInt(_localModeUpdatedAtKey(userId), updatedAtMs);
      if (role == UserRole.driver) {
        await prefs.remove(_localProtectionExpiryKey(userId));
      }
    } catch (e) {
      debugPrint('RoleController.activateMode local write failed: $e');
    }

    final sessionState = <String, dynamic>{
      _activeModeField: role.name,
      _activeModeUpdatedAtField: updatedAtMs,
      if (role == UserRole.driver) _activeTripProtectionExpiryField: null,
    };
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .set({_sessionStateField: sessionState}, SetOptions(merge: true))
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('RoleController.activateMode server write failed: $e');
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
          .limit(10)
          .get();

      for (final doc in snap.docs) {
        final data = doc.data();
        final customerId =
            (data['customerId'] ?? data['userId'] ?? '').toString();
        // Exclude self-booked customer orders
        if (customerId != driverId) {
          return true;
        }
      }
      return false;
    } catch (e) {
      debugPrint('RoleController.checkDriverHasActiveTrip error: $e');
      return false;
    }
  }

  /// Starts or resumes the active-trip protection timer against an absolute
  /// expiry so backgrounding or process recreation does not restart 10 minutes.
  void startActiveTripCountdown({
    required VoidCallback onExpired,
    String? userId,
    int? expiresAtMs,
    Duration duration = const Duration(minutes: 10),
  }) {
    _cancelCountdownTimer();
    _hasActiveTripProtection = true;
    _countdownUserId = userId;
    _countdownExpiresAtMs = expiresAtMs ??
        DateTime.now().add(duration).millisecondsSinceEpoch;
    _remainingCountdownSeconds = math
        .max(
          0,
          ((_countdownExpiresAtMs! - DateTime.now().millisecondsSinceEpoch) /
                  1000)
              .ceil(),
        )
        .toInt();
    _onCountdownExpired = onExpired;
    notifyListeners();

    if (userId != null) {
      unawaited(_persistActiveTripProtection(userId, _countdownExpiresAtMs!));
    }
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final expiresAt = _countdownExpiresAtMs;
      if (expiresAt == null) return;
      _remainingCountdownSeconds = math
          .max(
            0,
            ((expiresAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil(),
          )
          .toInt();
      if (_remainingCountdownSeconds == 0) {
        final expiredUserId = _countdownUserId;
        final onExpired = _onCountdownExpired;
        cancelActiveTripCountdown();
        if (expiredUserId != null) {
          unawaited(activateMode(expiredUserId, UserRole.driver));
        } else {
          setCurrentRole(UserRole.driver);
        }
        onExpired?.call();
      } else {
        notifyListeners();
      }
    });
  }

  /// Cancels any active countdown timer.
  void cancelActiveTripCountdown({String? userId}) {
    final ownerId = userId ?? _countdownUserId;
    _cancelCountdownTimer();
    _hasActiveTripProtection = false;
    _remainingCountdownSeconds = 600;
    _countdownUserId = null;
    _countdownExpiresAtMs = null;
    _onCountdownExpired = null;
    notifyListeners();
    if (ownerId != null) unawaited(_clearActiveTripProtection(ownerId));
  }

  void _cancelCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  Future<void> _persistActiveTripProtection(
    String userId,
    int expiresAtMs,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_localProtectionExpiryKey(userId), expiresAtMs);
    } catch (e) {
      debugPrint('RoleController: local trip protection save failed: $e');
    }
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .set({
            _sessionStateField: {
              _activeTripProtectionExpiryField: expiresAtMs,
            },
          }, SetOptions(merge: true))
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('RoleController: server trip protection save failed: $e');
    }
  }

  Future<void> _clearActiveTripProtection(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_localProtectionExpiryKey(userId));
    } catch (e) {
      debugPrint('RoleController: local trip protection clear failed: $e');
    }
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .set({
            _sessionStateField: {
              _activeTripProtectionExpiryField: null,
            },
          }, SetOptions(merge: true))
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('RoleController: server trip protection clear failed: $e');
    }
  }

  static String _localModeKey(String userId) => 'active_mode_$userId';
  static String _localModeUpdatedAtKey(String userId) =>
      'active_mode_updated_at_$userId';
  static String _localProtectionExpiryKey(String userId) =>
      'active_trip_protection_expires_at_$userId';

  static UserRole? _modeFromString(String? value) {
    return switch (value) {
      'customer' => UserRole.customer,
      'driver' => UserRole.driver,
      _ => null,
    };
  }

  static int? _asMillis(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is Timestamp) return value.millisecondsSinceEpoch;
    if (value is DateTime) return value.millisecondsSinceEpoch;
    return null;
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }
}
