using Entrelares.Models;
using Supabase.Postgrest;

namespace Entrelares.IntegrationTests
{
    // S-13 — LGPD accountability:
    //   · demonstrable consent: handle_new_user stamps consent_accepted_at +
    //     consent_policy_version from the sign-up metadata;
    //   · profiles created WITHOUT the policy_version metadata keep NULL consent
    //     columns (legacy semantics — recording must never be fabricated);
    //   · retention: purge_old_notifications deletes READ notifications older
    //     than 6 months and nothing else.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class ConsentAndRetentionTests(E2EFamilyFixture fx)
    {
        [Fact] // Sign-up with policy_version metadata → consent recorded.
        public async Task SignUp_WithPolicyVersion_RecordsConsent()
        {
            var fam = await fx.CreateFamilyAsync("consent");
            using var adminApi = new AdminApi();

            var email = fx.TestEmail("consent-3rd");
            var aunt = fx.Roles.First(r => r.RoleName.Equals("aunt", StringComparison.OrdinalIgnoreCase));
            var token = await E2EFamilyFixture.CreateInvitationAsync(fam.Admin, email, aunt.Id);
            await adminApi.CreateConfirmedUserAsync(email, fx.Password, new
            {
                full_name = "E2E Consent Third",
                invite_token = token,
                policy_version = "2026-07-21"
            });

            var joined = (await fx.Service.From<Profile>()
                .Where(p => p.Email == email).Get()).Models!.Single();
            Assert.NotNull(joined.ConsentAcceptedAt);
            Assert.Equal("2026-07-21", joined.ConsentPolicyVersion);
        }

        [Fact] // No policy_version metadata → consent columns stay NULL (legacy
               // semantics: consent is recorded, never fabricated).
        public async Task SignUp_WithoutPolicyVersion_LeavesConsentNull()
        {
            // The invitee is created WITHOUT policy_version on purpose. This used to
            // ride on CreateFamilyAsync, which sent no version either — but S-15's
            // re-consent gate blocks NULL-consent profiles once its notice window
            // elapses, so the fixture now signs its users up the way Register.razor
            // really does (with the version). The legacy shape therefore needs an
            // explicit sign-up here, which is also more honest: this test is about
            // the metadata-less path, not about whatever the fixture happens to do.
            var fam = await fx.CreateFamilyAsync("noconsent");
            using var adminApi = new AdminApi();

            var email = fx.TestEmail("noconsent-3rd");
            var aunt = fx.Roles.First(r => r.RoleName.Equals("aunt", StringComparison.OrdinalIgnoreCase));
            var token = await E2EFamilyFixture.CreateInvitationAsync(fam.Admin, email, aunt.Id);
            await adminApi.CreateConfirmedUserAsync(email, fx.Password, new
            {
                full_name = "E2E No Consent",
                invite_token = token
                // policy_version deliberately absent
            });

            var joined = (await fx.Service.From<Profile>()
                .Where(p => p.Email == email).Get()).Models!.Single();
            Assert.Null(joined.ConsentAcceptedAt);
            Assert.Null(joined.ConsentPolicyVersion);
        }

        [Fact] // Retention: only READ notifications older than 6 months go.
        public async Task PurgeOldNotifications_RemovesOnlyReadAndOld()
        {
            var readOld    = $"e2e-ret-read-old-{Guid.NewGuid():N}";
            var readRecent = $"e2e-ret-read-recent-{Guid.NewGuid():N}";
            var unreadOld  = $"e2e-ret-unread-old-{Guid.NewGuid():N}";

            foreach (var (marker, isRead, createdAt) in new[]
            {
                (readOld,    true,  DateTime.UtcNow.AddMonths(-7)),
                (readRecent, true,  DateTime.UtcNow.AddMonths(-1)),
                (unreadOld,  false, DateTime.UtcNow.AddMonths(-7)),
            })
            {
                await fx.Service.From<AppNotification>().Insert(new AppNotification
                {
                    RecipientProfileId = fx.MemberProfile.Id,
                    Type = "swap_requested",
                    Title = "E2E retenção",
                    Message = marker,
                    IsRead = isRead,
                    CreatedAt = createdAt
                }, new QueryOptions { Returning = QueryOptions.ReturnType.Minimal });
            }

            await fx.Service.Rpc("purge_old_notifications", new Dictionary<string, object>());

            var remaining = (await fx.Service.From<AppNotification>()
                .Where(n => n.RecipientProfileId == fx.MemberProfile.Id).Get()).Models!;
            Assert.DoesNotContain(remaining, n => n.Message == readOld);      // purged
            Assert.Contains(remaining, n => n.Message == readRecent);         // kept (recent)
            Assert.Contains(remaining, n => n.Message == unreadOld);          // kept (unread)
        }
    }
}
