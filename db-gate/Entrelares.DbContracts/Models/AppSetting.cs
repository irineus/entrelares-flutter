using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    // T-41: a row of the central app-configuration table. The client can only
    // SELECT rows flagged `is_public` (RLS) and only READS them (UX mirror) — every
    // real limit is enforced server-side, so a tampered client gains nothing.
    [Table("app_settings")]
    public class AppSetting : BaseModel
    {
        [PrimaryKey("key", false)]
        public string Key { get; set; } = string.Empty;

        [Column("value")]
        public string Value { get; set; } = string.Empty;

        [Column("value_type")]
        public string ValueType { get; set; } = "string";

        [Column("category")]
        public string Category { get; set; } = "general";
    }
}
