using System.Text.Json;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // U-13 — the half of the notification renderer that lives in the DATABASE.
    //
    // The client-side rendering rules are pinned by NotificationRendererTests, but
    // they are worthless if the trigger does not actually WRITE the payload they
    // read. That is the seam this suite covers, and it is a seam no unit test can
    // reach: `params` is filled by auto_approve_expired() inside PostgreSQL.
    //
    // Deliberately asserts the DATA and not the sentence: the stored title/message
    // stay PT-BR by design (they are the fallback for legacy rows), so asserting
    // text here would pin the wrong thing.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class NotificationParamsTests(E2EFamilyFixture fx)
    {
        // Offsets are ~43-47 DAYS back, not hours: the shared family is seeded by
        // several suites and a few days back is crowded (108h/156h passed alone
        // and collided in the full CI pack). The rule from CLAUDE.md applies —
        // a test that never renders the day cell should go FAR past, out of every
        // in-month helper's range by construction. The +6h on the reminder case
        // keeps it inside the 24-48h window relative to its own date.
        //
        // Mirrors AutoApprovalTests: the RPC computes expiry as
        // schedule_date + handoff in America/Sao_Paulo (fixed UTC-3), so this
        // lands the expiry a controlled number of hours in the past.
        private static (DateOnly date, TimeOnly handoff) ExpiryHoursAgo(double hoursAgo)
        {
            var expirySp = DateTime.UtcNow.AddHours(-3).AddHours(-hoursAgo);
            return (DateOnly.FromDateTime(expirySp), TimeOnly.FromDateTime(expirySp));
        }

        private async Task<(long requestId, DateOnly date)> SeedExpiredSwapAsync(double expiryHoursAgo)
        {
            var (date, handoff) = ExpiryHoursAgo(expiryHoursAgo);

            var schedule = (await fx.Service.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date,
                ScheduledParentId = fx.FounderProfile.Id
            })).Models!.First();

            var request = (await fx.Service.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = date,
                ScheduleId = schedule.Id,
                RequestingProfileId = fx.MemberProfile.Id,
                TargetProfileId = fx.FounderProfile.Id,
                PreviousActualParentId = null,
                ProposedActualParentId = fx.MemberProfile.Id,
                ProposedHandoffTime = handoff,
                Status = "pending",
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow
            })).Models!.First();

            return (request.Id, date);
        }

        private async Task<List<AppNotification>> NotificationsForAsync(long requestId) =>
            (await fx.Service.From<AppNotification>().Where(n => n.SwapRequestId == requestId).Get()).Models ?? [];

        // Reads through ParamsJson on purpose — that is the exact string the
        // client renderer receives, so a serialization break shows up here.
        private static Dictionary<string, JsonElement> ParamsOf(AppNotification n)
        {
            Assert.False(string.IsNullOrWhiteSpace(n.ParamsJson),
                $"Notification '{n.Type}' was written without params — the client cannot localize it.");
            return JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(n.ParamsJson!)!;
        }

        [Fact] // The 48h auto-approval writes params on all three of its types.
        public async Task AutoApproval_WritesRenderParamsOnEveryNotification()
        {
            var (requestId, date) = await SeedExpiredSwapAsync(expiryHoursAgo: 24 * 45);

            await fx.Service.Rpc("auto_approve_expired", new Dictionary<string, object>
            {
                ["p_env_prefix"] = "[Dev] "
            });

            var notifications = await NotificationsForAsync(requestId);
            // U-24: ISO 8601, not a rendered date. `params` carries DATA so the
            // reader's device can write the day in the reader's own format —
            // storing `05/08` here is exactly what told an English reader May 8th.
            var expectedDate = date.ToString("yyyy-MM-dd");

            // Both parties are notified under the SAME type with DIFFERENT copy,
            // so `role` is what keeps the renderer from handing each the other's
            // sentence. Its absence would be invisible until a user read it.
            var approved = notifications.Where(n => n.Type == "auto_approved").ToList();
            Assert.Equal(2, approved.Count);

            var roles = approved.Select(n => ParamsOf(n)["role"].GetString()).OrderBy(r => r).ToList();
            Assert.Equal(new[] { "approver", "requester" }, roles);

            foreach (var n in approved)
                Assert.Equal(expectedDate, ParamsOf(n)["date"].GetString());

            // F-28 fan-out: carries the date, the swap/revert discriminator and
            // the caregiver's name as USER DATA (never translated downstream).
            var fanout = notifications.SingleOrDefault(n => n.Type == "swap_family_info");
            if (fanout is not null)
            {
                var p = ParamsOf(fanout);
                Assert.Equal(expectedDate, p["date"].GetString());
                Assert.Equal("auto_swap", p["kind"].GetString());
                Assert.Equal(fx.MemberProfile.FullName, p["name"].GetString());
            }
        }

        // NOTE — the 24h REMINDER payload is asserted inside
        // AutoApprovalTests.ExpiredBetween24And48h_GetsReminderButNotApproved,
        // not here, and that is deliberate.
        //
        // The reminder only fires between 24h and 48h before now, so its seed
        // CANNOT be moved far into the past like the two below. That window is
        // barely two calendar days wide and the shared family already spends
        // both on AutoApprovalTests' own cases — any value this suite picked
        // would sit within 24h of one of them and share its date, which is the
        // (family_id, schedule_date) collision the CI pack caught twice.
        //
        // Asserting on a seed that already exists is the only stable answer: a
        // suite must not add a competing date to a window that has none free.

        // The stored PT-BR sentence must SURVIVE alongside params: it is the
        // fallback for every row written before U-13, and for any client that
        // does not yet know a newer type. Writing params must never come at the
        // cost of the text that keeps history readable.
        // A SECOND writer, proven end to end through a real flow (PR 4b).
        //
        // Why this one and not request_account_deletion or the family-deletion
        // RPCs: those are destructive (they leave the family, or schedule its
        // erasure) and demand sudo, so exercising them in the shared family would
        // dismantle it. notify_member_joined is the opposite — it is an AFTER
        // INSERT trigger on profiles, so simply completing an invitation fires
        // it, and a THROWAWAY family (purged on dispose) keeps it off family A.
        // The other nine writers are covered by
        // NotificationParamsCoverageTests.EveryLiveNotificationInsert_CarriesParams,
        // which reads the migrations and cannot be fooled by a forgotten INSERT.
        [Fact]
        public async Task MemberJoining_WritesTheNameAsRenderData()
        {
            var family = await fx.CreateFamilyAsync("u13notif");

            var joined = (await fx.Service.From<AppNotification>()
                .Where(n => n.RecipientProfileId == family.AdminProfile.Id)
                .Get()).Models!
                .Where(n => n.Type == "member_joined")
                .ToList();

            var notification = Assert.Single(joined);

            // The NAME, not the sentence: the admin may read the app in another
            // language than the person who joined, and a name is user data that
            // is passed through untranslated in either one.
            Assert.Equal(family.MemberProfile.FullName, ParamsOf(notification)["name"].GetString());

            // The PT-BR fallback still stands for clients that predate the item.
            Assert.Contains(family.MemberProfile.FullName, notification.Message);
        }

        [Fact]
        public async Task StoredMessage_IsStillWritten_AlongsideParams()
        {
            var (requestId, _) = await SeedExpiredSwapAsync(expiryHoursAgo: 24 * 47);

            await fx.Service.Rpc("auto_approve_expired", new Dictionary<string, object>
            {
                ["p_env_prefix"] = "[Dev] "
            });

            foreach (var n in await NotificationsForAsync(requestId))
            {
                Assert.False(string.IsNullOrWhiteSpace(n.Title));
                Assert.False(string.IsNullOrWhiteSpace(n.Message));
            }
        }
    }
}
