using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // S-15/A-4 — purge_stale_invitations().
    //
    // The invitation e-mail now promises: "Caso este convite não seja aceito, seu
    // registro será permanentemente expurgado de nossos sistemas em até 30 dias."
    // These tests are what keep that sentence true — and, just as importantly,
    // what stop the purge from eating the rows profiles.joined_via_invite (PR2a)
    // is derived from.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class InvitationPurgeTests(E2EFamilyFixture fx)
    {
        // Invitations are created through the real RPC (never hand-inserted: the
        // table has server-side defaults and a unique token), then backdated with a
        // targeted Set/Update — a full-model Update would serialize the computed
        // IsPending/IsExpired properties, which are not columns (PGRST204).
        private async Task<long> SeedPendingAsync(
            Supabase.Client inviter, long roleId, string tag, int ageDays)
        {
            var token = await E2EFamilyFixture.CreateInvitationAsync(
                inviter, fx.TestEmail($"purge-{tag}"), roleId);

            var tokenGuid = Guid.Parse(token);
            var row = (await fx.Service.From<FamilyInvitation>()
                .Where(i => i.Token == tokenGuid).Get()).Models!.Single();

            await Backdate(row.Id, ageDays);
            return row.Id;
        }

        private Task Backdate(long id, int ageDays) =>
            fx.Service.From<FamilyInvitation>()
                .Where(i => i.Id == id)
                .Set(i => i.CreatedAt, DateTime.UtcNow.AddDays(-ageDays))
                .Update();

        private async Task<bool> ExistsAsync(long id) =>
            (await fx.Service.From<FamilyInvitation>()
                .Where(i => i.Id == id).Get()).Models!.Count > 0;

        private Task PurgeAsync() =>
            fx.Service.Rpc("purge_stale_invitations", new Dictionary<string, object>());

        [Fact] // The promise itself: never accepted, older than 30 days → gone.
        public async Task NeverAccepted_OlderThan30Days_IsPurged()
        {
            var fam = await fx.CreateFamilyAsync("invpg1");
            var aunt = fx.Roles.Single(r => r.RoleName == "aunt");
            var stale = await SeedPendingAsync(fam.Admin, aunt.Id, "stale", ageDays: 31);

            await PurgeAsync();

            Assert.False(await ExistsAsync(stale));
        }

        [Fact] // Inside the window it stays. The promise is "em até 30 dias", and
               // the two periods in the e-mail are different things: the LINK dies
               // at 7 days, the RECORD at 30. This pins that gap — the exact point
               // the complementary parecer had to settle.
        public async Task NeverAccepted_InsideTheWindow_Survives()
        {
            var fam = await fx.CreateFamilyAsync("invpg2");
            var aunt = fx.Roles.Single(r => r.RoleName == "aunt");
            var recent = await SeedPendingAsync(fam.Admin, aunt.Id, "recent", ageDays: 10);

            await PurgeAsync();

            Assert.True(await ExistsAsync(recent));
        }

        [Fact] // THE one that protects A-1. An ACCEPTED invitation is the evidence
               // that its owner joined by invite — set_joined_via_invite() looks the
               // e-mail up in this very table on profile INSERT. Purging it would
               // silently reclassify that person as a family CREATOR and show them
               // the wrong legal declaration on the re-consent screen. Age must not
               // matter, so this backdates the fixture's own real accepted
               // invitation (the one that made the member joined_via_invite) far
               // past the window.
        public async Task Accepted_IsNeverPurged_EvenWhenAncient()
        {
            var fam = await fx.CreateFamilyAsync("invpg3");

            var accepted = (await fx.Service.From<FamilyInvitation>()
                .Where(i => i.FamilyId == fam.FamilyId).Get()).Models!
                .Single(i => i.AcceptedAt is not null);

            await Backdate(accepted.Id, ageDays: 400);
            await PurgeAsync();

            Assert.True(await ExistsAsync(accepted.Id));

            // And the marker it feeds is intact.
            var member = (await fx.Service.From<Profile>()
                .Where(p => p.Id == fam.MemberProfile.Id).Get()).Models!.Single();
            Assert.True(member.JoinedViaInvite);
        }

        [Fact] // Service-role only: a logged-in user must not be able to run it —
               // the function is SECURITY DEFINER and deletes across families.
        public async Task Purge_IsRefused_ForAuthenticatedCaller()
        {
            var fam = await fx.CreateFamilyAsync("invpg4");

            await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Member.Rpc("purge_stale_invitations", new Dictionary<string, object>()));
        }
    }
}
