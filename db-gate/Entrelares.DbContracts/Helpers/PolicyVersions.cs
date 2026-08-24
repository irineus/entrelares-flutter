using System;

namespace Entrelares.Helpers
{
    /// <summary>S-15/B-4: what the re-consent gate decided for a profile.</summary>
    public enum ConsentGateState
    {
        /// <summary>The profile already accepted the current version — nothing to do.</summary>
        UpToDate,

        /// <summary>Behind the current version, but still inside the notice window:
        /// warn, never block (legal review B-4: "aviso de 15 dias").</summary>
        Notice,

        /// <summary>Behind the current version and the notice window has elapsed:
        /// the hard lock applies (B-4: "o bloqueio do uso até o aceite é válido e
        /// proporcional").</summary>
        Blocked,
    }

    /// <summary>S-13: single source of the privacy-policy/terms version the
    /// sign-up consent refers to. Recorded per profile at account creation
    /// (profiles.consent_policy_version) so the consent is demonstrable
    /// (LGPD art. 8 §1). Bump this ONLY on a MATERIAL change to
    /// Privacy.razor/Terms.razor (one that alters how users' data is
    /// processed, their rights, or the risk) — bumping it forces a re-consent
    /// wave. For a purely informational/transparency edit the "Última
    /// atualização" date on the page still advances (it is the honest
    /// last-edited date), but this consent version stays put and may therefore
    /// LAG the displayed date. Example (v1.6.21, 24/07/2026): the L-09 landing
    /// newsletter disclosure was mirrored into §4/§7 — transparency only, no
    /// change to app-user processing — so the page shows 24/07 while this stays
    /// 2026-07-23. On the next material change, realign both.
    /// Realigned 2026-07-28 (T-39 PR3): billing is real — Terms §10 rewritten
    /// (Premium subscription, Asaas, cancellation/refund/CDC art. 49) and Asaas
    /// added as operator + subscription-data category in the Privacy policy —
    /// a MATERIAL change (new operator, new data category), hence the bump.
    ///
    /// S-15/B-4 (July 2026): a bump is no longer just a record — it now DRIVES
    /// the re-consent gate. Bumping <see cref="Current"/> makes every profile
    /// stamped with an older version pass through <see cref="Evaluate"/>, and
    /// from <see cref="EnforceFrom"/> the app blocks until the new text is
    /// accepted. MATERIAL-CHANGE CHECKLIST, all in the same delivery:
    ///   1. this <see cref="Current"/> constant;
    ///   2. <see cref="EnforceFrom"/> = publication date + 15 days;
    ///   3. the <c>policy.current_version</c> / <c>policy.enforce_from</c> rows in
    ///      app_settings (migration) — the RPC validates against them and REFUSES
    ///      an accept whose version does not match, so a forgotten migration is a
    ///      loud failure, never a silent unconsented change;
    ///   4. an entry in <see cref="ChangeSummary"/>, shown on the acceptance screen.
    ///
    /// Bumped 2026-07-30 (S-15 PR2b) — the FIRST bump that drives a real re-consent
    /// wave. It carries the two findings the legal review flagged as MATERIAL: the
    /// path declarations (A-1.1 creator / A-1.2 invitee, see
    /// <see cref="ConsentDeclarations"/>) and the Terms' judicial-notice suspension
    /// (A-5). The §3/§5 alignment (A-1.3) and the PDF-header disclosure (C-8) ride
    /// along in the same text but are NOT what makes it material — describing a
    /// SMALLER treatment than previously declared is a clarification in the
    /// subject's favour and would not, by itself, require a new accept.</summary>
    public static class PolicyVersions
    {
        /// <summary>The version the shipped policy/terms text corresponds to.
        /// 2026-07-30 = S-15 PR2b, the MATERIAL pair from the legal review: the
        /// path declarations at sign-up and on the re-consent screen (A-1.1/A-1.2)
        /// and the Terms' judicial-notice suspension clause (A-5).</summary>
        public const string Current = "2026-07-30";

        /// <summary>Date from which a missing accept of <see cref="Current"/> blocks
        /// the app. Legal review B-4 requires 15 days of notice, so this is always
        /// the date the text becomes VISIBLE to users, plus 15 days.
        ///
        /// PROVISIONAL, on purpose (owner's decision, 30/07/2026). 2026-09-30 is a
        /// deliberately loose placeholder, and a one-line corrective migration moves
        /// it — here and in `policy.enforce_from` — to the dev→master PROMOTION date
        /// + 15 days when that promotion happens. The 15 days exist so the subject
        /// can READ the new text before losing access, and they can only do that
        /// once it is in PRODUCTION; counting from the QA merge would burn the whole
        /// window while the text is invisible to the people it binds. Until the
        /// promotion the gate only warns, which is the correct behaviour anyway.
        ///
        /// This is the same class of mistake already made once (v1.6.35: the window
        /// ran from the TEXT's date rather than from the gate's). The rule that
        /// settles both: the window starts when the user can actually see the
        /// text.
        ///
        /// PINNED 2026-08-01 at the promotion (runbook §7 item 1): promotion date
        /// + 15 days = <c>2026-08-16</c>. The provisional 2026-09-30 was the
        /// harmless direction of the error — a window longer than designed rather
        /// than one expiring while the text was still invisible. Now that the text
        /// is actually reaching production the real window applies. Do NOT shorten
        /// it afterwards: an already-published notice period is a promise, and
        /// cutting it is worse than having left it long. The migration
        /// <c>20260801200000_s15_enforce_from_promotion</c> carries the other half —
        /// they move together or CI goes red.</summary>
        public const string EnforceFrom = "2026-08-16";

