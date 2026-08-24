using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    [Table("swap_requests")]
    public class SwapRequest : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("schedule_date")]
        public DateOnly ScheduleDate { get; set; }

        [Column("schedule_id")]
        public long? ScheduleId { get; set; }

        [Column("requesting_profile_id")]
        public long RequestingProfileId { get; set; }

        [Column("target_profile_id")]
        public long TargetProfileId { get; set; }

        [Column("previous_actual_parent_id")]
        public long? PreviousActualParentId { get; set; }

        [Column("proposed_actual_parent_id")]
        public long ProposedActualParentId { get; set; }

        [Column("proposed_handoff_time")]
        public TimeOnly? ProposedHandoffTime { get; set; }

        [Column("status")]
        public string Status { get; set; } = "pending";

        [Column("rejection_reason")]
        public string? RejectionReason { get; set; }

        // F-44: optional message from the requester, set once at creation
        // (swap or revert). Lives on the request only — never copied to
        // care_schedules.notes (the day-scoped observation).
        [Column("request_message")]
        public string? RequestMessage { get; set; }

        // F-44: optional note from the approver, set only on approval
        // (symmetric to rejection_reason).
        [Column("approval_note")]
        public string? ApprovalNote { get; set; }

        // F-20: urgency is NOT stored — it is computed from schedule_date +
        // proposed_handoff_time against "now" (pending) or resolved_at
        // (history). See SwapRequestService.ComputePriorityTag.

        // References the activity_logs row whose old_data snapshot is the day's
        // pre-edit state; used to fully restore the day on revert approval (F-26).
        [Column("pre_edit_log_id")]
        public long? PreEditLogId { get; set; }

        // F-45: references the activity_logs row this request's RESOLUTION
        // produced (the calendar change written on approval — manual or
        // automatic). Symmetric to pre_edit_log_id, which points backwards.
        // Trigger-owned: stamp_swap_resolution_log sets it on the resolution
        // transition and preserves it on every other update, so client writes
        // to this property are inert.
        [Column("resolution_log_id")]
        public long? ResolutionLogId { get; set; }

        // F-47: on a REVERT request, whether the restore should also put the
        // day's observation (care_schedules.notes) back to the pre-edit
        // snapshot. Written once by the requester, frozen by
        // freeze_revert_notes_choice afterwards — the approver's full-row
        // update cannot flip it. false (the default) keeps the current text.
        [Column("revert_notes")]
        public bool RevertNotes { get; set; }

        // F-24: when the 24h auto-approval reminder was sent (null = not yet).
        [Column("reminder_sent_at")]
        public DateTime? ReminderSentAt { get; set; }

        // F-24: who resolved the request — 'user' (manual) or 'system' (auto-approved).
        [Column("resolved_by")]
        public string ResolvedBy { get; set; } = "user";

        [Column("created_at")]
        public DateTime CreatedAt { get; set; }

        [Column("updated_at")]
        public DateTime UpdatedAt { get; set; }

        [Column("resolved_at")]
        public DateTime? ResolvedAt { get; set; }
    }
}
