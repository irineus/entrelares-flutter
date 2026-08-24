using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    [Table("families")]
    public class Family : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("name")]
        public string Name { get; set; } = string.Empty;

        [Column("created_at")]
        public DateTime CreatedAt { get; set; }

        // F-32: freemium plan. "free" (default) or "premium". Written only by the
        // service-role RPC set_family_plan (never by the client).
        [Column("plan")]
        public string Plan { get; set; } = "free";

        // F-32: end of the 30-day Premium trial (UTC). Null on grandfathered
        // premium families and after a family drops back to free.
        [Column("trial_ends_at")]
        public DateTime? TrialEndsAt { get; set; }

        // F-58: permanent courtesy Premium (comp), granted only by the platform
        // operator's RPC (admin_set_comp). Orthogonal to plan/trial — a billing
        // downgrade never clears it. Null = no comp.
        [Column("comp_premium_at")]
        public DateTime? CompPremiumAt { get; set; }
    }
}
