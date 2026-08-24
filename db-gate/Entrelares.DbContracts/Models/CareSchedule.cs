using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    [Table("care_schedules")]
    public class CareSchedule : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("schedule_date")]
        public DateOnly ScheduleDate { get; set; }

        [Column("handoff_time")]
        public TimeOnly? HandoffTime { get; set; }

        [Column("scheduled_parent_id")]
        public long ScheduledParentId { get; set; }

        [Column("actual_parent_id")]
        public long? ActualParentId { get; set; }

        [Column("notes")]
        public string? Notes { get; set; }

        [Column("created_at")]
        public DateTime CreatedAt { get; set; }

        [Column("updated_at")]
        public DateTime UpdatedAt { get; set; }

        // T-33: optimistic-concurrency counter. The DB increments it on every
        // UPDATE; a client update carrying a stale value is rejected with the
        // "someone got there first" message (trigger_c_enforce_schedule_revision).
        [Column("revision")]
        public int Revision { get; set; }

        // T-35: the non-guessable half of the same guard. The DB re-rolls this
        // token on every write, so it cannot be predicted from the row a client
        // already holds — unlike Revision, which a forged payload could simply
        // stamp as read+1.
        [Column("revision_token")]
        public Guid RevisionToken { get; set; }

        // T-35: the echo the DB checks against the row's current RevisionToken.
        // Computed, never stored: the trigger resets the column to NULL after
        // every write, and deriving it here (instead of assigning it at each
        // call site) is what makes it impossible for an update path to forget it
        // — every full-row Update() carries the token that was read, which is
        // the whole point of the guard. Omitting it is what a forged payload
        // would do, and the trigger rejects that.
        [Column("submitted_token")]
        public Guid? SubmittedToken
        {
            get => RevisionToken == Guid.Empty ? null : RevisionToken;
            set => _ = value;   // server-side value is always NULL; nothing to keep
        }
    }
}
