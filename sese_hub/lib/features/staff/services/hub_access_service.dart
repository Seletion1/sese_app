import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';

/// The single permanent Super Admin authority. Only this email bootstraps
/// the system and may provision staff — enforced client-side here AND
/// server-side in `firestore.rules` (`match /hub_staff/{staffEmail}`).
const String primaryOwnerEmail = 'bamiduromichael2@gmail.com';

/// Full-screen denial shown when the signed-in email has no hub_staff
/// record or no active permissions.
const String hubAccessDeniedMessage =
    'No role assigned at the moment. Please contact administration for '
    'full access.';

/// Module permission codes for pre-provisioned Gmail access. Stored on the
/// staffer's `hub_staff` record as `assignedPermissions` and enforced by
/// the nav shell ([visibleTabs]) — no separate Agent views exist.
const String permFleetVerify = 'fleet_verify';
const String permDynamicConfig = 'dynamic_config';
const String permStaffManage = 'staff_manage';
const String permSupportChat = 'support_chat';

/// Payout desk (reads `payout_requests`). Mirrors the Firestore
/// `processPayouts` scope; staff with this grant see the automated
/// withdrawal audit trail for support follow-up.
const String permPayouts = 'process_payouts';
const String permActiveRides = 'active_rides';

/// Scoped Sub-Admin permission toggles.
const String permEditFares = 'edit_fares';
const String permSuspendUsers = 'suspend_users';
const String permP2pLimits = 'p2p_limits';
const String permDocumentReview = 'document_review';

/// User and Driver Onboarding / Registration module permission code.
const String permUserOnboarding = 'user_onboarding';

/// Targeted push broadcast module (announcements + urgent alerts).
/// Super Admins always hold it; Admins/Agents need the explicit grant.
/// The `sendTargetedBroadcast` callable enforces the same rule server-side.
const String permBroadcast = 'broadcast_notifications';

/// ── Sub-section permission codes (Req: granular per-section grants) ──────
/// Each gates ONE card/section inside its module tab (see `HubModuleShell`).
/// A staffer needs the module grant AND the section code — except legacy
/// records provisioned before fine-grained codes existed (no fine codes at
/// all): those fail OPEN to every section under their granted modules so
/// existing staff are never locked out by the upgrade. Owner/Super always
/// pass. See [canSeeSection].

// Dynamic Config sections (map engine controls live inside API & Remote Keys,
// next to the keys they depend on).
const String secConfigPricing = 'config_pricing';
const String secConfigApiKeys = 'config_api_keys';
const String secConfigWallet = 'config_wallet';
const String secConfigReferral = 'config_referral';
const String secConfigDispatch = 'config_dispatch';
const String secConfigEngagement = 'config_engagement';

// Fleet & Security sections (mirrors the 7 desk tabs).
const String secFleetVehicles = 'fleet_vehicles';
const String secFleetDrivers = 'fleet_drivers';
const String secFleetCustomers = 'fleet_customers';
const String secFleetDriverKyc = 'fleet_driver_kyc';
const String secFleetCustomerKyc = 'fleet_customer_kyc';
const String secFleetCameraAudit = 'fleet_camera_audit';
const String secFleetDispatchQueue = 'fleet_dispatch_queue';

// Active Rides sections.
const String secRidesLive = 'rides_live';
const String secRidesScheduled = 'rides_scheduled';

/// Every sub-section code. Used to detect legacy records (none of these
/// present → module grant covers all its sections).
const Set<String> hubSectionCodes = {
  secConfigPricing,
  secConfigApiKeys,
  secConfigWallet,
  secConfigReferral,
  secConfigDispatch,
  secConfigEngagement,
  secFleetVehicles,
  secFleetDrivers,
  secFleetCustomers,
  secFleetDriverKyc,
  secFleetCustomerKyc,
  secFleetCameraAudit,
  secFleetDispatchQueue,
  secRidesLive,
  secRidesScheduled,
};

