import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_hub/main.dart';
import 'package:sese_hub/features/auth/login_page.dart';
import 'package:sese_hub/features/staff/services/hub_access_service.dart';

/// AuthRepository double whose only instrumented members are
/// [authStateChanges] and [signOut]; everything else is unimplemented.
class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this._stream);

  final Stream<AppUser?> _stream;
  int signOutCalls = 0;

  @override
  Stream<AppUser?> get authStateChanges => _stream;

  @override
  Future<void> signOut() async => signOutCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// HubAccessService double that replays a fixed check outcome.
class _StubAccessService extends HubAccessService {
  _StubAccessService(this._result);

  final HubAccessResult _result;

  @override
  Future<HubAccessResult> checkAccess({required String email}) async =>
      _result;
}

AppUser _staffUser() => AppUser(
      uid: 'staff-uid',
      fullName: 'Hub Staffer',
      email: 'staff@example.com',
      phoneNumber: '',
      role: UserRole.agent,
      isActive: true,
      createdAt: DateTime.now(),
      photoUrl: '',
    );

void main() {
  testWidgets('gate keeps the session and offers Retry when the hub_staff '
      'check cannot be performed', (tester) async {
    final controller = StreamController<AppUser?>.broadcast();
    final auth = _FakeAuthRepository(controller.stream);
    final access = _StubAccessService(
      const HubAccessResult.verificationError('permission-denied'),
    );

    await tester.pumpWidget(
      MyApp(authRepository: auth, accessService: access),
    );
    controller.add(_staffUser());
    await tester.pumpAndSettle();

    // Transient failure (offline / PERMISSION_DENIED): retry screen, and
    // the session is never revoked — the core ejection-loop regression.
    expect(find.text('Could not verify your access.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(auth.signOutCalls, 0);

    await controller.close();
  });

  testWidgets('gate signs an unregistered email out exactly once and shows '
      'the no-role notice', (tester) async {
    final controller = StreamController<AppUser?>.broadcast();
    final auth = _FakeAuthRepository(controller.stream);
    final access = _StubAccessService(const HubAccessResult.unqualified());

    await tester.pumpWidget(
      MyApp(authRepository: auth, accessService: access),
    );
    controller.add(_staffUser());
    await tester.pumpAndSettle();

    expect(find.text(hubAccessDeniedMessage), findsOneWidget);
    expect(find.text('Sign Out'), findsOneWidget);
    expect(auth.signOutCalls, 1);

    await controller.close();
  });

  testWidgets('gate clears cached rejections once the session ends, so a '
      're-provisioned staffer is re-checked on the next sign-in',
      (tester) async {
    final controller = StreamController<AppUser?>.broadcast();
    final auth = _FakeAuthRepository(controller.stream);
    final access = _StubAccessService(const HubAccessResult.unqualified());

    await tester.pumpWidget(
      MyApp(authRepository: auth, accessService: access),
    );

    // First sign-in: rejected + signed out once.
    controller.add(_staffUser());
    await tester.pumpAndSettle();
    expect(auth.signOutCalls, 1);

    // Session ends (the real repository emits null after signOut).
    controller.add(null);
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);

    // Second sign-in with the same email: the stale rejection must not be
    // replayed — the check runs again (still unqualified here, but a fresh
    // sign-out attempt must occur exactly once more).
    controller.add(_staffUser());
    await tester.pumpAndSettle();
    expect(auth.signOutCalls, 2);

    await controller.close();
  });

  testWidgets('qualified Super staffer lands on the dashboard without any '
      'sign-out', (tester) async {
    final controller = StreamController<AppUser?>.broadcast();
    final auth = _FakeAuthRepository(controller.stream);
    final access = _StubAccessService(const HubAccessResult.qualified(
      role: UserRole.superRole,
      isOwner: false,
      assignedPermissions: [permStaffManage],
    ));

    await tester.pumpWidget(
      MyApp(authRepository: auth, accessService: access),
    );
    controller.add(_staffUser());
    await tester.pumpAndSettle();

    expect(find.text('Fleet & Security'), findsOneWidget);
    expect(auth.signOutCalls, 0);

    await controller.close();
  });

  testWidgets('signed-out stream with no raw Firebase session shows the '
      'login page', (tester) async {
    final controller = StreamController<AppUser?>.broadcast();
    final auth = _FakeAuthRepository(controller.stream);
    final access = _StubAccessService(const HubAccessResult.unqualified());

    await tester.pumpWidget(
      MyApp(authRepository: auth, accessService: access),
    );
    controller.add(null);
    await tester.pumpAndSettle();

    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(auth.signOutCalls, 0);

    await controller.close();
  });
}
