using Entrelares.Helpers;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // T-41 — central app-configuration table. Security model: the client only READS
    // public rows (UX mirror); every real limit is enforced server-side. These tests
    // prove a malicious authenticated user can neither read the private settings nor
    // change any setting for their own benefit.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class AppSettingsTests(E2EFamilyFixture fx)
    {
        [Fact] // Authenticated clients see ONLY public settings (calendar horizons),
               // never the private ones (e-mail caps).
        public async Task Authenticated_ReadsOnlyPublicSettings()
        {
            var keys = ((await fx.Member.From<AppSetting>().Get()).Models ?? [])
                .Select(s => s.Key).ToHashSet();

            Assert.Contains("calendar_months_free", keys);
            Assert.Contains("calendar_months_premium", keys);
            Assert.Contains("free_caregivers", keys);
            Assert.Contains("max_caregivers", keys);
            Assert.DoesNotContain("email_cap_free", keys);
            Assert.DoesNotContain("email_cap_premium", keys);
        }

        [Fact] // T-53 stage 4: the cutover date is a PUBLIC row — the frozen Blazor
               // client reads it to decide whether to announce the move at all, and a
               // client that cannot read it announces nothing. The VALUE is not
               // asserted: QA legitimately writes a date here to exercise the banner.
        public async Task Authenticated_ReadsTheCutoverDate()
        {
            var row = ((await fx.Member.From<AppSetting>().Get()).Models ?? [])
                .SingleOrDefault(s => s.Key == CutoverNotice.DateSettingKey);

            Assert.NotNull(row);
            // The seed's declared type, which the table's own check constraint
            // accepts — 'text' is NOT one of the five it allows, and the migration
            // that said so was refused outright.
            Assert.Equal("string", row!.ValueType);
        }

        [Fact] // The service role (management path) sees every setting.
        public async Task ServiceRole_SeesAllSettings()
        {
            var keys = ((await fx.Service.From<AppSetting>().Get()).Models ?? [])
                .Select(s => s.Key).ToHashSet();

            Assert.Contains("email_cap_free", keys);
            Assert.Contains("calendar_months_free", keys);
        }

        [Fact] // A malicious authenticated user cannot CHANGE a setting for their own
               // benefit — no write privilege is granted to `authenticated`.
        public async Task Authenticated_CannotWriteSettings()
        {
            await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Member.From<AppSetting>()
                    .Where(s => s.Key == "calendar_months_free")
                    .Set(s => s.Value, "999")
                    .Update());

            await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Member.From<AppSetting>().Insert(new AppSetting
                {
                    Key = "hacker_key", Value = "1", ValueType = "int", Category = "general"
                }));

            // The real value is untouched — the server reads the truth.
            var row = (await fx.Service.From<AppSetting>()
                .Where(s => s.Key == "calendar_months_free").Get()).Models!.Single();
            Assert.Equal("6", row.Value);
        }
    }
}