/// Human labels for the Staff Management section picker.
const Map<String, String> hubSectionCatalog = {
  secConfigPricing: 'Pricing Engines',
  secConfigApiKeys: 'API & Remote Keys',
  secConfigWallet: 'Wallet & Payout Rules',
  secConfigReferral: 'Referral & Revenue',
  secConfigDispatch: 'Dispatch & Trips Tuning',
  secConfigEngagement: 'Driver Engagement',
  secFleetVehicles: 'Vehicle Registrations',
  secFleetDrivers: 'Driver Directory',
  secFleetCustomers: 'Customer Directory',
  secFleetDriverKyc: 'Driver KYC Approvals',
  secFleetCustomerKyc: 'Customer KYC Approvals',
  secFleetCameraAudit: 'Camera Audit Logs',
  secFleetDispatchQueue: 'Dispatch Queue',
  secRidesLive: 'Live Rides',
  secRidesScheduled: 'Scheduled Rides',
};

/// Section visibility gate for [HubModuleShell].
///
/// - Owner/Super: always true.
/// - Otherwise the module grant is required; when [sectionPermission] is
///   null the module grant suffices; when set, legacy records carrying NO
///   fine-grained codes at all fail open (backward compat), while records
///   with any fine code must hold the specific one.
bool canSeeSection({
  required bool isOwner,
  required UserRole role,
  required List<String> permissions,
  required String modulePermission,
  String? sectionPermission,
}) {
  if (isOwner || role == UserRole.superRole) return true;
  if (!permissions.contains(modulePermission)) return false;
  if (sectionPermission == null) return true;
  final hasAnyFine = permissions.any(hubSectionCodes.contains);
  if (!hasAnyFine) return true;
  return permissions.contains(sectionPermission);
}

/// Country scope values. `global` = all jurisdictions; otherwise an
/// ISO-3166 alpha-2 code (e.g. `NG`) restricting the staffer to that
/// country's data wherever the data model carries a country field
/// (today: Active Rides trip docs via `pickupCountryCode`).
const String countryScopeGlobal = 'global';

/// Normalizes a stored scope: empty/unknown → `global`; otherwise the
/// upper-cased country code.
String normalizeCountryScope(String? raw) {
  final code = (raw ?? '').trim().toUpperCase();
  if (code.isEmpty || code == 'GLOBAL' || code == 'ALL') {
    return countryScopeGlobal;
  }
  return code;
}

/// Every permission the Super Admin may check off in Staff Management.
/// `staff_manage` is Super-only (enforced in the dialog and on write).
const Map<String, String> hubModuleCatalog = {
  permActiveRides: 'Active Rides Console',
  permFleetVerify: 'Fleet & Security',
  permUserOnboarding: 'User & Driver Onboarding',
  permDynamicConfig: 'Dynamic Config',
  permSupportChat: 'Support Inbox',
  permPayouts: 'Payout Desk',
  permEditFares: 'Edit Fares & Pricing',
  permSuspendUsers: 'Suspend Users & Drivers',
  permP2pLimits: 'P2P Limits & Wallet Rules',
  permDocumentReview: 'Document Review & KYC',
  permBroadcast: 'Broadcast Notifications',
  permStaffManage: 'Staff Management',
};

/// Permissions a non-Super staffer may retain on write. `staff_manage`
/// never lands on Admin/Agent records, even if a stale client offers it.
List<String> filterPermissionsForRole(UserRole role, List<String> permissions) {
  final known =
      permissions.where(hubModuleCatalog.containsKey).toSet();
  if (role == UserRole.superRole) return known.toList();
  return known.where((p) => p != permStaffManage).toList();
}

/// Tabs available inside Sese Hub. There are no separate Agent views:
/// everyone navigates this single permission-filtered tab set.
enum HubTab { activeRides, fleet, onboarding, support, payouts, broadcast, config, staff, profile }

