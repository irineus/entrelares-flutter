using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // S-15/A-1 — the marker that decides WHICH declaration a profile is shown.
    //
    // The legal review split the two ways into a family: whoever CREATES it accepts
    // a ciência/responsabilidade term (the system has no dedicated child fields);
    // whoever is INVITED accepts confidentiality instead, holding no parental
    // authority. Register.razor knows which path it is; the re-consent gate, running
    // for profiles created long ago, does not — so the marker is persisted.
    //
    // These tests pin the DB half: the trigger classifies new sign-ups correctly and
    // the classification survives the paths that could plausibly corrupt it.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class JoinedViaInviteTests(E2EFamilyFixture fx)
    {
        [Fact] // The two entry paths land on opposite sides of the marker.
        public async Task Founder_IsNotInvited_Member_Is()
        {
            var fam = await fx.CreateFamilyAsync("jvi");

            var rows = (await fx.Service.From<Profile>()
                .Where(p => p.FamilyId == fam.FamilyId).Get()).Models!;

            Assert.False(rows.Single(p => p.Id == fam.AdminProfile.Id).JoinedViaInvite);
            Assert.True(rows.Single(p => p.Id == fam.MemberProfile.Id).JoinedViaInvite);
        }

        [Fact] // A third caregiver joining later is also an invitee — the marker is
               // about HOW you entered, not about being first or holding admin.
        public async Task ThirdCaregiver_IsMarkedAsInvited()
        {
            var third = await fx.EnsureThirdMemberAsync();

            var row = (await fx.Service.From<Profile>()
                .Where(p => p.Id == third.Id).Get()).Models!.Single();

            Assert.True(row.JoinedViaInvite);
        }

        [Fact] // The founder of the fixture's own family is not an invitee either —
               // guards against a backfill/trigger rule that matches too broadly
               // (e.g. any invitation in the family rather than to this e-mail).
        public async Task FixtureFounder_IsNotMarkedAsInvited()
        {
            var row = (await fx.Service.From<Profile>()
                .Where(p => p.Id == fx.FounderProfile.Id).Get()).Models!.Single();

            Assert.False(row.JoinedViaInvite);
        }

        // The marker must not be client-writable: it decides which legal declaration
        // a user is asked to accept, so a profile able to flip its own value could
        // route itself to the weaker text. The client CAN edit its own profile
        // (name, etc.), so the column is frozen by the trigger instead — silently,
        // because raising would break an ordinary edit that happens to send the
        // whole row back. The write is therefore accepted and simply has no effect.
        [Fact]
        public async Task Member_CannotFlipTheMarkerOnItsOwnRow()
        {
            await fx.Member.From<Profile>()
                .Where(p => p.Id == fx.MemberProfile.Id)
                .Set(p => p.JoinedViaInvite, false)
                .Update();

            var row = (await fx.Service.From<Profile>()
                .Where(p => p.Id == fx.MemberProfile.Id).Get()).Models!.Single();
            Assert.True(row.JoinedViaInvite);
        }

        // Even the service role cannot rewrite it — the freeze is in the trigger, not
        // in a policy. Worth pinning: it means a stray admin/script cannot quietly
        // change which declaration a user is shown.
        [Fact]
        public async Task ServiceRole_CannotFlipTheMarkerEither()
        {
            await fx.Service.From<Profile>()
                .Where(p => p.Id == fx.MemberProfile.Id)
                .Set(p => p.JoinedViaInvite, false)
                .Update();

            var row = (await fx.Service.From<Profile>()
                .Where(p => p.Id == fx.MemberProfile.Id).Get()).Models!.Single();
            Assert.True(row.JoinedViaInvite);
        }
    }
}
