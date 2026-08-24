using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.IntegrationTests
{
    // F-58: test-only model — the app's AppSetting model declares its key with
    // shouldInsert=false (the client never writes settings), which would make a
    // service-client Insert silently DROP the key. This twin exists solely so
    // the suite can seed/delete a throwaway settings row.
    [Table("app_settings")]
    public class AppSettingSeed : BaseModel
    {
        [PrimaryKey("key", true)]
        public string Key { get; set; } = string.Empty;

        [Column("value")]
        public string Value { get; set; } = string.Empty;

        [Column("value_type")]
        public string ValueType { get; set; } = "string";

        [Column("category")]
        public string Category { get; set; } = "general";
    }
}
