using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.IntegrationTests
{
    // F-58: test-only model — the app never touches platform_operators (the row
    // is seeded by migration; is_platform_operator() checks it in SQL), but the
    // suite grants/removes the flag for throwaway users through the service
    // client, which is also the documented ops path for an account created
    // after the seed migration ran.
    [Table("platform_operators")]
    public class PlatformOperator : BaseModel
    {
        [PrimaryKey("user_id", true)]
        public string UserId { get; set; } = string.Empty;

        [Column("note")]
        public string? Note { get; set; }
    }
}
