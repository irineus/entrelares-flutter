using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    // F-15: co-parent invitation. Rows are written exclusively by the
    // create_invitation / revoke_invitation RPCs; the client only reads
    // (RLS: family-scoped SELECT).
    [Table("family_invitations")]
    public class FamilyInvitation : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("family_id")]
        public long FamilyId { get; set; }

        [Column("email")]
        public string Email { get; set; } = string.Empty;

        [Column("role_id")]
        public long RoleId { get; set; }

        [Column("token")]
        public Guid Token { get; set; }

        [Column("invited_by")]
        public long InvitedBy { get; set; }

        [Column("created_at")]
        public DateTime CreatedAt { get; set; }

        [Column("expires_at")]
        public DateTime ExpiresAt { get; set; }

        [Column("accepted_at")]
        public DateTime? AcceptedAt { get; set; }

        [Column("revoked_at")]
        public DateTime? RevokedAt { get; set; }

        public bool IsPending => AcceptedAt is null && RevokedAt is null && ExpiresAt > DateTime.UtcNow;
        public bool IsExpired => AcceptedAt is null && RevokedAt is null && ExpiresAt <= DateTime.UtcNow;
    }
}
