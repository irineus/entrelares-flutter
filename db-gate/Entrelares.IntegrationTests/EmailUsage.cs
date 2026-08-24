using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.IntegrationTests
{
    // F-38: test-only model — the app never reads email_usage directly (the
    // send-swap-email Edge Function consumes it via consume_email_quota in SQL),
    // but the suite seeds/reads the monthly counter through the service client.
    [Table("email_usage")]
    public class EmailUsage : BaseModel
    {
        [PrimaryKey("family_id", false)]
        public long FamilyId { get; set; }

        [PrimaryKey("year_month", false)]
        public string YearMonth { get; set; } = string.Empty;

        [Column("sent_count")]
        public int SentCount { get; set; }

        [Column("warned_80")]
        public bool WarnedEighty { get; set; }

        [Column("warned_last")]
        public bool WarnedLast { get; set; }

        [Column("upsell_notified")]
        public bool UpsellNotified { get; set; }
    }
}
