using System.Net;
using System.Text;
using System.Text.Json;

namespace Entrelares.IntegrationTests
{
    // S-16 — the in-code authorization that REPLACED the platform's verify_jwt
    // gate. Five functions had to give the gate up: it only understands the
    // legacy JWT-based keys, so a caller presenting a new-model key
    // (`sb_secret_…` on `apikey`) is rejected at the gateway before the function
    // runs. Turning the gate off is safe only because each of those functions now
    // checks its own callers — and THAT is what this class pins.
    //
    // Without these tests the regression is invisible in the happy path: the app
    // and the crons keep working while the functions quietly answer to anyone.
    // An e-mail relay, an account purge and the auto-approval worker are exactly
    // the things that must not become anonymous endpoints.
    //
    // `register-invitee` is deliberately absent: it authorizes by invitation
    // token (its caller has no account yet and holds only the public publishable
    // key), and `RegisterInviteeTests` already covers the garbage-token refusal.
    [Trait("pack", "p0")]
    public class EdgeFunctionAuthTests
    {
        // The edge runtime answers 503 SUPABASE_EDGE_RUNTIME_SERVICE_DEGRADED while
        // a freshly deployed function is still booting, and CI redeploys ALL
        // functions on every `dev` push — minutes before this suite runs. It first
        // blocked the gate in Aug 2026: five cases red inside a TWO-SECOND window,
        // with `deployment_id`/`function_id` null in the Supabase logs and the same
        // functions answering 401 correctly on both sides of it.
        //
        // A 503 is never OUR answer: the function did not run, so there is no
        // authorization verdict to assert. Retrying only that status keeps the
        // regressions this class exists for — a 200 (wide open) or a 500 (the
        // function ran and failed later, i.e. the check is missing) — failing on
        // the first attempt, and a runtime that stays down still fails the
        // assertion with the body printed.
        private const int BootRetries = 4;

        private static async Task<(HttpStatusCode Status, string Body)> CallAsync(
            string function, string? apiKey = null, string? bearer = null)
        {
            var result = await SendAsync(function, apiKey, bearer);
            for (var attempt = 1; attempt <= BootRetries && result.Status == HttpStatusCode.ServiceUnavailable; attempt++)
            {
                await Task.Delay(TimeSpan.FromSeconds(2 * attempt));
                result = await SendAsync(function, apiKey, bearer);
            }
            return result;
        }

        private static async Task<(HttpStatusCode Status, string Body)> SendAsync(
            string function, string? apiKey, string? bearer)
        {
            using var http = new HttpClient();
            using var request = new HttpRequestMessage(
                HttpMethod.Post, $"{TestEnv.SupabaseUrl.TrimEnd('/')}/functions/v1/{function}");
            if (apiKey is not null) request.Headers.Add("apikey", apiKey);
            if (bearer is not null) request.Headers.Add("Authorization", $"Bearer {bearer}");
            request.Content = new StringContent(JsonSerializer.Serialize(new { }), Encoding.UTF8, "application/json");

            var response = await http.SendAsync(request);
            return (response.StatusCode, await response.Content.ReadAsStringAsync());
        }

        // The heart of it: no credential at all must never reach the work. A 500
        // here means the function DID run and failed later — i.e. the check is
        // missing; a 200 means it is wide open. Both are the regression.
        [Theory]
        [InlineData("auto-approve-expired")]
        [InlineData("purge-deleted")]
        [InlineData("send-swap-email")]
        [InlineData("send-account-email")]
        public async Task GatelessFunction_WithoutCredentials_Refuses(string function)
        {
            var (status, body) = await CallAsync(function);
            Assert.True(status == HttpStatusCode.Unauthorized,
                $"{function} answered {(int)status} to an anonymous call (expected 401). Body: {body}");
        }

        // A wrong secret must not pass either — the check has to compare the key,
        // not merely notice that some `apikey` header arrived.
        [Theory]
        [InlineData("auto-approve-expired")]
        [InlineData("purge-deleted")]
        [InlineData("send-swap-email")]
        [InlineData("send-account-email")]
        public async Task GatelessFunction_WithWrongSecret_Refuses(string function)
        {
            var (status, body) = await CallAsync(function, apiKey: "sb_secret_not_the_real_one");
            Assert.True(status == HttpStatusCode.Unauthorized,
                $"{function} answered {(int)status} to a bogus secret key (expected 401). Body: {body}");
        }

        // The publishable key is PUBLIC — holding it proves nothing. It must not
        // open a function whose callers are our own backends or signed-in users.
        [Theory]
        [InlineData("auto-approve-expired")]
        [InlineData("send-swap-email")]
        public async Task GatelessFunction_WithPublishableKey_Refuses(string function)
        {
            var (status, body) = await CallAsync(function, apiKey: TestEnv.AnonKey);
            Assert.True(status == HttpStatusCode.Unauthorized,
                $"{function} answered {(int)status} to the public publishable key (expected 401). Body: {body}");
        }

        // U-13: `send-auth-email` is the sixth gateless function and authorizes
        // differently from the other five — GoTrue calls it with no JWT and no
        // key, signing the body with the Standard Webhooks scheme. So the checks
        // above do not describe it, and it gets its own.
        //
        // The stake is higher here than anywhere else in this class: the function
        // sends password-reset and sign-up-confirmation mail. Open, it is a relay
        // that will mail an account-recovery link to whatever address a caller
        // names.
        [Fact]
        public async Task SendAuthEmail_WithoutASignature_Refuses()
        {
            var (status, body) = await CallAsync("send-auth-email");
            Assert.True(status == HttpStatusCode.Unauthorized,
                $"send-auth-email answered {(int)status} to an unsigned call (expected 401). Body: {body}");
        }

        // ...and the project's own keys are not a substitute for the signature.
        // A secret key opens the other five, so this pins that this function did
        // not quietly inherit their check.
        [Fact]
        public async Task SendAuthEmail_WithProjectKeys_StillRefuses()
        {
            var (anon, anonBody) = await CallAsync("send-auth-email", apiKey: TestEnv.AnonKey);
            Assert.True(anon == HttpStatusCode.Unauthorized,
                $"send-auth-email answered {(int)anon} to the publishable key (expected 401). Body: {anonBody}");

            var (secret, secretBody) = await CallAsync("send-auth-email", apiKey: TestEnv.ServiceRoleKey);
            Assert.True(secret == HttpStatusCode.Unauthorized,
                $"send-auth-email answered {(int)secret} to the secret key (expected 401). Body: {secretBody}");
        }

        // An expired/garbage session token is not a session. Guards the other half
        // of the check (the user-JWT branch), which the app's own calls rely on.
        [Fact]
        public async Task GatelessFunction_WithGarbageSession_Refuses()
        {
            var (status, body) = await CallAsync("send-swap-email", apiKey: TestEnv.AnonKey, bearer: "not.a.jwt");
            Assert.True(status == HttpStatusCode.Unauthorized,
                $"send-swap-email answered {(int)status} to a garbage session token (expected 401). Body: {body}");
        }
    }
}