/// Unified permission-based tab rendering for the nav shell
/// (HubDashboardScreen rail + bottom bar):
///
/// - Owner: every tab (permanent master control).
/// - Super role: every module tab (permanent full access); the Staff tab
///   additionally requires an explicit `staff_manage` grant, which only a
///   Super Admin may hold.
/// - Any other staffer: ONLY tabs in their `assignedPermissions`; Profile
///   is always visible. No read-only states exist — a visible module tab
///   grants full operational actions inside that module.
List<HubTab> visibleTabs({
  required UserRole role,
  required bool isOwner,
  List<String> permissions = const [],
}) {
  if (isOwner) return HubTab.values;
  if (role == UserRole.superRole) {
    return [
      HubTab.activeRides,
      HubTab.fleet,
      HubTab.onboarding,
      HubTab.support,
      HubTab.payouts,
      HubTab.broadcast,
      HubTab.config,
      if (permissions.contains(permStaffManage)) HubTab.staff,
      HubTab.profile,
    ];
  }
  if (role != UserRole.admin && role != UserRole.agent) {
    return [HubTab.profile];
  }
  final granted = permissions.toSet();
  final out = <HubTab>[];
  if (granted.contains(permActiveRides)) out.add(HubTab.activeRides);
  if (granted.contains(permFleetVerify)) out.add(HubTab.fleet);
  if (granted.contains(permUserOnboarding) || granted.contains(permDocumentReview)) {
    out.add(HubTab.onboarding);
  }
  if (granted.contains(permSupportChat)) out.add(HubTab.support);
  if (granted.contains(permPayouts)) out.add(HubTab.payouts);
  if (granted.contains(permBroadcast)) out.add(HubTab.broadcast);
  if (granted.contains(permDynamicConfig)) out.add(HubTab.config);
  if (granted.contains(permStaffManage)) out.add(HubTab.staff);
  out.add(HubTab.profile);
  return out;
}

/// True when [email] is the primary owner (case-insensitive, trimmed).
bool isPrimaryOwnerEmail(String? email) =>
    (email ?? '').trim().toLowerCase() == primaryOwnerEmail;

/// Parses a `hub_staff` role string (`Super`/`Admin`/`Agent`,
/// case-insensitive) into a [UserRole]. Returns null for anything else —
/// unknown roles fail closed (unqualified).
UserRole? parseHubStaffRole(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'super':
      return UserRole.superRole;
    case 'admin':
      return UserRole.admin;
    case 'agent':
      return UserRole.agent;
    default:
      return null;
  }
}

/// Canonical `hub_staff` role string for [role] (matches the
/// `in ['Super', 'Admin', 'Agent']` rule allow-list).
String hubStaffRoleName(UserRole role) {
  switch (role) {
    case UserRole.superRole:
      return 'Super';
    case UserRole.admin:
      return 'Admin';
    case UserRole.agent:
    case UserRole.customer:
    case UserRole.driver:
      return 'Agent';
  }
}

/// A staff record stored under `hub_staff/{email}`.
///
/// `assignedPermissions` is the authoritative module list driving
/// [visibleTabs]. `scopes` is retained read-only for records provisioned
/// before the unified permission model.
/// `countryScope` is `global` or an ISO country code (`NG`, …): staff see
/// only data from their jurisdiction wherever the data model carries a
/// country field (Active Rides today; server-side enforcement + data
/// migration for the remaining collections is tracked follow-up work).
class HubStaffRecord {
  final String email;
  final String roleRaw;
  final List<String> scopes;
  final List<String> assignedPermissions;
  final String assignedBy;
  final bool active;

  /// Normalized jurisdiction scope (`global` or e.g. `NG`).
  final String countryScope;

  const HubStaffRecord({
    required this.email,
    required this.roleRaw,
    this.scopes = const [],
    this.assignedPermissions = const [],
    this.assignedBy = '',
    this.active = true,
    this.countryScope = countryScopeGlobal,
  });

  factory HubStaffRecord.fromMap(Map<String, dynamic> map) {
    final rawScopes = map['scopes'];
    final rawPerms = map['assignedPermissions'];
    return HubStaffRecord(
      email: (map['email'] ?? '').toString(),
      roleRaw: (map['role'] ?? '').toString(),
      scopes: rawScopes is List
          ? rawScopes.map((e) => e.toString()).toList()
          : const [],
      assignedPermissions: rawPerms is List
          ? rawPerms.map((e) => e.toString()).toList()
          : const [],
      assignedBy: (map['assignedBy'] ?? '').toString(),
      active: map['active'] != false,
      countryScope: normalizeCountryScope(
        (map['countryScope'] ?? map['country_scope'] ?? map['country'])
            ?.toString(),
      ),
    );
  }

  Map<String, dynamic> toMap() => {
        'email': email,
        'role': roleRaw,
        'scopes': scopes,
        'assignedPermissions': assignedPermissions,
        'assignedBy': assignedBy,
        'active': active,
        'countryScope': countryScope,
      };
}

