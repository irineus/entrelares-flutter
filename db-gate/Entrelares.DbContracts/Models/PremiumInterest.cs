using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    // F-32: the soft premium waitlist — one row per family recording that a
    // member expressed interest in the (not-yet-built) premium tier. Written
    // only via the register_premium_interest RPC; RLS lets members read their
    // own family's row so the UI can show the "interesse registrado" state.
    [Table("premium_interest")]
    public class PremiumInterest : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("family_id")]
        public long FamilyId { get; set; }

        [Column("profile_id")]
        public long ProfileId { get; set; }

        [Column("feature")]
        public string? Feature { get; set; }

        [Column("created_at")]
        public DateTime CreatedAt { get; set; }
    }
}
