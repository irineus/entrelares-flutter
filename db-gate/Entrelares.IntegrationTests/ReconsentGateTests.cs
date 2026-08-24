using Entrelares.Helpers;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // S-15/B-4 — the server half of the re-consent gate (accept_current_policy).
    //
    // The legal review of 30/07/2026 made re-consent on a material policy change
    // obligatory, and the burden of proving consent is the controller's (LGPD art. 8
    // §1). That is why these tests care less about the happy path than about what the
    // RPC REFUSES: a version the client made up, an unauthenticated caller, a frozen
    // profile — and why a refusal must never leave a half-written record.
    //
    // Every test works on a THROWAWAY family: the shared fixture member is asserted to
    // have NULL consent columns by ConsentAndRetentionTests, and stamping it here would
    // break that test through the shared collection.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class ReconsentGateTests(E2EFamilyFixture fx)
    {
        // A version that is certainly not the current one, used as the "behind"
        // starting state. The fixture signs its users up the way Register.razor
        // really does (stamped with the CURRENT version), so each test builds the
        // precondition it needs instead of leaning on the fixture's incidental
        // state — which is also what makes these assertions about a TRANSITION.
        private const string StaleVersion = "2020-01-01";

        [Fact] // The accept stamps the CALLER's row — and nobody else's.
        public async Task Accept_CurrentVersion_StampsCallerOnly()
        {
            var fam = await fx.CreateFamilyAsync("rcacc");

            // Put BOTH rows behind, so the isolation assertion at the end is real.
            await fx.Service.From<Profile>()
                .Where(p => p.FamilyId == fam.FamilyId)
                .Set(p => p.ConsentPolicyVersion!, StaleVersion)
                .Update();

            await fam.Member.Rpc("accept_current_policy",
                new Dictionary<string, object> { ["p_version"] = PolicyVersions.Current });

            var after = (await fx.Service.From<Profile>()
                .Where(p => p.FamilyId == fam.FamilyId).Get()).Models!;

            var member = after.Single(p => p.Id == fam.MemberProfile.Id);
            Assert.Equal(PolicyVersions.Current, member.ConsentPolicyVersion);
            Assert.NotNull(member.ConsentAcceptedAt);

            // Consent is personal: accepting for myself must never stamp anyone else.
            // A record one member could create for another would be fabricated evidence.
            var admin = after.Single(p => p.Id == fam.AdminProfile.Id);
            Assert.Equal(StaleVersion, admin.ConsentPolicyVersion);
        }

        [Fact] // A version the client invents is refused — and nothing is written.
        public async Task Accept_StaleVersion_IsRefused_AndWritesNothing()
        {
            var fam = await fx.CreateFamilyAsync("rcstale");

            await fx.Service.From<Profile>()
                .Where(p => p.Id == fam.MemberProfile.Id)
                .Set(p => p.ConsentPolicyVersion!, StaleVersion)
                .Update();

            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Member.Rpc("accept_current_policy",
                    new Dictionary<string, object> { ["p_version"] = StaleVersion }));

            // The message is user-facing (the client turns it into "update the app").
            Assert.Contains("desatualizada", ex.Message, StringComparison.OrdinalIgnoreCase);

            // A refused accept must leave NO trace: the row must still carry the OLD
            // version. Stamping the wrong one would be worse than no record at all.
            var member = (await fx.Service.From<Profile>()
                .Where(p => p.Id == fam.MemberProfile.Id).Get()).Models!.Single();
            Assert.Equal(StaleVersion, member.ConsentPolicyVersion);
        }

        [Fact] // EXECUTE is granted to authenticated only — anon cannot reach it.
        public async Task Accept_Anonymous_IsRefused()
        {
            var anon = await E2EFamilyFixture.NewClientAsync(TestEnv.AnonKey);

            await Assert.ThrowsAnyAsync<Exception>(() =>
                anon.Rpc("accept_current_policy",
                    new Dictionary<string, object> { ["p_version"] = PolicyVersions.Current }));
        }

        [Fact] // S-11: a member on the way out is frozen — the profile is immutable,
               // so the accept finds no active row and is refused rather than reviving it.
        public async Task Accept_FrozenProfile_IsRefused()
        {
            var fam = await fx.CreateFamilyAsync("rcfrozen");

            await fx.ElevateAsync(fam.MemberProfile);
            await fam.Member.Rpc("request_account_deletion", new Dictionary<string, object>());

            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Member.Rpc("accept_current_policy",
                    new Dictionary<string, object> { ["p_version"] = PolicyVersions.Current }));
            Assert.Contains("não encontrado", ex.Message, StringComparison.OrdinalIgnoreCase);
        }

        [Fact] // The two-place checklist, pinned.
               //
               // A material change must bump BOTH Helpers/PolicyVersions.cs and the
               // policy.current_version setting (migration). If only the code constant
               // moves, the RPC starts refusing every accept in production — users get
               // "atualize o aplicativo" on a build that is already current, and the
               // gate blocks everyone with no way through. This test turns that into a
               // red CI gate instead of a live incident.
        public async Task CodeConstant_MatchesServerSetting()
        {
            var setting = (await fx.Service.From<AppSetting>()
                .Where(s => s.Key == "policy.current_version").Get()).Models!.SingleOrDefault();

            Assert.NotNull(setting);
            Assert.Equal(PolicyVersions.Current, setting!.Value);
        }

        [Fact] // The OTHER half of the same checklist — the notice window.
               //
               // enforce_from lives in settings so it can be adjusted without a
               // deploy, and the CLIENT mirrors it in PolicyVersions.EnforceFrom.
               // Nothing forces the two to agree at runtime: the server would keep
               // warning while the client already blocks, or the reverse — a gate
               // that enforces a date nobody published. Both are silent, and both
               // are exactly what the 15-day notice is supposed to make impossible.
               //
               // S-15 PR2b pins them at 2026-09-30, deliberately provisional: the
               // corrective migration at the dev→master promotion sets BOTH to
               // promotion date + 15, and this test is what fails if only one moves.
        public async Task EnforceFromConstant_MatchesServerSetting()
        {
            var setting = (await fx.Service.From<AppSetting>()
                .Where(s => s.Key == "policy.enforce_from").Get()).Models!.SingleOrDefault();

            Assert.NotNull(setting);
            Assert.Equal(PolicyVersions.EnforceFrom, setting!.Value);
        }
    }
}