/// Outcome kind of the silent post-login qualification check.
enum HubAccessStatus {
  /// Owner bootstrap or an active `hub_staff` record with a known role.
  qualified,

  /// The registry was read successfully and the email definitively has no
  /// access: no hub_staff record, an inactive record, or an unknown role.
  /// Safe to revoke the session (with a logged reason + UI notice).
  notRegistered,

  /// The check itself failed (offline, PERMISSION_DENIED, App Check, …).
  /// Access is neither granted nor revoked — the caller must NOT sign the
  /// user out; offer a retry instead. This is what breaks the historic
  /// post-login ejection loop where a transient read failure was treated
  /// identically to "no staff record".
  verificationError,
}

/// Outcome of the silent post-login qualification check.
class HubAccessResult {
  final HubAccessStatus status;

  /// Failure detail when [status] is [HubAccessStatus.verificationError].
  final Object? error;

  final UserRole role;
  final bool isOwner;
  final HubStaffRecord? record;

  /// Effective module permissions: the record's `assignedPermissions`,
  /// or every module for the owner (permanent full access).
  final List<String> assignedPermissions;

  /// Effective jurisdiction scope (`global` or a country code). Owner and
  /// records without a stored scope resolve to `global`.
  final String countryScope;

  /// Convenience for callers that only care about pass/fail: true only when
  /// [status] is [HubAccessStatus.qualified].
  bool get qualified => status == HubAccessStatus.qualified;

  const HubAccessResult._({
    required this.status,
    required this.role,
    required this.isOwner,
    this.record,
    this.assignedPermissions = const [],
    this.countryScope = countryScopeGlobal,
    this.error,
  });

  const HubAccessResult.unqualified()
      : this._(
          status: HubAccessStatus.notRegistered,
          role: UserRole.customer,
          isOwner: false,
        );

  const HubAccessResult.verificationError(Object error)
      : this._(
          status: HubAccessStatus.verificationError,
          role: UserRole.customer,
          isOwner: false,
          error: error,
        );

  const HubAccessResult.qualified({
    required UserRole role,
    required bool isOwner,
    HubStaffRecord? record,
    List<String> assignedPermissions = const [],
    String countryScope = countryScopeGlobal,
  }) : this._(
          status: HubAccessStatus.qualified,
          role: role,
          isOwner: isOwner,
          record: record,
          assignedPermissions: assignedPermissions,
          countryScope: countryScope,
        );
}

/// Zero-trust gate for Sese Hub access.
///
/// Qualification rule (mirrors the spec exactly):
/// qualified ⟺ email is [primaryOwnerEmail] OR a document exists at
/// `hub_staff/{email}` with `active != false` and a known role.
class HubAccessService {
  final FirebaseFirestore? _firestore;

