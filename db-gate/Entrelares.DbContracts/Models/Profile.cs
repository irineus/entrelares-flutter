using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    [Table("profiles")] 
    public class Profile : BaseModel 
    {
        [PrimaryKey("id", false)] 
        public long Id { get; set; }

        [Column("user_id")]
        public string UserId { get; set; } = string.Empty;

        [Column("full_name")]
        public string FullName { get; set; } = string.Empty;

        [Column("role_id")]
        public long RoleId { get; set; }

        [Column("email")]
        public string Email { get; set; } = string.Empty;

        // F-14/S-06: family scoping + admin flag (managed exclusively by the DB;
        // the client only reads these — protection triggers block escalation).
        [Column("family_id")]
        public long FamilyId { get; set; }

        [Column("is_admin")]
        public bool IsAdmin { get; set; }

        // S-11: set when the member requests to leave the family; the account is
        // hard-deleted (GoTrue user removed, this row tombstoned) after the
        // 30-day grace. A tombstone has UserId null and LeftAt set.
        [Column("left_at")]
        public DateTime? LeftAt { get; set; }

        [Column("deletion_scheduled_for")]
        public DateTime? DeletionScheduledFor { get; set; }

        // S-11 QA: persistent color slot (1-4), assigned at join and managed by
        // the DB (reclaimed on return). Colors belong to ACTIVE members only.
        [Column("color_slot")]
        public int? ColorSlot { get; set; }

        // S-13: demonstrable LGPD consent — stamped by handle_new_user at
        // sign-up with the policy version accepted. NULL on pre-S-13 profiles.
        [Column("consent_accepted_at")]
        public DateTime? ConsentAcceptedAt { get; set; }

        [Column("consent_policy_version")]
        public string? ConsentPolicyVersion { get; set; }

        // S-15/A-1: entered the family through an invitation (set by a DB trigger
        // from family_invitations). Decides WHICH declaration the sign-up and the
        // re-consent screen show — the creator undertakes responsibility for what
        // goes into free text; the invitee, who holds no parental authority,
        // accepts confidentiality instead.
        [Column("joined_via_invite")]
        public bool JoinedViaInvite { get; set; }

        // U-13: the language this member CHOSE ("pt-BR" | "en"), NULL when they
        // never picked one. The client's own copy lives in localStorage (it must
        // work before a session exists); this column is the account-level fact,
        // and it is what LocalizationService.ShouldAdopt reads to carry a choice
        // made on one device over to another.
        [Column("language")]
        public string? Language { get; set; }

        // U-13 (pre-production round): the language this member's session actually
        // RENDERS in, recorded on sign-in. Deliberately not the same column as the
        // choice above: a detected language must never drive the adoption rule, or
        // opening the app once on an English-locale laptop would switch the user's
        // own phone. Nothing on the client reads this — it exists so the e-mail
        // senders, which have no browser to ask, know what the client already
        // knows. They read the generated `language_effective` (choice ?? detected),
        // which is not mapped here because it is not writable.
        [Column("language_detected")]
        public string? LanguageDetected { get; set; }

        // U-23: the three first-run facts the app cannot derive from family
        // state — what this person has SEEN or DECIDED. Everything else the
        // activation checklist shows (is there a second caregiver, is there a
        // plan) is read live, because a stored "done" that disagrees with the
        // family's real state is worse than no checklist at all.
        [Column("onboarding_swap_explained_at")]
        public DateTime? OnboardingSwapExplainedAt { get; set; }

        [Column("onboarding_tour_seen_at")]
        public DateTime? OnboardingTourSeenAt { get; set; }

        [Column("onboarding_dismissed_at")]
        public DateTime? OnboardingDismissedAt { get; set; }

        [Column("created_at")]
        public DateTime CreatedAt { get; set; }

        // Convenience (not mapped): a live, present member holds a family seat.
        public bool IsActiveMember => !string.IsNullOrEmpty(UserId) && LeftAt is null;
    }
}
