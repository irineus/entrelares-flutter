using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    // S-10: append-only audit of ACCOUNT operations (admin grants, role/name
    // changes, e-mail changes, invitations, self-actions). Written only by DB
    // triggers/definer RPCs — the client has SELECT (family-scoped) alone.
    [Table("account_logs")]
    public class AccountLog : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("family_id")]
        public long FamilyId { get; set; }

        [Column("actor_profile_id")]
        public long? ActorProfileId { get; set; }

        [Column("target_profile_id")]
        public long? TargetProfileId { get; set; }

        [Column("action")]
        public string Action { get; set; } = string.Empty;

        [Column("old_value")]
        public string? OldValue { get; set; }

        [Column("new_value")]
        public string? NewValue { get; set; }

        [Column("created_at")]
        public DateTime CreatedAt { get; set; }
    }
}
