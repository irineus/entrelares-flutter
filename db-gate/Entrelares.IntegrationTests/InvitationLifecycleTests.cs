using System.Text.Json;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // T-31 Suite A (integration) — the invitation lifecycle rules that live in
    // the database: revoke/resend token invalidation, the anon-facing
    // get_invite_info RPC (the pre-auth register page depends on it), and the
    // two-member cap at acceptance time.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class InvitationLifecycleTests(E2EFamilyFixture fx)
    {
        private async Task<string?> GetInviteFamilyNameAsync(string token)
        {
            // Anonymous client — exactly how the register page calls it pre-auth.
            var anon = await E2EFamilyFixture.NewClientAsync(TestEnv.AnonKey);
            var response = await anon.Rpc("get_invite_info", new Dictionary<string, object>
            {
                ["p_token"] = token
            });
            using var doc = JsonDocument.Parse(response.Content ?? "[]");
            return doc.RootElement.GetArrayLength() > 0
                ? doc.RootElement[0].GetProperty("family_name").GetString()
                : null;
        }

        [Fact] // A4 — revoking kills the token; resending issues a fresh one and
               // invalidates the previous (create_invitation revokes pending ones).
               // Runs on family B — the only one with a free seat to invite into.
        public async Task RevokeAndResend_InvalidateOldTokens()
        {
            var email = fx.TestEmail("lifecycle");
            var aunt = fx.Roles.Single(r => r.RoleName == "aunt");

            var token1 = await E2EFamilyFixture.CreateInvitationAsync(fx.FounderB, email, aunt.Id);
            Assert.NotNull(await GetInviteFamilyNameAsync(token1));

            // Revoke → token dead. (Guid hoisted: the postgrest LINQ visitor
            // cannot translate method calls inside the predicate.)
            var token1Guid = Guid.Parse(token1);
            var invitation = (await fx.Service.From<FamilyInvitation>()
                .Where(i => i.Token == token1Guid)
                .Get()).Models!.Single();
            await fx.FounderB.Rpc("revoke_invitation", new Dictionary<string, object>
            {
                ["p_invitation_id"] = invitation.Id
            });
            Assert.Null(await GetInviteFamilyNameAsync(token1));

            // Resend twice: the newest token wins, the previous dies.
            var token2 = await E2EFamilyFixture.CreateInvitationAsync(fx.FounderB, email, aunt.Id);
            var token3 = await E2EFamilyFixture.CreateInvitationAsync(fx.FounderB, email, aunt.Id);
            Assert.NotEqual(token2, token3);
            Assert.Null(await GetInviteFamilyNameAsync(token2));
            Assert.NotNull(await GetInviteFamilyNameAsync(token3));
        }

        [Fact] // D7 — get_invite_info answers anonymously for a valid pending
               // token and stays silent for garbage (no information leak).
        public async Task GetInviteInfo_AnswersAnonymously_AndHidesGarbage()
        {
            var token = await E2EFamilyFixture.CreateInvitationAsync(
                fx.FounderB, fx.TestEmail("info"), fx.Roles.First().Id);

            var familyName = await GetInviteFamilyNameAsync(token);
            Assert.StartsWith(TestEnv.E2eFamilyPrefix, familyName);

            Assert.Null(await GetInviteFamilyNameAsync(Guid.NewGuid().ToString()));
        }

        // A6 (two-member cap) was superseded by F-28: the cap is now 4 seats
        // (members + open invitations) — covered by MultiCaregiverTests.
    }
}
