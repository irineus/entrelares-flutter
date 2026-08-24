using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // U-13 (pre-production round) — the database half of "e-mails in the language
    // the person actually reads".
    //
    // The defect: `profiles.language` was written only by the language picker, and
    // the picker was rendered only on the public auth screens (where the visitor is
    // anonymous, so nothing is written) and in the DESKTOP top bar. A signed-in
    // phone had no picker at all, so the column was NULL for everyone — and
    // `send-swap-email`, which correctly reads the RECIPIENT's language, resolved
    // NULL to pt-BR and mailed Portuguese to people whose whole app was in English.
    //
    // The fix is two columns and a generated third, and what these tests pin is the
    // part no unit test can: that the generated column really is what the Edge
    // Functions will read, and that a member can write their own detection through
    // the existing own-row policy without a new RPC.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class ProfileLanguageTests(E2EFamilyFixture fx)
    {
        private async Task<ProfileLanguageRow> ReadAsync(long profileId) =>
            (await fx.Service.From<ProfileLanguageRow>().Where(p => p.Id == profileId).Get()).Models!.Single();

        private Task SetAsync(long profileId, string? choice, string? detected) =>
            fx.Service.From<ProfileLanguageRow>().Where(p => p.Id == profileId)
                .Set(p => p.Language!, choice)
                .Set(p => p.LanguageDetected!, detected)
                .Update();

        [Fact] // The reported bug, as a rule: no choice on file, but we know what
               // their screen renders — and that is what the senders must read.
        public async Task Detection_FeedsTheEffectiveLanguage_WhenNoChoiceWasMade()
        {
            var id = fx.MemberProfile.Id;
            try
            {
                await SetAsync(id, choice: null, detected: "en");
                Assert.Equal("en", (await ReadAsync(id)).LanguageEffective);
            }
            finally { await SetAsync(id, null, null); }
        }

        [Fact] // An explicit choice outranks the detection — someone reading the
               // app in English on a borrowed device still gets their own language.
        public async Task Choice_WinsOverDetection()
        {
            var id = fx.MemberProfile.Id;
            try
            {
                await SetAsync(id, choice: "pt-BR", detected: "en");
                Assert.Equal("pt-BR", (await ReadAsync(id)).LanguageEffective);
            }
            finally { await SetAsync(id, null, null); }
        }

        [Fact] // Nothing known yet: the senders' own NULL → pt-BR fallback applies,
               // and it must be a real NULL rather than a guessed 'pt-BR' — the two
               // are different facts and the migration refuses to conflate them.
        public async Task Effective_IsNull_WhenNeitherIsKnown()
        {
            var id = fx.MemberProfile.Id;
            await SetAsync(id, null, null);
            Assert.Null((await ReadAsync(id)).LanguageEffective);
        }

        [Fact] // The client writes this itself on sign-in, through the own-row
               // policy — no RPC, and `enforce_profile_protection` must not treat a
               // display language as a system-managed field the way it does
               // color_slot or is_admin.
        public async Task Member_RecordsOwnDetection_ThroughTheOwnRowPolicy()
        {
            var id = fx.MemberProfile.Id;
            try
            {
                await fx.Member.From<Profile>().Where(p => p.Id == id)
                    .Set(p => p.LanguageDetected!, "en").Update();

                Assert.Equal("en", (await ReadAsync(id)).LanguageDetected);
            }
            finally { await SetAsync(id, null, null); }
        }

        [Fact] // ...and only their own. RLS answers with silence, not an error, so
               // the assertion has to be on the stored value.
        public async Task Member_CannotRecordSomeoneElsesLanguage()
        {
            var target = fx.FounderProfile.Id;
            try
            {
                await fx.Member.From<Profile>().Where(p => p.Id == target)
                    .Set(p => p.LanguageDetected!, "en").Update();

                Assert.Null((await ReadAsync(target)).LanguageDetected);
            }
            finally { await SetAsync(target, null, null); }
        }

        [Fact] // The CHECK is the same closed set as AppLanguages — a third language
               // means widening it in the migration that adds it, not in a caller.
        public async Task Detection_RefusesALanguageTheAppDoesNotHave()
        {
            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                SetAsync(fx.MemberProfile.Id, null, "fr"));
            Assert.Contains("language_detected", ex.Message);
        }
    }
}
