using System.Net;
using System.Text;
using System.Text.Json;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // U-17 — the register-invitee Edge Function: an invitee signs up through a
    // valid token and comes out PRE-CONFIRMED (immediate sign-in, no
    // confirmation e-mail), while garbage tokens and weak passwords are
    // refused. Calls the DEPLOYED function on the dev project with the anon
    // key — exactly what the register page does.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class RegisterInviteeTests(E2EFamilyFixture fx)
    {
        private static async Task<(HttpStatusCode Status, string Body)> CallAsync(object payload)
        {
            using var http = new HttpClient();
            using var request = new HttpRequestMessage(
                HttpMethod.Post, $"{TestEnv.SupabaseUrl.TrimEnd('/')}/functions/v1/register-invitee");
            // S-16: same header shape the register page uses (AuthService).
            TestEnv.ApplyKeyHeaders(request, TestEnv.AnonKey);
            request.Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
            var response = await http.SendAsync(request);
            return (response.StatusCode, await response.Content.ReadAsStringAsync());
        }

        // Calls the function repeatedly until the response reaches its TERMINAL
        // state (<paramref name="settled"/>) or the attempts run out, returning
        // the last response either way. The cross-family migration touches
        // GoTrue's Admin API (create/delete user) and a DB teardown spanning two
        // families — several of those steps are only EVENTUALLY consistent, so a
        // single call can catch a transient in-between status. Polling to the
        // terminal state absorbs that lag WITHOUT weakening the test: when the
        // terminal state genuinely never arrives (a real regression), the loop
        // exhausts and the caller's assertions fail on the last (wrong) response.
        // Same spirit as the fixture's 429 sign-in backoff.
        private static async Task<(HttpStatusCode Status, string Body)> CallUntilAsync(
            object payload, Func<HttpStatusCode, string, bool> settled,
            int attempts = 10, int delayMs = 750)
        {
            (HttpStatusCode Status, string Body) last = default;
            for (var attempt = 0; attempt < attempts; attempt++)
            {
                last = await CallAsync(payload);
                if (settled(last.Status, last.Body)) return last;
                await Task.Delay(delayMs);
            }
            return last;
        }

        [Fact] // The happy path: valid token → account created CONFIRMED —
               // signing in works immediately, and the profile joined the family.
        public async Task ValidToken_CreatesConfirmedUser_ImmediateSignIn()
        {
            var email = fx.TestEmail("autoconfirm");
            var aunt = fx.Roles.Single(r => r.RoleName == "aunt");
            var token = await E2EFamilyFixture.CreateInvitationAsync(fx.FounderB, email, aunt.Id);

            var (status, _) = await CallAsync(new { token, fullName = "E2E Autoconfirm", password = fx.Password });
            Assert.Equal(HttpStatusCode.OK, status);

            // Pre-confirmed: sign-in succeeds with no confirmation step. (With
            // an unconfirmed account GoTrue would refuse with "Email not
            // confirmed".)
            var client = await fx.SignInAsync(email);
            Assert.NotNull(client.Auth.CurrentUser);

            var profile = (await fx.Service.From<Profile>()
                .Where(p => p.Email == email)
                .Get()).Models!.Single();
            Assert.Equal(fx.FamilyBId, profile.FamilyId);
            Assert.Equal(aunt.Id, profile.RoleId);
            Assert.False(profile.IsAdmin);
        }

        [Fact] // S-11 cross-family migration: a departed member invited to another
               // family is first WARNED (409 needsMigration), then on consent the
               // old registration is erased and the new account is created.
        public async Task DepartedMember_InvitedElsewhere_WarnsThenMigratesOnConsent()
        {
            var famA = await fx.CreateFamilyAsync("xmig-a");
            var famB = await fx.CreateFamilyAsync("xmig-b");
            var email = famA.MemberProfile.Email;
            var famAName = (await fx.Service.From<Family>()
                .Where(f => f.Id == famA.FamilyId).Get()).Models!.Single().Name;

            // The member leaves family A (admin stays active → tombstone, not purge).
            await fx.ElevateAsync(famA.MemberProfile);
            await famA.Member.Rpc("request_account_deletion", new Dictionary<string, object>());

            // Invited to family B (allowed — the member is no longer active in A).
            var aunt = fx.Roles.Single(r => r.RoleName == "aunt");
            var token = await E2EFamilyFixture.CreateInvitationAsync(famB.Admin, email, aunt.Id);

            // First attempt (no consent) → warned, nothing created yet. The warn
            // call creates nothing, so it is safe to poll: retry through the
            // transient window (a 400 while the fresh invitation / just-departed
            // member aren't yet visible to the function's read, or a 409 that is
            // the plain "already registered" rejection before the departed-member
            // view is consistent) until it settles on 409 + needsMigration.
            var warnPayload = new { token, fullName = "E2E Migrante", password = fx.Password };
            var (warnStatus, warnBody) = await CallUntilAsync(
                warnPayload,
                settled: (s, b) => s == HttpStatusCode.Conflict && b.Contains("needsMigration"),
                attempts: 15, delayMs: 1000);   // ~15s: invitation/departed-member visibility
            Assert.Equal(HttpStatusCode.Conflict, warnStatus);
            Assert.Contains("needsMigration", warnBody);
            Assert.Contains(famAName, warnBody);

            // Consent given → old registration erased, new account created. A
            // non-OK response means nothing was created (createUser errored), so
            // polling never double-creates: retry through the transient window
            // where the just-freed GoTrue e-mail isn't yet re-registerable
            // (createUser still 409) until creation succeeds with 200.
            var consentPayload = new
            {
                token, fullName = "E2E Migrante", password = fx.Password, confirmMigration = true
            };
            // GoTrue's delete-old-user → create-new-user with the SAME e-mail is
            // eventually consistent: after the erase, createUser can keep 409-ing
            // for longer than a few seconds under load (run #162 exhausted the old
            // 7.5s window and failed on the trailing Conflict). Give this the most
            // generous window — the account is created on the FIRST 200 and the
            // loop stops, so the long budget only ever spends on a genuinely slow
            // GoTrue, never on the happy path.
            var (okStatus, _) = await CallUntilAsync(
                consentPayload,
                settled: (s, _) => s == HttpStatusCode.OK,
                attempts: 24, delayMs: 1250);   // ~30s ceiling for GoTrue re-registration lag
            Assert.Equal(HttpStatusCode.OK, okStatus);

            // The e-mail now belongs to a fresh profile in family B; the family-A
            // profile was tombstoned (e-mail freed, kept for history).
            var profiles = (await fx.Service.From<Profile>()
                .Where(p => p.FamilyId == famB.FamilyId).Get()).Models!;
            Assert.Contains(profiles, p => p.Email == email && p.RoleId == aunt.Id);

            var oldProfile = (await fx.Service.From<Profile>()
                .Where(p => p.Id == famA.MemberProfile.Id).Get()).Models!.Single();
            Assert.StartsWith("removido+", oldProfile.Email);

            // Sign-in works on the new account.
            var client = await fx.SignInAsync(email);
            Assert.NotNull(client.Auth.CurrentUser);
        }

        [Fact] // A garbage token creates nothing and leaks nothing.
        public async Task InvalidToken_IsRefused()
        {
            var (status, body) = await CallAsync(new
            {
                token = Guid.NewGuid().ToString(),
                fullName = "E2E Nobody",
                password = fx.Password
            });
            Assert.Equal(HttpStatusCode.BadRequest, status);
            Assert.Contains("Convite inválido", body);
        }

        [Theory] // T-32: MALFORMED tokens (not valid-UUID shapes, SQL-ish
                 // strings, path traversal) must be refused gracefully — no 500,
                 // no leak, no account created. Two layers reject them: the
                 // register-invitee function maps an invalid uuid cast to the
                 // friendly "Convite inválido" (400); attack-signature payloads
                 // (SQL injection, path traversal) are stopped earlier by the
                 // platform edge/WAF with a 403, before the function even runs.
                 // Either way it is a safe client-error refusal — assert on that,
                 // and check the friendly body only on the 400 (function) path.
        [InlineData("not-a-uuid")]
        [InlineData("'; DROP TABLE family_invitations; --")]
        [InlineData("00000000-0000-0000-0000-00000000000Z")]   // wrong UUID char
        [InlineData("../../etc/passwd")]
        [InlineData("<script>alert(1)</script>")]
        public async Task MalformedToken_IsRefusedGracefully(string token)
        {
            var (status, body) = await CallAsync(new
            {
                token,
                fullName = "E2E Malformed",
                password = fx.Password
            });
            Assert.True(
                status is HttpStatusCode.BadRequest or HttpStatusCode.Forbidden,
                $"Expected a 4xx refusal (400 from the function or 403 from the edge/WAF), got {(int)status}.");
            if (status == HttpStatusCode.BadRequest)
                Assert.Contains("Convite inválido", body);
        }

        [Fact] // The Admin API bypasses the sign-up password policy, so the
               // function enforces the register form's 8-char minimum itself.
        public async Task WeakPassword_IsRefused()
        {
            var email = fx.TestEmail("weakpass");
            var token = await E2EFamilyFixture.CreateInvitationAsync(fx.FounderB, email, fx.Roles.First().Id);

            var (status, body) = await CallAsync(new { token, fullName = "E2E Weak", password = "1234567" });
            Assert.Equal(HttpStatusCode.BadRequest, status);
            Assert.Contains("8 caracteres", body);

            // Clean up the open invitation so it doesn't hold a family-B seat.
            var tokenGuid = Guid.Parse(token);
            var invitation = (await fx.Service.From<FamilyInvitation>()
                .Where(i => i.Token == tokenGuid)
                .Get()).Models!.Single();
            await fx.FounderB.Rpc("revoke_invitation", new Dictionary<string, object>
            {
                ["p_invitation_id"] = invitation.Id
            });
        }
    }
}
