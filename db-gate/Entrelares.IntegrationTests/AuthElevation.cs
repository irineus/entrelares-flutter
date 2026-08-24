using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.IntegrationTests
{
    // S-10: test-only model — the app never reads auth_elevations directly
    // (the elevate Edge Function writes it; is_elevated() checks it in SQL),
    // but the suite seeds/clears rows through the service client.
    [Table("auth_elevations")]
    public class AuthElevation : BaseModel
    {
        [PrimaryKey("user_id", true)]
        public string UserId { get; set; } = string.Empty;

        [Column("elevated_until")]
        public DateTime ElevatedUntil { get; set; }
    }
}
