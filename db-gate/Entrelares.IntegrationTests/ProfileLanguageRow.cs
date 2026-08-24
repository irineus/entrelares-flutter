using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.IntegrationTests
{
    // U-13: test-only view of the three language columns.
    //
    // The app's own `Profile` model deliberately does NOT map `language_effective`
    // — it is a generated column, so PostgREST rejects any write that carries it,
    // and a mapped property is one careless full-row update away from breaking
    // every profile save. This narrow model exists so the suite can READ the
    // generated value, which is the whole point of the column: it is what the
    // e-mail Edge Functions select.
    [Table("profiles")]
    public class ProfileLanguageRow : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("language")]
        public string? Language { get; set; }

        [Column("language_detected")]
        public string? LanguageDetected { get; set; }

        // Read-only by construction: nothing here ever calls Set on it.
        [Column("language_effective")]
        public string? LanguageEffective { get; set; }
    }
}
