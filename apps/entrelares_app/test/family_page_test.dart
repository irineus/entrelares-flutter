// The Família page: roster, rename, invitations and the F-37 seat arithmetic.
//
// The seat rules are the interesting part, and they are asymmetric on purpose:
// a PENDING invitation holds a seat (so a family cannot invite its way past the
// cap), a DEPARTED member does not, and the invitation list is only fetched
// while a seat is free — which is also why the arithmetic reads an empty list
// at the cap without that being a bug.
import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:entrelares_app/models/family.dart';
import 'package:entrelares_app/models/family_invitation.dart';
import 'package:entrelares_app/models/member.dart';
import 'package:entrelares_app/models/role.dart';
import 'package:entrelares_app/screens/family_screen.dart';
import 'package:entrelares_app/services/admin_mode.dart';
import 'package:entrelares_app/services/sudo_service.dart';
import 'package:entrelares_app/widgets/app_l10n.dart';

import 'calendar_slice_test.dart' show FakeCustodyDataSource;

const roleMother = Role(id: 1, roleName: 'mother');
const roleFather = Role(id: 2, roleName: 'father');
const roleCustom =
    Role(id: 90, roleName: 'Vovó Coruja', familyId: 7, emoji: '🦉');

const admin = Member(
  id: 1,
  fullName: 'Ana Souza',
  colorSlot: 1,
  userId: 'u1',
  isAdmin: true,
  roleId: 1,
  email: 'ana@example.com',
);
const plain = Member(
  id: 2,
  fullName: 'Bruno Lima',
  colorSlot: 2,
  userId: 'u2',
  roleId: 2,
  email: 'bruno@example.com',
);
const departed = Member(
  id: 3,
  fullName: 'Carla Dias',
  colorSlot: 3,
  userId: 'u3',
  leftAt: '2026-07-01T00:00:00Z',
  roleId: 2,
  email: 'carla@example.com',
);

FamilyInvitation pendingInvite({int id = 10, String email = 'vovo@example.com'}) =>
    FamilyInvitation(
      id: id,
      email: email,
      roleId: 1,
      token: '11111111-2222-3333-4444-555555555555',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 5)),
    );

FamilyInvitation expiredInvite({int id = 11}) => FamilyInvitation(
      id: id,
      email: 'antigo@example.com',
      roleId: 1,
      token: '22222222-2222-3333-4444-555555555555',
      expiresAt: DateTime.now().toUtc().subtract(const Duration(days: 1)),
    );

FakeCustodyDataSource source({
  List<Member> members = const [admin, plain],
  List<FamilyInvitation> invitations = const [],
  String plan = 'free',
  Map<String, String> settings = const {},
  Member? me,
}) {
  final ds = FakeCustodyDataSource(members: members, days: [])
    ..family = Family(id: 7, name: 'Souza', plan: plan)
    ..roles = const [roleMother, roleFather, roleCustom]
    ..invitations = invitations
    ..publicSettings = settings;
  return ds;
}

