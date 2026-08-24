using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.IntegrationTests
{
    // F-58: test-only model — operator_audit_logs has no client access at all
    // (service_role/Dashboard only in v1); the suite inspects it through the
    // service client to prove every operator action leaves its trail.
    [Table("operator_audit_logs")]
    public class OperatorAuditLog : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("operator_user_id")]
        public string OperatorUserId { get; set; } = string.Empty;

        [Column("action")]
        public string Action { get; set; } = string.Empty;

        [Column("family_id")]
        public long? FamilyId { get; set; }

        [Column("setting_key")]
        public string? SettingKey { get; set; }

        [Column("old_value")]
        public string? OldValue { get; set; }

        [Column("new_value")]
        public string? NewValue { get; set; }

        [Column("created_at")]
        public DateTime CreatedAt { get; set; }
    }
}
