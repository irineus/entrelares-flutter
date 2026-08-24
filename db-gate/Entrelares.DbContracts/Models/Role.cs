using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    [Table("roles")]
    public class Role : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("role")]
        public string RoleName { get; set; } = string.Empty;

        // F-41: family-scoped custom roles — null = built-in catalog row.
        // RLS already narrows reads to built-ins + the caller's own family.
        [Column("family_id")]
        public long? FamilyId { get; set; }

        [Column("emoji")]
        public string? Emoji { get; set; }

        public bool IsCustom => FamilyId.HasValue;
    }
}
