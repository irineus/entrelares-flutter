using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    [Table("notifications")]
    public class AppNotification : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("recipient_profile_id")]
        public long RecipientProfileId { get; set; }

        [Column("type")]
        public string Type { get; set; } = string.Empty;

        [Column("title")]
        public string Title { get; set; } = string.Empty;

        [Column("message")]
        public string Message { get; set; } = string.Empty;

        // U-13: render data for NotificationRenderer — the row's stored
        // Title/Message are a PT-BR sentence written by whoever ACTED, while the
        // reader may speak another language. NULL on every row written before
        // the item; the renderer falls back to the stored text for those.
        //
        // TYPED AS JObject, NOT string (found by NotificationParamsTests): the
        // column is JSONB, so PostgREST returns a JSON OBJECT. Binding it to a
        // string makes Newtonsoft — the serializer the Supabase SDK uses — throw
        // `Unexpected character encountered while parsing value: {` on the WHOLE
        // response. That would not have failed the notification's own rendering:
        // it would have broken every client read of the table the moment the
        // first row carried params.
        [Column("params")]
        public Newtonsoft.Json.Linq.JObject? Params { get; set; }

        /// <summary>The payload as JSON text, for <c>NotificationRenderer</c>
        /// (which parses with System.Text.Json and treats null/invalid as
        /// "fall back to the stored sentence").
        ///
        /// <para><b>[JsonIgnore] is load-bearing.</b> The Postgrest model binder
        /// serializes every PUBLIC property, mapped or not — without this the
        /// column-less <c>ParamsJson</c> rode along on INSERTs and PostgREST
        /// answered <c>PGRST204: Could not find the 'ParamsJson' column</c>,
        /// breaking EVERY notification insert (including SwapRequestService's).
        /// "Not mapped" is not the default here; it has to be declared.</para></summary>
        [Newtonsoft.Json.JsonIgnore]
        public string? ParamsJson => Params?.ToString(Newtonsoft.Json.Formatting.None);

        [Column("swap_request_id")]
        public long? SwapRequestId { get; set; }

        [Column("is_read")]
        public bool IsRead { get; set; }

        [Column("created_at")]
        public DateTime CreatedAt { get; set; }
    }
}
