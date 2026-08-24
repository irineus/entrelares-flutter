using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // Suite D — RLS multi-tenancy (F-14/S-06): family A must never see or
    // touch family B's data, whatever the client sends.
    [Collection("e2e-family")]
    public class FamilyIsolationTests(E2EFamilyFixture fx)
    {
        [Fact]
        public async Task Profiles_AreScopedToOwnFamily()
        {
            var seenByA = (await fx.Member.From<Profile>().Get()).Models ?? [];

            Assert.All(seenByA, p => Assert.Equal(fx.FamilyId, p.FamilyId));
            Assert.DoesNotContain(seenByA, p => p.Id == fx.FounderBProfile.Id);
        }

        [Fact]
        public async Task Schedules_OfAnotherFamily_AreInvisible()
        {
            var dateB = fx.NextFutureDate();
            await fx.FounderB.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = dateB,
                ScheduledParentId = fx.FounderBProfile.Id
            });

            var seenByA = (await fx.Member.From<CareSchedule>()
                .Where(s => s.ScheduleDate == dateB)
                .Get()).Models ?? [];

            Assert.Empty(seenByA);
        }

        [Fact]
        public async Task CannotCreateSchedule_ForAnotherFamilysMember()
        {
            // The family_id is stamped server-side from the scheduled parent's
            // profile — pointing at family B's member must be rejected (RLS).
            await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Member.From<CareSchedule>().Insert(new CareSchedule
                {
                    ScheduleDate = fx.NextFutureDate(),
                    ScheduledParentId = fx.FounderBProfile.Id
                }));
        }
    }
}
