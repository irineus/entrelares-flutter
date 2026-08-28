/// S-13/S-15 — the policy version the sign-up consent refers to, and the pure
/// decision of the re-consent gate. Ported from `entrelares-app`
/// `Entrelares/Helpers/PolicyVersions.cs`; that repo was archived with the
/// Blazor client (T-56, 25/08/2026), so this is now the only copy.
///
/// A bump is not just a record: it DRIVES the gate. Bumping [current] makes
/// every profile stamped with an older version pass through [evaluate], and
/// from [enforceFrom] the app blocks until the new text is accepted.
/// MATERIAL-CHANGE CHECKLIST, all in the same delivery — it still spans two
/// repos, but the second one is now `entrelares-site`, which holds the ONLY
/// copy of the legal TEXT: the app has no `/privacy` route of its own and links
/// straight to the landing (see `deep_link_urls.dart`).
///   0. the text itself, in `entrelares-site/public/{privacidade,termos}.html`;
///   1. [current];
///   2. [enforceFrom] = publication date + 15 days — and "publication" there is
///      the landing's `preview`→`main` promotion, which is deploy-on-demand in
///      that repo, never the merge that only reaches `preview`;
///   3. the `policy.current_version` / `policy.enforce_from` rows in
///      `app_settings` (migration) — the RPC validates against them and REFUSES
///      an accept whose version does not match, so a forgotten migration is a
///      loud failure, never a silent unconsented change;
///   4. an entry in [changeSummary] AND [changeSummaryEn], shown on the
///      acceptance screen.
library;

import 'date_math.dart';

/// S-15/B-4: what the re-consent gate decided for a profile.
enum ConsentGateState {
  /// The profile already accepted the current version — nothing to do.
  upToDate,

  /// Behind the current version, but still inside the notice window: warn,
  /// never block (legal review B-4: "aviso de 15 dias").
  notice,

  /// Behind the current version and the notice window has elapsed: the hard
  /// lock applies.
  blocked,
}

abstract final class PolicyVersions {
  /// The version the shipped policy/terms text corresponds to.
  static const String current = '2026-07-30';

  /// Date from which a missing accept of [current] blocks the app. Always the
  /// date the text becomes VISIBLE to users, plus 15 days — the window exists
  /// so the subject can READ the new text before losing access, so it counts
  /// from the production promotion, never from the QA merge.
  ///
  /// Do NOT shorten it afterwards: an already-published notice period is a
  /// promise. The migration `20260801200000_s15_enforce_from_promotion` carries
  /// the other half.
  static const String enforceFrom = '2026-08-16';

  /// [enforceFrom] parsed once. Invalid content would be an authoring mistake,
  /// and `DateTime.parse` throws rather than defaulting to "never block" — a
  /// silent default would disable the gate exactly when it matters.
  static final DateTime enforceFromDate = DateTime.parse(enforceFrom);

  /// Plain-PT-BR summary of what changed in the current version, rendered on
  /// the acceptance screen so nobody is asked to accept a diff they cannot see
  /// (LGPD art. 9 — clear and adequate information).
  static const List<String> changeSummary = [
    'Passamos a pedir uma declaração específica para cada forma de entrar numa família: quem cria a família declara ciência de que o aplicativo não possui campos próprios para dados da criança e se compromete a inserir apenas o necessário à rotina nos campos de texto livre; quem entra por convite declara manter estrita confidencialidade sobre as informações e a rotina da criança ou adolescente.',
    'Os Termos de Uso passaram a prever a suspensão preventiva e imediata do acesso do usuário restrito quando formos notificados formalmente, com cópia integral, de decisão judicial válida que restrinja o contato ou o acesso às informações da criança ou do outro responsável.',
    'A Política de Privacidade foi alinhada ao que o aplicativo realmente faz: não há coleta estruturada de dados de crianças em campos específicos — esses dados só são tratados de forma incidental, se os responsáveis optarem por inseri-los nos campos de texto livre da rotina.',
    'Passamos a informar que o nome digitado no cabeçalho do relatório em PDF é tratado de forma efêmera, apenas em memória durante a exportação, e não é armazenado em nenhum banco de dados do Serviço.',
  ];

  /// U-13 — COURTESY translation of [changeSummary], so an English reader is
  /// not asked to accept a diff in a language they cannot read. NOT a second
  /// normative text. **Entries must stay index-aligned with [changeSummary].**
  static const List<String> changeSummaryEn = [
    "We now ask for a specific declaration for each way of joining a family: whoever creates the family acknowledges that the app has no dedicated fields for the child's data and undertakes to enter only what the routine requires in the free-text fields; whoever joins through an invitation declares that they will keep strict confidentiality about the information and the routine of the child or adolescent.",
    "The Terms of Use now provide for the immediate, preventive suspension of a restricted user's access when we are formally notified, with a full copy, of a valid judicial decision restricting contact with — or access to the information of — the child or the other caregiver.",
    'The Privacy Policy was aligned with what the app actually does: there is no structured collection of children\'s data in dedicated fields — such data is only processed incidentally, if the caregivers choose to enter it into the routine\'s free-text fields.',
    "We now disclose that the name typed into the PDF report's header is handled ephemerally, in memory only during the export, and is not stored in any database of the Service.",
  ];

  /// The change summary in the reader's language.
  static List<String> changeSummaryFor({required bool english}) =>
      english ? changeSummaryEn : changeSummary;

  /// Pure decision of the re-consent gate. [stampedVersion] is
  /// `profiles.consent_policy_version` — NULL on legacy profiles, which this
  /// same gate captures on purpose (the S-13 migration deliberately left them
  /// NULL rather than backfilling, which would have fabricated evidence).
  ///
  /// The comparison is EXACT: no trim, no case-fold, no date parse. A stamp of
  /// " 2026-07-30" or "2026-7-30" is not the current version, and an unknown
  /// FUTURE version is not an acceptance either — both fall through to the
  /// notice/block decision.
  static ConsentGateState evaluate(String? stampedVersion, DateTime today) {
    if (stampedVersion == current) return ConsentGateState.upToDate;
    // Anything else — an older version OR the legacy null — needs the new
    // accept; the notice window decides whether it warns or blocks. The
    // boundary is strict, so the enforce date itself already BLOCKS.
    return dateOnly(today).isBefore(dateOnly(enforceFromDate))
        ? ConsentGateState.notice
        : ConsentGateState.blocked;
  }
}
