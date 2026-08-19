/// Lote 4 — the pure validations of the account surfaces: sign-up
/// (`Register.razor.Validate`) and the family invite form
/// (`FamilyPage.razor.SendInvitation`).
///
/// All of these are UX mirrors. `handle_new_user`, `register-invitee` and
/// `create_invitation` refuse the same inputs server-side and their messages
/// propagate verbatim — these exist so the user is not charged a round-trip to
/// learn that a field is blank.
library;

import 'localization/k.dart';
import 'localization/k_app.dart';

abstract final class RegisterRules {
  /// GoTrue's own minimum is configured server-side; 8 is what the web refuses
  /// upfront, and the `register-invitee` Edge Function repeats it.
  static const int minPasswordLength = 8;

  /// The web's `maxlength` on both free-text fields.
  static const int maxNameLength = 80;

  /// The sign-up form's first violation, as a catalog KEY, or null when the
  /// input may be submitted.
  ///
  /// The ORDER is part of the mirror: the family/role checks come before the
  /// password checks, and both are skipped entirely on the invited branch —
  /// an invitee has no family to name (they are joining one) and no role to
  /// pick (the invitation carries it).
  static String? validationErrorKey({
    required String fullName,
    required String email,
    required String? familyName,
    required String? role,
    required String password,
    required String confirmPassword,
    required bool acceptedTerms,
    required bool isInvited,
  }) {
    if (fullName.trim().isEmpty) return K.registerErrorNameRequired;
    if (email.trim().isEmpty) return K.registerErrorEmailRequired;
    if (!isInvited && (familyName ?? '').trim().isEmpty) {
      return K.registerErrorFamilyRequired;
    }
    if (!isInvited && role == null) return K.registerErrorRoleRequired;
    if (password.length < minPasswordLength) {
      return K.registerErrorPasswordShort;
    }
    if (password != confirmPassword) return K.registerErrorPasswordMismatch;
    if (!acceptedTerms) return K.registerErrorConsentRequired;
    return null;
  }

  /// The founder's family name when they leave the field to the trigger's
  /// default. `handle_new_user` builds `'Família ' || meta_name` from the
  /// person's own name — mirrored here only to render the hint, never sent.
  static String defaultFamilyName(String fullName) =>
      'Família ${fullName.trim()}';
}

abstract final class InviteFormRules {
  /// The invite form's first violation, as a catalog KEY, or null when it may
  /// be sent. The e-mail test is deliberately the web's shallow one (non-blank
  /// and contains "@"): `create_invitation` normalises and the address either
  /// receives the message or it does not — a stricter client regex would only
  /// refuse addresses the server accepts.
  static String? validationErrorKey({
    required String email,
    required String? myEmail,
    required int roleId,
  }) {
    final clean = email.trim();
    if (clean.isEmpty || !clean.contains('@')) return K.famErrInvalidEmail;
    if (myEmail != null && clean.toLowerCase() == myEmail.trim().toLowerCase()) {
      return K.famErrOwnEmail;
    }
    if (roleId == 0) return KApp.inviteErrRoleRequired;
    return null;
  }

  /// The invite link a pending invitation resolves to — the same string the
  /// e-mail carries, so the copyable fallback and the message cannot diverge.
  /// It is an App Link: on a device with the app installed and the domain
  /// verified, Android opens `/register?invite=…` in the app; anywhere else it
  /// degrades to the web page.
  static String inviteLink(String webOrigin, String token) =>
      '$webOrigin/register?invite=$token';

  /// The `invite` query parameter of an incoming deep link, or null when the
  /// URI is not an invitation. Kept here so the router and the register screen
  /// read the token the same way.
  static String? inviteTokenFrom(Uri uri) {
    final token = uri.queryParameters['invite'];
    return (token == null || token.trim().isEmpty) ? null : token.trim();
  }
}
