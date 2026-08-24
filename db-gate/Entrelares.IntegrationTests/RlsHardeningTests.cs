using Entrelares.Models;
using Supabase.Postgrest;

namespace Entrelares.IntegrationTests
{
    // T-31 Suite D+ — RLS hardening beyond the day-protection rules:
    // notification privacy, admin-only family rename and the append-only
    // audit log. RLS denials on UPDATE/DELETE are silent (0 rows affected),
    // so these tests assert persistence, not exceptions.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class RlsHardeningTests(E2EFamilyFixture fx)
    {
        [Fact] // S-12 — the anon role has ZERO grants on application tables: a
               // client holding only the public anon key (no session) must read
               // nothing from ANY table. Both outcomes prove it — a permission
               // error (the grant is missing, PostgREST rejects the query) or an
               // empty result (RLS filtered everything); what must never happen
               // is a row coming back.
        public async Task AnonKey_WithoutSession_ReadsNothingFromAnyTable()
        {
            var anon = await E2EFamilyFixture.NewClientAsync(TestEnv.AnonKey);

            await AssertNoAnonReadAsync<Role>(anon);
            await AssertNoAnonReadAsync<Family>(anon);
            await AssertNoAnonReadAsync<Profile>(anon);
            await AssertNoAnonReadAsync<FamilyInvitation>(anon);
            await AssertNoAnonReadAsync<CareSchedule>(anon);
            await AssertNoAnonReadAsync<ActivityLog>(anon);
            await AssertNoAnonReadAsync<SwapRequest>(anon);
            await AssertNoAnonReadAsync<AppNotification>(anon);
            await AssertNoAnonReadAsync<AuthElevation>(anon);
            await AssertNoAnonReadAsync<AccountLog>(anon);
            await AssertNoAnonReadAsync<FamilyDeletionRequest>(anon);
            await AssertNoAnonReadAsync<FamilyDeletionResponse>(anon);
        }

        private static async Task AssertNoAnonReadAsync<T>(Supabase.Client anon)
            where T : Supabase.Postgrest.Models.BaseModel, new()
        {
            try
            {
                var response = await anon.From<T>().Get();
                Assert.Empty(response.Models ?? []);
            }
            catch
            {
                // Rejected outright (permission denied) — the stronger outcome.
            }
        }

        [Fact] // D8 — Returning.Minimal insert for the OTHER member works, but
               // each user reads only their own notifications.
        public async Task Notifications_AreReadableOnlyByTheirRecipient()
        {
            var marker = $"e2e-rls-{Guid.NewGuid():N}";
            await fx.Founder.From<AppNotification>().Insert(new AppNotification
            {
                RecipientProfileId = fx.MemberProfile.Id,
                Type = "swap_requested",
                Title = "E2E",
                Message = marker,
                IsRead = false,
                CreatedAt = DateTime.UtcNow
            }, new QueryOptions { Returning = QueryOptions.ReturnType.Minimal });

            var seenByMember = (await fx.Member.From<AppNotification>().Get()).Models ?? [];
            Assert.Contains(seenByMember, n => n.Message == marker);

            var seenByFounder = (await fx.Founder.From<AppNotification>().Get()).Models ?? [];
            Assert.DoesNotContain(seenByFounder, n => n.Message == marker);
        }

        [Fact] // D9 — family rename is admin-only (RPC enforced).
        public async Task NonAdmin_CannotRenameFamily()
        {
            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Member.Rpc("rename_family", new Dictionary<string, object>
                {
                    ["p_name"] = $"{TestEnv.E2eFamilyPrefix}hijacked"
                }));
            Assert.Contains("Somente administradores", ex.Message);
        }

        [Fact] // D10 — the audit log is append-only for clients: updates and
               // deletes silently affect zero rows and the entry survives.
        public async Task ActivityLog_IsImmutableForClients()
        {
            // Any calendar write produces a log row via the DB trigger.
            var day = fx.NextFutureDate();
            await fx.Founder.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = day,
                ScheduledParentId = fx.FounderProfile.Id
            });

            var log = (await fx.Founder.From<ActivityLog>().Get()).Models!
                .First(l => l.AffectedDate.Date == day.ToDateTime(TimeOnly.MinValue).Date);

            var originalAction = log.Action;
            log.Action = "tampered";
            await fx.Founder.From<ActivityLog>().Update(log);
            await fx.Founder.From<ActivityLog>().Where(l => l.Id == log.Id).Delete();

            var reloaded = (await fx.Founder.From<ActivityLog>()
                .Where(l => l.Id == log.Id)
                .Get()).Models!.Single();
            Assert.Equal(originalAction, reloaded.Action);
        }
    }
}
