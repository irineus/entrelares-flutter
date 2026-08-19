/// Mirror of the sign-up validation in `entrelares-app`
/// `Entrelares/Pages/Register.razor.Validate()` and of the invite form's checks
/// in `FamilyPage.razor.SendInvitation()`.
///
/// The ORDER of the sign-up checks is asserted explicitly: it is what decides
/// which single message a form with several problems shows, and the two clients
/// must pick the same one.
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

String? founder({
  String fullName = 'Ana Souza',
  String email = 'ana@example.com',
  String? familyName = 'Souza',
  String? role = 'mother',
  String password = 'segredo123',
  String? confirmPassword,
  bool acceptedTerms = true,
}) =>
    RegisterRules.validationErrorKey(
      fullName: fullName,
      email: email,
      familyName: familyName,
      role: role,
      password: password,
      confirmPassword: confirmPassword ?? password,
      acceptedTerms: acceptedTerms,
      isInvited: false,
    );

String? invited({
  String fullName = 'Bruno Souza',
  String email = 'bruno@example.com',
  String password = 'segredo123',
  String? confirmPassword,
  bool acceptedTerms = true,
}) =>
    RegisterRules.validationErrorKey(
      fullName: fullName,
      email: email,
      familyName: null,
      role: null,
      password: password,
      confirmPassword: confirmPassword ?? password,
      acceptedTerms: acceptedTerms,
      isInvited: true,
    );

void main() {
  group('sign-up — founder branch', () {
    test('a complete form passes', () {
      expect(founder(), isNull);
    });

    test('name first', () {
      expect(founder(fullName: '   '), K.registerErrorNameRequired);
    });

    test('then e-mail', () {
      expect(founder(email: ''), K.registerErrorEmailRequired);
    });

    test('then the family name', () {
      expect(founder(familyName: '  '), K.registerErrorFamilyRequired);
    });

    test('then the role', () {
      expect(founder(role: null), K.registerErrorRoleRequired);
    });

    test('then the password length', () {
      expect(founder(password: '1234567'), K.registerErrorPasswordShort);
    });

    test('exactly the minimum length is accepted', () {
      expect(founder(password: '12345678'), isNull);
    });

    test('then the confirmation', () {
      expect(founder(password: 'segredo123', confirmPassword: 'segredo124'),
          K.registerErrorPasswordMismatch);
    });

    test('consent last — the F-18 gate', () {
      expect(founder(acceptedTerms: false), K.registerErrorConsentRequired);
    });

    test('the family/role checks come BEFORE the password ones', () {
      expect(
        founder(familyName: '', password: '1'),
        K.registerErrorFamilyRequired,
      );
    });
  });

  group('sign-up — invited branch', () {
    test('a complete form passes without family or role', () {
      expect(invited(), isNull);
    });

    test('the family and role checks are skipped entirely', () {
      expect(
        RegisterRules.validationErrorKey(
          fullName: 'Bruno',
          email: 'bruno@example.com',
          familyName: null,
          role: null,
          password: 'segredo123',
          confirmPassword: 'segredo123',
          acceptedTerms: true,
          isInvited: true,
        ),
        isNull,
      );
    });

    test('but the password and consent rules still apply', () {
      expect(invited(password: 'curta'), K.registerErrorPasswordShort);
      expect(invited(acceptedTerms: false), K.registerErrorConsentRequired);
    });
  });

  test('defaultFamilyName mirrors the trigger\'s fallback', () {
    expect(RegisterRules.defaultFamilyName('  Ana Souza '), 'Família Ana Souza');
  });

  group('invite form', () {
    String? check({
      String email = 'vovo@example.com',
      String? myEmail = 'ana@example.com',
      int roleId = 3,
    }) =>
        InviteFormRules.validationErrorKey(
            email: email, myEmail: myEmail, roleId: roleId);

    test('a complete form passes', () {
      expect(check(), isNull);
    });

    test('blank and "@"-less addresses are refused', () {
      expect(check(email: '   '), K.famErrInvalidEmail);
      expect(check(email: 'vovo.example.com'), K.famErrInvalidEmail);
    });

    test('inviting yourself is refused, case-insensitively', () {
      expect(check(email: 'ANA@example.com'), K.famErrOwnEmail);
      expect(check(email: '  ana@example.com  '), K.famErrOwnEmail);
    });

    test('the role placeholder is refused', () {
      expect(check(roleId: 0), KApp.inviteErrRoleRequired);
    });

    test('the e-mail checks come before the role check', () {
      expect(check(email: '', roleId: 0), K.famErrInvalidEmail);
    });
  });

  group('invite link', () {
    test('builds the same URL the e-mail carries', () {
      expect(
        InviteFormRules.inviteLink(
            'https://web.entrelares.app', '11111111-2222-3333-4444-555555555555'),
        'https://web.entrelares.app/register?invite='
            '11111111-2222-3333-4444-555555555555',
      );
    });

    test('reads the token back out of a deep link', () {
      expect(
        InviteFormRules.inviteTokenFrom(Uri.parse(
            'https://web.entrelares.app/register?invite=abc-123')),
        'abc-123',
      );
    });

    test('a register link with no token is not an invitation', () {
      expect(
          InviteFormRules.inviteTokenFrom(
              Uri.parse('https://web.entrelares.app/register')),
          isNull);
      expect(
          InviteFormRules.inviteTokenFrom(
              Uri.parse('https://web.entrelares.app/register?invite=')),
          isNull);
    });
  });
}
