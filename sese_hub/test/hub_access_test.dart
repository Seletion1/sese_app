import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_hub/features/staff/services/hub_access_service.dart';

void main() {
  group('Primary owner gate', () {
    test('returns false when primaryOwnerEmail is unconfigured', () {
      expect(isPrimaryOwnerEmail('owner@example.com'), isFalse);
      expect(isPrimaryOwnerEmail(''), isFalse);
      expect(isPrimaryOwnerEmail(null), isFalse);
    });

    test('unconfigured owner check falls through to registry without Firestore', () async {
      final service = HubAccessService();
      final result = await service.checkAccess(
        email: 'admin@example.com',
      );
      expect(result.qualified, isFalse);
      expect(result.status, HubAccessStatus.verificationError);
    });

    test('empty email fails closed without Firestore', () async {
      final service = HubAccessService();
      final result = await service.checkAccess(email: '   ');
      expect(result.qualified, isFalse);
      expect(result.status, HubAccessStatus.notRegistered);
    });

    test('Firestore being unavailable is a verification error, not "not registered"', () async {
      // Without an initialized Firebase app the registry read cannot run at
      // all. The service must report verificationError (session preserved,
      // retryable) — never notRegistered (which revokes the session).
      final service = HubAccessService();
      final result = await service.checkAccess(email: 'staff@example.com');
      expect(result.qualified, isFalse);
      expect(result.status, HubAccessStatus.verificationError);
      expect(result.error, isNotNull);
    });
  });

  group('hub_staff role parsing', () {
    test('maps Super/Admin/Agent case-insensitively', () {
      expect(parseHubStaffRole('Super'), UserRole.superRole);
      expect(parseHubStaffRole('ADMIN'), UserRole.admin);
      expect(parseHubStaffRole('agent'), UserRole.agent);
    });

    test('unknown roles fail closed', () {
      expect(parseHubStaffRole('Owner'), isNull);
      expect(parseHubStaffRole('customer'), isNull);
      expect(parseHubStaffRole(''), isNull);
      expect(parseHubStaffRole(null), isNull);
    });

    test('role names match the firestore.rules allow-list', () {
      expect(hubStaffRoleName(UserRole.superRole), 'Super');
      expect(hubStaffRoleName(UserRole.admin), 'Admin');
      expect(hubStaffRoleName(UserRole.agent), 'Agent');
    });
  });

  group('visibleTabs unified permissions', () {
    test('owner gets every tab (master control)', () {
      expect(
        visibleTabs(
            role: UserRole.superRole, isOwner: true, permissions: const []),
        [
          HubTab.activeRides,
          HubTab.fleet,
          HubTab.onboarding,
          HubTab.support,
          HubTab.payouts,
          HubTab.broadcast,
          HubTab.config,
          HubTab.staff,
          HubTab.profile,
        ],
      );
    });

    test('Super role keeps all module tabs without staff', () {
      expect(
        visibleTabs(
            role: UserRole.superRole, isOwner: false, permissions: const []),
        [
          HubTab.activeRides,
          HubTab.fleet,
          HubTab.onboarding,
          HubTab.support,
          HubTab.payouts,
          HubTab.broadcast,
          HubTab.config,
          HubTab.profile,
        ],
      );
    });

    test('staff render only explicitly granted tabs', () {
      expect(
        visibleTabs(
          role: UserRole.admin,
          isOwner: false,
          permissions: const [permFleetVerify, permSupportChat],
        ),
        [HubTab.fleet, HubTab.support, HubTab.profile],
      );
      expect(
        visibleTabs(
          role: UserRole.agent,
          isOwner: false,
          permissions: const [permDynamicConfig],
        ),
        [HubTab.config, HubTab.profile],
      );
      expect(
        visibleTabs(
            role: UserRole.admin, isOwner: false, permissions: const []),
        [HubTab.profile],
      );
      expect(
        visibleTabs(
          role: UserRole.admin,
          isOwner: false,
          permissions: const [permPayouts],
        ),
        [HubTab.payouts, HubTab.profile],
      );
    });
  });

  group('provisionStaff exclusive authority', () {
    test('non-owner provisioner is refused before any Firestore use',
        () async {
      final service = HubAccessService();
      expect(
        () => service.provisionStaff(
          provisionerEmail: 'super.staff@example.com',
          candidateEmail: 'new.agent@gmail.com',
          role: UserRole.agent,
          assignedPermissions: const [permSupportChat],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('unauthorized provisioner is rejected', () async {
      final service = HubAccessService();
      expect(
        () => service.provisionStaff(
          provisionerEmail: 'admin@example.com',
          candidateEmail: 'not-an-email',
          role: UserRole.agent,
          assignedPermissions: const [],
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('permission filtering on write', () {
    test('staff_manage is stripped for non-Super roles', () {
      expect(
        filterPermissionsForRole(UserRole.admin,
            [permFleetVerify, permStaffManage, 'nope']),
        [permFleetVerify],
      );
      expect(
        filterPermissionsForRole(
            UserRole.agent, [permSupportChat, permStaffManage]),
        [permSupportChat],
      );
    });

    test('Super retains every known module', () {
      expect(
        filterPermissionsForRole(UserRole.superRole,
            [permStaffManage, permDynamicConfig, 'nope']),
        containsAll([permStaffManage, permDynamicConfig]),
      );
    });
  });

  group('no-role denial message', () {
    test('matches the Gmail-gate spec and reveals no role', () {
      expect(
        hubAccessDeniedMessage,
        'No role assigned at the moment. Please contact administration '
        'for full access.',
      );
      final lower = hubAccessDeniedMessage.toLowerCase();
      expect(lower, isNot(contains('agent')));
      expect(lower, isNot(contains('super')));
      expect(
          RegExp(r'\badmin\b').hasMatch(
              lower.replaceFirst('administration', '')),
          isFalse);
    });
  });
}
