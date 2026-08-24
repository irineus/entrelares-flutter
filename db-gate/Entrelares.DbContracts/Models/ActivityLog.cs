using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    [Table("activity_logs")]
    public class ActivityLog : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("schedule_id")]
        public long? ScheduleId { get; set; }

        [Column("affected_date")]
        public DateTime AffectedDate { get; set; }

        [Column("action")]
        public string Action { get; set; } = string.Empty;

        [Column("old_data")]
        public object? OldData { get; set; }

        [Column("new_data")]
        public object? NewData { get; set; }

        [Column("performed_by_id")]
        public long? PerformedById { get; set; }

        [Column("created_at")]
        public DateTime CreatedAt { get; set; }
    }
}