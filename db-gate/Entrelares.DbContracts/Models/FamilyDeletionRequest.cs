using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    // S-11 PR2: whole-family deletion request (multi-party consent). Read-only
    // for the client (RLS exposes SELECT to the family; every write goes
    // through the SECURITY DEFINER RPCs).
    [Table("family_deletion_requests")]
    public class FamilyDeletionRequest : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("family_id")]
        public long FamilyId { get; set; }

        [Column("requested_by")]
        public long RequestedBy { get; set; }

        [Column("requested_at")]
        public DateTime RequestedAt { get; set; }

        [Column("scheduled_for")]
        public DateTime ScheduledFor { get; set; }

        // pending | refused | withdrawn (a completed purge removes the row).
        [Column("status")]
        public string Status { get; set; } = string.Empty;

        [Column("resolved_at")]
        public DateTime? ResolvedAt { get; set; }

        [Column("resolved_by")]
        public long? ResolvedBy { get; set; }

        [Column("reminder_sent_at")]
        public DateTime? ReminderSentAt { get; set; }
    }

    // A member's explicit answer (agree/refuse) — silence is consent, so the
    // absence of a row means "aguardando".
    [Table("family_deletion_responses")]
    public class FamilyDeletionResponse : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("request_id")]
        public long RequestId { get; set; }

        [Column("profile_id")]
        public long ProfileId { get; set; }

        [Column("agreed")]
        public bool Agreed { get; set; }

        [Column("responded_at")]
        public DateTime RespondedAt { get; set; }
    }
}