  const HubAccessService([this._firestore]);

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  /// Silent qualification check. Never throws.
  ///
  /// - [HubAccessStatus.qualified] ⟺ email is [primaryOwnerEmail] OR an
  ///   active `hub_staff` record with a known role exists for it.
  /// - [HubAccessStatus.notRegistered] ⟺ the registry read SUCCEEDED and
  ///   proved the email has no access (missing / inactive / unknown-role
  ///   record). The only outcome that may revoke the session.
  /// - [HubAccessStatus.verificationError] ⟺ the read itself failed
  ///   (offline, PERMISSION_DENIED, App Check). Callers must keep the
  ///   session and offer a retry — never sign out on this outcome.
  ///
  /// Primes a fresh ID token first so the `hub_staff` read (and every
  /// downstream WatchStream) never opens with stale credentials — the
  /// `UNAUTHENTICATED` retry-loop fix.
  Future<HubAccessResult> checkAccess({required String email}) async {
    final clean = email.trim();
    if (clean.isEmpty) {
      debugPrint(
          'HubAccessService.checkAccess: empty email -> not registered.');
      return const HubAccessResult.unqualified();
    }

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) await user.getIdToken(true);
    } catch (e) {
      debugPrint('HubAccessService: pre-check token refresh failed: $e');
    }

    // Owner bootstrap: permanent Super authority, no document required —
    // full access to every module (all catalog grants, including broadcast).
    if (isPrimaryOwnerEmail(clean)) {
      return HubAccessResult.qualified(
        role: UserRole.superRole,
        isOwner: true,
        assignedPermissions: hubModuleCatalog.keys.toList(),
        countryScope: countryScopeGlobal,
      );
    }

    final db = _db;
    if (db == null) {
      // Firestore unreachable (offline / not initialized): we cannot prove
      // anything either way, so this is a verification error — the session
      // must NOT be revoked for it.
      debugPrint(
        'HubAccessService.checkAccess: Firestore unavailable for "$clean" '
        '-> verification error (session preserved).',
      );
      return HubAccessResult.verificationError(
        StateError('Firestore is unavailable — check your connection.'),
      );
    }

    // Document IDs are stored lowercase; also try the exact email for
    // records provisioned before that convention.
    Object? readError;
    for (final docId in <String>{clean, clean.toLowerCase()}) {
      try {
        final snap = await db.collection('hub_staff').doc(docId).get();
        if (snap.exists && snap.data() != null) {
          final record = HubStaffRecord.fromMap(snap.data()!);
          if (!record.active) {
            debugPrint(
                'HubAccessService.checkAccess: "$docId" is inactive -> not registered.');
            return const HubAccessResult.unqualified();
          }
          final role = parseHubStaffRole(record.roleRaw);
          if (role == null) {
            debugPrint(
                'HubAccessService.checkAccess: "$docId" has unknown role '
                '"${record.roleRaw}" -> not registered.');
            return const HubAccessResult.unqualified();
          }
          return HubAccessResult.qualified(
            role: role,
            isOwner: false,
            record: record,
            assignedPermissions: record.assignedPermissions,
            countryScope: record.countryScope,
          );
        }
      } catch (e) {
        // Read failure (network / PERMISSION_DENIED / App Check): remember
        // it — if no successful read proves a record exists, this is a
        // verification error, NOT proof of "not registered".
        readError = e;
        debugPrint(
            'HubAccessService.checkAccess: hub_staff read failed for "$docId": $e');
      }
    }
    if (readError != null) {
      debugPrint(
        'HubAccessService.checkAccess: could not verify "$clean" '
        '(read error) -> verification error (session preserved).',
      );
      return HubAccessResult.verificationError(readError);
    }
    debugPrint(
        'HubAccessService.checkAccess: no hub_staff record for "$clean" -> not registered.');
    return const HubAccessResult.unqualified();
  }

  /// Pre-provisions (or re-provisions) a staff member under
  /// `hub_staff/{candidateEmail}` with an explicit module list.
  ///
  /// Exclusive authority: throws [StateError] unless [provisionerEmail] is
  /// exactly [primaryOwnerEmail] — even Super-role holders are refused.
  /// `firestore.rules` enforces the same constraint server-side.
  /// `staff_manage` is stripped for non-Super roles (Super Admin only),
  /// even if a stale client offers it.
  /// [countryScope] is `global` or an ISO country code (`NG`, …) bounding
  /// the staffer's data jurisdiction (see [HubStaffRecord.countryScope]).
  Future<void> provisionStaff({
    required String provisionerEmail,
    required String candidateEmail,
    required UserRole role,
    required List<String> assignedPermissions,
    String countryScope = countryScopeGlobal,
  }) async {
    if (!isPrimaryOwnerEmail(provisionerEmail)) {
      throw StateError(
        'Only the primary owner ($primaryOwnerEmail) can provision staff.',
      );
    }
    final candidate = candidateEmail.trim().toLowerCase();
    if (candidate.isEmpty || !candidate.contains('@')) {
      throw ArgumentError('Enter a valid Gmail address for the candidate.');
    }
    if (role != UserRole.agent &&
        role != UserRole.admin &&
        role != UserRole.superRole) {
      throw ArgumentError('Staff role must be Agent, Admin, or Super.');
    }
    final db = _db;
    if (db == null) {
      throw StateError('Firestore is unavailable. Check your connection.');
    }
    final validPermissions = filterPermissionsForRole(role, assignedPermissions);

    await db.collection('hub_staff').doc(candidate).set(
      {
        'email': candidate,
        'role': hubStaffRoleName(role),
        'assignedPermissions': validPermissions,
        'countryScope': normalizeCountryScope(countryScope),
        'assignedBy': primaryOwnerEmail,
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}
