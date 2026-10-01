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

/// Every permission the Super Admin may check off in Staff Management.
/// `staff_manage` is Super-only (enforced in the dialog and on write).
const Map<String, String> hubModuleCatalog = {
  permFleetVerify: 'Fleet & Security',
  permDynamicConfig: 'Dynamic Config',
  permStaffManage: 'Staff Management',
  permSupportChat: 'Support Inbox',
  permPayouts: 'Payout Desk',
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
enum HubTab { fleet, support, payouts, config, staff, profile }

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
      HubTab.fleet,
      HubTab.support,
      HubTab.payouts,
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
  if (granted.contains(permFleetVerify)) out.add(HubTab.fleet);
  if (granted.contains(permSupportChat)) out.add(HubTab.support);
  if (granted.contains(permPayouts)) out.add(HubTab.payouts);
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
class HubStaffRecord {
  final String email;
  final String roleRaw;
  final List<String> scopes;
  final List<String> assignedPermissions;
  final String assignedBy;
  final bool active;

  const HubStaffRecord({
    required this.email,
    required this.roleRaw,
    this.scopes = const [],
    this.assignedPermissions = const [],
    this.assignedBy = '',
    this.active = true,
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
    );
  }

  Map<String, dynamic> toMap() => {
        'email': email,
        'role': roleRaw,
        'scopes': scopes,
        'assignedPermissions': assignedPermissions,
        'assignedBy': assignedBy,
        'active': active,
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

  /// Convenience for callers that only care about pass/fail: true only when
  /// [status] is [HubAccessStatus.qualified].
  bool get qualified => status == HubAccessStatus.qualified;

  const HubAccessResult._({
    required this.status,
    required this.role,
    required this.isOwner,
    this.record,
    this.assignedPermissions = const [],
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
  }) : this._(
          status: HubAccessStatus.qualified,
          role: role,
          isOwner: isOwner,
          record: record,
          assignedPermissions: assignedPermissions,
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
    // full access to every module.
    if (isPrimaryOwnerEmail(clean)) {
      return const HubAccessResult.qualified(
        role: UserRole.superRole,
        isOwner: true,
        assignedPermissions: [
          permFleetVerify,
          permDynamicConfig,
          permStaffManage,
          permSupportChat,
        ],
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
  Future<void> provisionStaff({
    required String provisionerEmail,
    required String candidateEmail,
    required UserRole role,
    required List<String> assignedPermissions,
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
        'assignedBy': primaryOwnerEmail,
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}
