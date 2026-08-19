/// S-15/A-1 — the declaration each path into a family accepts, alongside the
/// Privacy Policy and the Terms. Mirror of `entrelares-app`
/// `Entrelares/Helpers/ConsentDeclarations.cs`.
///
/// The legal review (adendo v2, 30/07/2026) split the two ways of entering a
/// family. Whoever CREATES it exercises parental authority and gets a *termo de
/// ciência e responsabilidade* (A-1.1): the app has no dedicated child fields,
/// so what reaches us about the child depends entirely on what that person
/// types into free text. Whoever is INVITED holds no parental authority and
/// must not consent for the child's data — they accept a confidentiality
/// declaration instead (A-1.2).
///
/// A-1.1 also decided the FORM: no extra checkbox. The declaration is folded
/// into the GENERAL acceptance — one checkbox covering policy, terms and
/// declaration.
///
/// The texts live here, not in the screens, because TWO screens render them —
/// sign-up (which knows the path from the invite token) and the re-consent gate
/// (which reads the persisted `profiles.joined_via_invite`). Sharing the
/// constant is what keeps the two from drifting into different legal texts for
/// the same person.
///
/// They are also NOT in the string catalog: a legal statement and its courtesy
/// translation must be visible in a single diff, so neither can be edited
/// alone.
library;

abstract final class ConsentDeclarations {
  /// A-1.1 — accepted by whoever creates the family.
  static const String creator =
      'Ao criar a família, declaro estar ciente de que o sistema não possui campos próprios '
      'para dados da criança. Comprometo-me, no uso da minha autoridade parental, a inserir '
      'apenas informações estritamente necessárias à rotina nos campos de texto livre.';

  /// A-1.2 — accepted by whoever joins through an invitation.
  static const String invitee =
      'Declaro ter sido convidado(a) para acessar o calendário desta família e comprometo-me '
      'a manter estrita confidencialidade sobre as informações e a rotina da '
      'criança/adolescente, utilizando o aplicativo exclusivamente para a organização da '
      'convivência.';

  /// U-13 — courtesy translation of [creator]. NOT a second legal instrument:
  /// the binding text is the PT-BR one, and the screen says so
  /// (`K.registerConsentBindingNotice`).
  static const String creatorEn =
      "By creating the family, I acknowledge that the system has no dedicated fields "
      "for the child's data. In exercising my parental authority, I undertake to enter "
      'only information strictly necessary to the routine in the free-text fields.';

  /// U-13 — courtesy translation of [invitee]. See [creatorEn].
  static const String inviteeEn =
      "I declare that I have been invited to access this family's calendar and undertake "
      'to keep strict confidentiality about the information and the routine of the '
      'child/adolescent, using the application solely to organise their care.';

  /// The declaration for a given path, in the reader's language.
  /// [joinedViaInvite] is the invite token at sign-up and
  /// `profiles.joined_via_invite` on the re-consent screen — the persisted
  /// marker exists precisely because the gate has no invite context left.
  static String forPath(bool joinedViaInvite, {bool english = false}) {
    if (english) return joinedViaInvite ? inviteeEn : creatorEn;
    return joinedViaInvite ? invitee : creator;
  }
}