Future<void> pumpFamily(
  WidgetTester tester,
  FakeCustodyDataSource ds, {
  AdminMode? adminMode,
  AppLanguage language = AppLanguage.ptBr,
  VoidCallback? onOpenCustomRoles,
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(AppL10n(
    l: Localization(language),
    setLanguage: (_) async {},
    child: MaterialApp(
      home: FamilyScreen(
        dataSource: ds,
        adminMode: adminMode ?? AdminMode(),
        sudo: SudoService(ds),
        onOpenCustomRoles: onOpenCustomRoles,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  final l = Localization(AppLanguage.ptBr);

  group('roster', () {
    testWidgets('lists members with the role label and the admin badge',
        (tester) async {
      await pumpFamily(tester, source());

      // U-28: the name owns ONE line and carries the "(você)" mark inline —
      // as two widgets sharing the row with the badges, a full legal name came
      // out four lines tall on the admin's card.
      expect(find.text('Ana Souza ${l[K.famYou]}'), findsOne);
      expect(find.text('Bruno Lima'), findsOne);
      expect(find.text('Mãe'), findsOne);
      expect(find.text('Pai'), findsOne);
      expect(find.text(l[K.famAdminBadge]), findsOne);
    });

    testWidgets('a departed member keeps their card, marked "Saiu"',
        (tester) async {
      await pumpFamily(tester, source(members: [admin, plain, departed]));

      expect(find.text('Carla Dias'), findsOne);
      expect(find.text(l[K.famLeftBadge]), findsOne);
    });

    testWidgets('a custom role renders raw, with its emoji', (tester) async {
      const withCustom = Member(
          id: 4, fullName: 'Dora Melo', userId: 'u4', roleId: 90);
      await pumpFamily(tester, source(members: [admin, withCustom]));

      expect(find.text('🦉 Vovó Coruja'), findsOne);
    });
  });

  group('rename', () {
    testWidgets('an admin sees the pencil', (tester) async {
      await pumpFamily(tester, source());

      expect(find.byIcon(Icons.edit_outlined), findsOne);
    });

    testWidgets('a non-admin does not', (tester) async {
      // The fake reports the FIRST member as "me", so ordering picks the
      // signed-in profile.
      final nonAdmin =
          FakeCustodyDataSource(members: const [plain, admin], days: [])
            ..family = const Family(id: 7, name: 'Souza', plan: 'free')
            ..roles = const [roleMother, roleFather];
      await pumpFamily(tester, nonAdmin);

      expect(find.byIcon(Icons.edit_outlined), findsNothing);
    });

    testWidgets('saves a new name', (tester) async {
      final ds = source();
      await pumpFamily(tester, ds);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Souza Lima');
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();

      expect(ds.renames, ['Souza Lima']);
    });

    testWidgets('an unchanged name writes nothing — no audit row for a no-op',
        (tester) async {
      final ds = source();
      await pumpFamily(tester, ds);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();

      expect(ds.renames, isEmpty);
    });

    testWidgets('a blank name is refused before reaching the server',
        (tester) async {
      final ds = source();
      await pumpFamily(tester, ds);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();

      expect(ds.renames, isEmpty);
      expect(find.text(l[K.famErrFamilyNameRequired]), findsOne);
    });
  });

  group('invitations and the F-37 cap', () {
    testWidgets('a free family at the free limit gets the notice, not a form',
        (tester) async {
      // 2 active members = the free cap.
      await pumpFamily(tester, source());

      expect(find.text(l[K.famFreeCapNotice]), findsOne);
      expect(find.text(l[K.famSendInvite]), findsNothing);
    });

    testWidgets('a premium family below the hard cap gets the form',
        (tester) async {
      await pumpFamily(tester, source(plan: 'premium'));

      expect(find.text(l[K.famSendInvite]), findsOne);
      expect(find.text(l[K.famFreeCapNotice]), findsNothing);
    });

    testWidgets('a PENDING invitation holds a seat', (tester) async {
      // 1 active member + 1 pending invitation = 2 seats = the free cap.
      await pumpFamily(
          tester,
          source(members: const [admin], invitations: [pendingInvite()]));

      expect(find.text(l[K.famFreeCapNotice]), findsOne);
    });

    testWidgets('a DEPARTED member holds none', (tester) async {
      await pumpFamily(
          tester, source(members: const [admin, departed], plan: 'premium'));

      expect(find.text(l[K.famSendInvite]), findsOne);
    });

    testWidgets('the whole block disappears once every seat is a live member',
        (tester) async {
      const third = Member(id: 4, fullName: 'Dora', userId: 'u4', roleId: 1);
      const fourth = Member(id: 5, fullName: 'Elis', userId: 'u5', roleId: 1);
      await pumpFamily(
          tester,
          source(
              members: const [admin, plain, third, fourth], plan: 'premium'));

      expect(find.text(l[K.famInviteSection]), findsNothing);
    });

    testWidgets('a non-admin is told invitations are not theirs to send',
        (tester) async {
      final ds = FakeCustodyDataSource(members: const [plain, admin], days: [])
        ..family = const Family(id: 7, name: 'Souza', plan: 'premium')
        ..roles = const [roleMother, roleFather];
      await pumpFamily(tester, ds);

      expect(find.text(l[K.famOnlyAdminsInvite]), findsOne);
      expect(find.text(l[K.famSendInvite]), findsNothing);
    });

    testWidgets('sends an invitation and reports the mail', (tester) async {
      final ds = source(plan: 'premium');
      await pumpFamily(tester, ds);

      await tester.enterText(
          find.widgetWithText(TextField, l[K.commonEmail]), 'vovo@example.com');
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mãe').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l[K.famSendInvite]));
      await tester.pumpAndSettle();

      expect(ds.createdInvitations,
          [{'email': 'vovo@example.com', 'roleId': 1}]);
      expect(ds.mailedInvitations, [42]);
    });

    testWidgets('refuses inviting yourself before any round-trip',
        (tester) async {
      final ds = source(plan: 'premium');
      await pumpFamily(tester, ds);

      await tester.enterText(
          find.widgetWithText(TextField, l[K.commonEmail]), 'ANA@example.com');
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mãe').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l[K.famSendInvite]));
      await tester.pumpAndSettle();

      expect(find.text(l[K.famErrOwnEmail]), findsOne);
      expect(ds.createdInvitations, isEmpty);
    });

    testWidgets('refuses a missing role with the catalogued sentence',
        (tester) async {
      final ds = source(plan: 'premium');
      await pumpFamily(tester, ds);

      await tester.enterText(
          find.widgetWithText(TextField, l[K.commonEmail]), 'vovo@example.com');
      await tester.tap(find.text(l[K.famSendInvite]));
      await tester.pumpAndSettle();

      expect(find.text(l[KApp.inviteErrRoleRequired]), findsOne);
      expect(ds.createdInvitations, isEmpty);
    });

    testWidgets('a pending invitation offers copy, share, resend and revoke',
        (tester) async {
      await pumpFamily(
          tester,
          source(
              members: const [admin],
              invitations: [pendingInvite()],
              plan: 'premium'));

      expect(find.text('vovo@example.com'), findsOne);
      expect(find.text(l[K.famInviteSentBadge]), findsOne);
      expect(find.text(l[K.famCopyLink]), findsOne);
      expect(find.text(l[KApp.commonShare]), findsOne);
      expect(find.text(l[K.famResendInvite]), findsOne);
      expect(find.text(l[K.famRevoke]), findsOne);
    });

    testWidgets('an EXPIRED invitation drops the link and explains why',
        (tester) async {
      await pumpFamily(
          tester,
          source(
              members: const [admin],
              invitations: [expiredInvite()],
              plan: 'premium'));

      expect(find.text(l[K.famInviteExpiredBadge]), findsOne);
      expect(find.text(l[K.famInviteExpiredHint]), findsOne);
      expect(find.text(l[K.famCopyLink]), findsNothing);
      expect(find.text(l[K.famResendInvite]), findsOne);
    });

    testWidgets('resending re-creates for the same address and role',
        (tester) async {
      final ds = source(
          members: const [admin],
          invitations: [expiredInvite()],
          plan: 'premium');
      await pumpFamily(tester, ds);

      await tester.tap(find.text(l[K.famResendInvite]));
      await tester.pumpAndSettle();

      expect(ds.createdInvitations,
          [{'email': 'antigo@example.com', 'roleId': 1}]);
    });

    testWidgets('revoking calls the RPC', (tester) async {
      final ds = source(
          members: const [admin],
          invitations: [pendingInvite()],
          plan: 'premium');
      await pumpFamily(tester, ds);

      await tester.tap(find.text(l[K.famRevoke]));
      await tester.pumpAndSettle();

      expect(ds.revokedInvitations, [10]);
    });

    testWidgets('the server\'s own cap refusal is shown verbatim',
        (tester) async {
      final ds = source(plan: 'premium')
        ..throwOnFamilyWrite = Exception(
            '{"code":"23514","message":"Esta família já atingiu o limite de 4 '
            'responsáveis (contando convites pendentes)."}');
      await pumpFamily(tester, ds);

      await tester.enterText(
          find.widgetWithText(TextField, l[K.commonEmail]), 'vovo@example.com');
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mãe').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l[K.famSendInvite]));
      await tester.pumpAndSettle();

      expect(find.textContaining('já atingiu o limite de 4'), findsOne);
    });
  });

  group('admin mode section', () {
    testWidgets('an admin can turn it on, and the tier copy explains F-40',
        (tester) async {
      final mode = AdminMode();
      await pumpFamily(tester, source(), adminMode: mode);

      expect(find.text(l[K.famAdminSection]), findsOne);
      expect(find.textContaining('plano gratuito'), findsWidgets);

      await tester.tap(find.text(l[K.famAdminActivate]));
      await tester.pumpAndSettle();

      expect(mode.isActive, isTrue);
      expect(find.text(l[K.famAdminActiveNote]), findsOne);
    });

    testWidgets('a premium family reads the months, not the days',
        (tester) async {
      await pumpFamily(tester, source(plan: 'premium'));

      expect(find.textContaining('Administrador (Premium)'), findsOne);
    });

    testWidgets('a non-admin never sees the section', (tester) async {
      final ds = FakeCustodyDataSource(members: const [plain, admin], days: [])
        ..family = const Family(id: 7, name: 'Souza', plan: 'free')
        ..roles = const [roleMother, roleFather];
      await pumpFamily(tester, ds);

      expect(find.text(l[K.famAdminSection]), findsNothing);
    });
  });

  testWidgets('the custom-roles link is offered from the invite form',
      (tester) async {
    var opened = false;
    await pumpFamily(tester, source(plan: 'premium'),
        onOpenCustomRoles: () => opened = true);

    await tester.tap(find.text(l[K.famCustomRolesLink]));
    await tester.pumpAndSettle();

    expect(opened, isTrue);
  });

  testWidgets('an English session renders the roster in English',
      (tester) async {
    await pumpFamily(tester, source(), language: AppLanguage.en);

    expect(find.text('Mother'), findsOne);
    expect(find.text('Father'), findsOne);
  });
}
