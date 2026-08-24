using System.Net;
using System.Text;
using System.Text.Json;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // T-49 — the suites drive the REAL flows, so every run used to hand the
    // fixture's throwaway addresses to Resend for real: ~86 e-mails a day, all
    // from CI, against the allowance PRODUCTION shares (one Resend account, one
    // domain — including the GoTrue SMTP that sends sign-up confirmations). The
    // functions now suppress the outbound call for `@resend.dev` recipients
    // (`_shared/mail.ts`).
    //
    // This is the red gate for that. Without it the guard is invisible when it
    // regresses: nothing in the app reads the functions' response, and no test
    // ever asserted delivery — the quota would simply start bleeding again, and
    // the first sign would be the Resend warning e-mail days later.
    //
    // It asserts the DISTINCTION, not merely "nothing was sent": `suppressed`
    // must count the message and `failed` must stay zero, which is what proves
    // the send was skipped on purpose rather than broken.
    [Collection("e2e-family")]
    [Trait("pack", "p0")]
    public class TestRecipientSuppressionTests(E2EFamilyFixture fx)
    {
        [Fact] // The app's own path: a signed-in user dispatching a swap e-mail.
        public async Task SwapEmail_ToTestRecipient_IsSuppressed_AndNotCountedAsFailure()
        {
            var request = (await fx.Member.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = fx.NextFutureDate(),
                RequestingProfileId = fx.MemberProfile.Id,
                TargetProfileId = fx.FounderProfile.Id,
                PreviousActualParentId = null,
                ProposedActualParentId = fx.MemberProfile.Id,
                Status = "pending",
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow,
            })).Models!.First();

            // S-16: the app calls with the publishable key on `apikey` and the user's
            // session on Authorization — the same shape hasValidUserSession expects.
            var accessToken = fx.Member.Auth.CurrentSession?.AccessToken;
            Assert.False(string.IsNullOrWhiteSpace(accessToken),
                "The member client has no session — the fixture sign-in did not complete.");

            using var http = new HttpClient();
            using var message = new HttpRequestMessage(
                HttpMethod.Post, $"{TestEnv.SupabaseUrl.TrimEnd('/')}/functions/v1/send-swap-email");
            message.Headers.Add("apikey", TestEnv.AnonKey);
            message.Headers.Add("Authorization", $"Bearer {accessToken}");
            message.Content = new StringContent(JsonSerializer.Serialize(new
            {
                swapRequestId = request.Id,
                emailType = "swap_requested",
                environmentPrefix = "[T-49] ",
            }), Encoding.UTF8, "application/json");

            var response = await http.SendAsync(message);
            var body = await response.Content.ReadAsStringAsync();
            Assert.True(response.StatusCode == HttpStatusCode.OK,
                $"send-swap-email answered {(int)response.StatusCode} (expected 200). Body: {body}");

            using var json = JsonDocument.Parse(body);
            var root = json.RootElement;

            Assert.True(root.TryGetProperty("suppressed", out var suppressed),
                $"The response carries no 'suppressed' count — the T-49 guard is gone " +
                $"and the fixture's e-mails are reaching Resend again. Body: {body}");
            Assert.True(suppressed.GetInt32() >= 1,
                $"Expected at least one suppressed test recipient. Body: {body}");
            Assert.Equal(0, root.GetProperty("sent").GetInt32());
            Assert.Equal(0, root.GetProperty("failed").GetInt32());
        }
    }
}
