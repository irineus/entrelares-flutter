using System.Net;
using System.Text;
using System.Text.Json;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // S-10 — server-enforced sudo mode + account audit trail:
    //   · set_member_admin refuses without an ACTIVE elevation (a stolen
    //     session token alone cannot flip admin flags);
    //   · account_logs is append-only, family-scoped and fed by DB triggers;
    //   · log_account_action only accepts the self-action whitelist;
    //   · the deployed elevate Edge Function rejects a wrong password.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class SudoElevationTests(E2EFamilyFixture fx)
    {
        [Fact] // No elevation row → the detectable ELEVATION_REQUIRED contract.
        public async Task SetMemberAdmin_WithoutElevation_IsRejected()
        {
            await fx.ClearElevationAsync(fx.FounderProfile);

            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Founder.Rpc("set_member_admin", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fx.MemberProfile.Id,
                    ["p_is_admin"] = true
                }));
            Assert.Contains("ELEVATION_REQUIRED", ex.Message);
        }

        [Fact] // An EXPIRED elevation is as good as none.
        public async Task SetMemberAdmin_WithExpiredElevation_IsRejected()
        {
            await fx.Service.From<AuthElevation>().Upsert(new AuthElevation
            {
                UserId = fx.FounderProfile.UserId,
                ElevatedUntil = DateTime.UtcNow.AddMinutes(-1)
            });

            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Founder.Rpc("set_member_admin", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fx.MemberProfile.Id,
                    ["p_is_admin"] = true
                }));
            Assert.Contains("ELEVATION_REQUIRED", ex.Message);
        }

        [Fact] // Elevated: promote + demote succeed, and both land in account_logs.
        public async Task Admin_TogglesAdminFlag_WithElevation_AndAuditTrail()
        {
            await fx.ElevateAsync(fx.FounderProfile);

            try
            {
                await fx.Founder.Rpc("set_member_admin", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fx.MemberProfile.Id,
                    ["p_is_admin"] = true
                });

                var refreshed = (await fx.Founder.From<Profile>().Get()).Models!
                    .Single(p => p.Id == fx.MemberProfile.Id);
                Assert.True(refreshed.IsAdmin);

                var granted = (await fx.Founder.From<AccountLog>().Get()).Models!
                    .Where(l => l.Action == "admin_granted" && l.TargetProfileId == fx.MemberProfile.Id);
                Assert.NotEmpty(granted);
                Assert.All(granted, l => Assert.Equal(fx.FounderProfile.Id, l.ActorProfileId));
            }
            finally
            {
                await fx.Founder.Rpc("set_member_admin", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fx.MemberProfile.Id,
                    ["p_is_admin"] = false
                });
            }

            var revoked = (await fx.Founder.From<AccountLog>().Get()).Models!
                .Where(l => l.Action == "admin_revoked" && l.TargetProfileId == fx.MemberProfile.Id);
            Assert.NotEmpty(revoked);
        }

        [Fact] // The whitelist blocks forged audit entries; a real one lands.
        public async Task LogAccountAction_EnforcesWhitelist()
        {
            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Member.Rpc("log_account_action", new Dictionary<string, object>
                {
                    ["p_action"] = "admin_granted"   // trigger-only action: forging it must fail
                }));
            Assert.Contains("não permitida", ex.Message);

            await fx.Member.Rpc("log_account_action", new Dictionary<string, object>
            {
                ["p_action"] = "data_exported"
            });

            var rows = (await fx.Member.From<AccountLog>().Get()).Models!
                .Where(l => l.Action == "data_exported" && l.ActorProfileId == fx.MemberProfile.Id);
            Assert.NotEmpty(rows);
            Assert.All(rows, l => Assert.Equal(fx.MemberProfile.Id, l.TargetProfileId));
        }

        [Fact] // RLS: family B never sees family A's account trail.
        public async Task AccountLogs_AreFamilyScoped()
        {
            // Guarantee at least one family-A row exists.
            await fx.Founder.Rpc("log_account_action", new Dictionary<string, object>
            {
                ["p_action"] = "data_exported"
            });

            var mine = (await fx.Founder.From<AccountLog>().Get()).Models ?? [];
            Assert.NotEmpty(mine);
            Assert.All(mine, l => Assert.Equal(fx.FamilyId, l.FamilyId));

            var theirs = (await fx.FounderB.From<AccountLog>().Get()).Models ?? [];
            Assert.DoesNotContain(theirs, l => l.FamilyId == fx.FamilyId);
        }

        [Fact] // QA refinement: self-actions are the author's alone; governance
               // events stay visible to the whole family (two-party oversight).
        public async Task SelfActions_VisibleOnlyToAuthor_GovernanceVisibleToFamily()
        {
            // Founder: one personal self-action + one governance round-trip.
            await fx.Founder.Rpc("log_account_action", new Dictionary<string, object>
            {
                ["p_action"] = "data_exported"
            });

            await fx.ElevateAsync(fx.FounderProfile);
            await fx.Founder.Rpc("set_member_admin", new Dictionary<string, object>
            {
                ["p_profile_id"] = fx.MemberProfile.Id,
                ["p_is_admin"] = true
            });
            await fx.Founder.Rpc("set_member_admin", new Dictionary<string, object>
            {
                ["p_profile_id"] = fx.MemberProfile.Id,
                ["p_is_admin"] = false
            });

            var memberView = (await fx.Member.From<AccountLog>().Get()).Models ?? [];

            // The member must NOT see the founder's personal actions...
            Assert.DoesNotContain(memberView,
                l => l.Action == "data_exported" && l.ActorProfileId == fx.FounderProfile.Id);

            // ...but MUST see the governance events about themselves.
            Assert.Contains(memberView,
                l => l.Action == "admin_granted" && l.TargetProfileId == fx.MemberProfile.Id);
            Assert.Contains(memberView,
                l => l.Action == "admin_revoked" && l.TargetProfileId == fx.MemberProfile.Id);

            // The author keeps seeing their own self-actions.
            var founderView = (await fx.Founder.From<AccountLog>().Get()).Models ?? [];
            Assert.Contains(founderView,
                l => l.Action == "data_exported" && l.ActorProfileId == fx.FounderProfile.Id);
        }

        [Fact] // The deployed elevate function: wrong password → 401, session untouched.
        public async Task Elevate_WithWrongPassword_IsRefused()
        {
            var accessToken = fx.Founder.Auth.CurrentSession!.AccessToken!;

            using var http = new HttpClient();
            using var request = new HttpRequestMessage(
                HttpMethod.Post, $"{TestEnv.SupabaseUrl.TrimEnd('/')}/functions/v1/elevate");
            request.Headers.Add("apikey", TestEnv.AnonKey);
            request.Headers.Add("Authorization", $"Bearer {accessToken}");
            request.Content = new StringContent(
                JsonSerializer.Serialize(new { password = "senha-errada-123" }),
                Encoding.UTF8, "application/json");

            var response = await http.SendAsync(request);
            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);

            var body = await response.Content.ReadAsStringAsync();
            Assert.Contains("Senha incorreta", body);
        }
    }
}