        /// <summary><see cref="EnforceFrom"/> parsed once. Invalid content would be an
        /// authoring mistake, and it fails loudly rather than defaulting to "never
        /// block" — a silent default would disable the gate exactly when it matters.</summary>
        public static readonly DateOnly EnforceFromDate = DateOnly.ParseExact(EnforceFrom, "yyyy-MM-dd");

        /// <summary>Plain-PT-BR summary of what changed in the current version,
        /// rendered on the acceptance screen so nobody is asked to accept a diff
        /// they cannot see (LGPD art. 9 — clear and adequate information).</summary>
        public static readonly string[] ChangeSummary =
        [
            "Passamos a pedir uma declaração específica para cada forma de entrar numa família: quem cria a família declara ciência de que o aplicativo não possui campos próprios para dados da criança e se compromete a inserir apenas o necessário à rotina nos campos de texto livre; quem entra por convite declara manter estrita confidencialidade sobre as informações e a rotina da criança ou adolescente.",
            "Os Termos de Uso passaram a prever a suspensão preventiva e imediata do acesso do usuário restrito quando formos notificados formalmente, com cópia integral, de decisão judicial válida que restrinja o contato ou o acesso às informações da criança ou do outro responsável.",
            "A Política de Privacidade foi alinhada ao que o aplicativo realmente faz: não há coleta estruturada de dados de crianças em campos específicos — esses dados só são tratados de forma incidental, se os responsáveis optarem por inseri-los nos campos de texto livre da rotina.",
            "Passamos a informar que o nome digitado no cabeçalho do relatório em PDF é tratado de forma efêmera, apenas em memória durante a exportação, e não é armazenado em nenhum banco de dados do Serviço.",
        ];

        /// <summary>U-13 — COURTESY translation of <see cref="ChangeSummary"/>, so an
        /// English reader is not asked to accept a diff in a language they cannot
        /// read (the same LGPD art. 9 reasoning that put the summary on screen).
        ///
        /// <para>NOT a second normative text: the binding version is the PT-BR one
        /// above, and the acceptance screen says so in English
        /// (<c>K.RegisterConsentBindingNotice</c>). It lives beside the original
        /// rather than in the string catalogue for the same reason
        /// <c>ConsentDeclarations</c> does — the two versions of one legal statement
        /// must be visible in a single diff, so neither can be edited alone.</para>
        ///
        /// <para><b>Entries must stay index-aligned with <see cref="ChangeSummary"/>.</b>
        /// A material change adds to BOTH in the same delivery; the unit test pins the
        /// counts so a forgotten half is a red gate, not a silent gap on screen.</para></summary>
        public static readonly string[] ChangeSummaryEn =
        [
            "We now ask for a specific declaration for each way of joining a family: whoever creates the family acknowledges that the app has no dedicated fields for the child's data and undertakes to enter only what the routine requires in the free-text fields; whoever joins through an invitation declares that they will keep strict confidentiality about the information and the routine of the child or adolescent.",
            "The Terms of Use now provide for the immediate, preventive suspension of a restricted user's access when we are formally notified, with a full copy, of a valid judicial decision restricting contact with — or access to the information of — the child or the other caregiver.",
            "The Privacy Policy was aligned with what the app actually does: there is no structured collection of children's data in dedicated fields — such data is only processed incidentally, if the caregivers choose to enter it into the routine's free-text fields.",
            "We now disclose that the name typed into the PDF report's header is handled ephemerally, in memory only during the export, and is not stored in any database of the Service.",
        ];

        /// <summary>The change summary in the reader's language. English is a
        /// courtesy rendering — see <see cref="ChangeSummaryEn"/>.</summary>
        public static string[] ChangeSummaryFor(bool english) => english ? ChangeSummaryEn : ChangeSummary;

        /// <summary>Pure decision of the re-consent gate. <paramref name="stampedVersion"/>
        /// is profiles.consent_policy_version — NULL on legacy profiles, which this
        /// same gate captures on purpose (the S-13 migration deliberately left them
        /// NULL rather than backfilling, which would have fabricated evidence).</summary>
        public static ConsentGateState Evaluate(string? stampedVersion, DateOnly today)
        {
            if (string.Equals(stampedVersion, Current, StringComparison.Ordinal))
                return ConsentGateState.UpToDate;

            // Anything else — an older version OR the legacy NULL — needs the new
            // accept; the notice window decides whether it warns or blocks.
            return today < EnforceFromDate ? ConsentGateState.Notice : ConsentGateState.Blocked;
        }
    }
}
