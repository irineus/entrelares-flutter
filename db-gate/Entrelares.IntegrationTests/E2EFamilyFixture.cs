using System.Text.Json;
using Entrelares.Helpers;
using Entrelares.Models;
using static Supabase.Postgrest.Constants;

namespace Entrelares.IntegrationTests
{
    // T-30 fixture: one throwaway E2E family per run, created against the REAL
    // dev project through the REAL onboarding path (auth insert → handle_new_user;
    // invitation via the create_invitation RPC). RLS keeps it invisible to any
    // other family. Cleanup has two layers:
    //   1. DisposeAsync always purges this run's data (green or red).
    //   2. InitializeAsync sweeps ORPHANED E2E families (double signature +
    //      older than 2h) left behind by crashed runs — self-healing.
    // The purge itself is the purge_e2e_family RPC (service_role only), whose
    // double-signature guard lives in the DATABASE: a fixture bug cannot
    // delete a real family.
    [CollectionDefinition("e2e-family")]
    public class E2EFamilyCollection : ICollectionFixture<E2EFamilyFixture> { }

    public sealed class E2EFamilyFixture : IAsyncLifetime
    {
        public string RunId { get; private set; } = string.Empty;
        public string Password { get; private set; } = string.Empty;

        public Supabase.Client Service { get; private set; } = default!;   // bypasses RLS (seeding/inspection)
        public Supabase.Client Founder { get; private set; } = default!;   // admin, role 'father'
        public Supabase.Client Member { get; private set; } = default!;    // non-admin, role 'mother'
        public Supabase.Client FounderB { get; private set; } = default!;  // second family (RLS isolation tests)

        public Profile FounderProfile { get; private set; } = default!;
        public Profile MemberProfile { get; private set; } = default!;
        public Profile FounderBProfile { get; private set; } = default!;
        public List<Role> Roles { get; private set; } = [];
        public long FamilyId { get; private set; }
        public long FamilyBId { get; private set; }

        private AdminApi _admin = default!;
        private readonly List<Guid> _userIds = [];
        private readonly List<long> _extraFamilyIds = [];
        private int _dateCounter;

        /// <summary>Unique future date per call — tests never collide on the
        /// UNIQUE (family_id, schedule_date) constraint.</summary>
        public DateOnly NextFutureDate() => NextFutureDates(1)[0];

        /// <summary>Allocates <paramref name="count"/> CONSECUTIVE unique future
        /// dates. Needed by tests that reason about NEIGHBOURING days (T-45: a
        /// day's transition status is defined against D-1) — taking the block in
        /// one atomic step is what stops the next caller from being handed a date
        /// inside it.</summary>
        public IReadOnlyList<DateOnly> NextFutureDates(int count)
        {
            var last  = Interlocked.Add(ref _dateCounter, count);
            var first = DateOnly.FromDateTime(DateTime.Today).AddDays(10 + last - count + 1);
            return [.. Enumerable.Range(0, count).Select(first.AddDays)];
        }

        private readonly object _visibleDayLock = new();
        private DateOnly _nextVisibleDay = DateOnly.FromDateTime(DateTime.Today).AddDays(3);

        /// <summary>Unique future date for E2E tests that assert on day cells.
        /// Shorthand for <see cref="NextVisibleDays"/> with a block of 1.</summary>
        public DateOnly NextVisibleDay() => NextVisibleDays(1)[0];

        /// <summary>Allocates <paramref name="count"/> consecutive unique future
        /// dates, all guaranteed to fall in the SAME calendar month so a single
        /// month view shows the whole block. When the block would straddle a
        /// month boundary, it moves whole to day 1 of the next month — the old
        /// allocator clamped the overflow to day 1 of the CURRENT month, which
        /// is a PAST day (immutable per V008) and the same date on every
        /// overflow (UNIQUE violations); it broke every master run near the end
        /// of a month. Blocks may land beyond the initial view — pair cell
        /// interactions with UiFixture.ShowMonthOfAsync.</summary>
        public IReadOnlyList<DateOnly> NextVisibleDays(int count)
        {
            lock (_visibleDayLock)
            {
                if (_nextVisibleDay.AddDays(count - 1).Month != _nextVisibleDay.Month)
                    _nextVisibleDay = new DateOnly(_nextVisibleDay.Year, _nextVisibleDay.Month, 1).AddMonths(1);
                var block = Enumerable.Range(0, count).Select(i => _nextVisibleDay.AddDays(i)).ToList();
                _nextVisibleDay = _nextVisibleDay.AddDays(count);
                return block;
            }
        }

        public async Task InitializeAsync()
        {
            _admin = new AdminApi();   // throws with instructions if the service key is missing
            Service = await NewClientAsync(TestEnv.ServiceRoleKey);

            await SweepOrphanedFamiliesAsync();

            RunId = $"{DateTime.UtcNow:yyyyMMddHHmmss}-{Guid.NewGuid().ToString("N")[..4]}";
            Password = $"E2e!{Guid.NewGuid():N}";

            // Family A: founder through the real trigger path.
            var founderEmail = TestEmail("founder");
            _userIds.Add(await _admin.CreateConfirmedUserAsync(founderEmail, Password, new
            {
                full_name = "E2E Founder",
                role = "father",
                family_name = $"{TestEnv.E2eFamilyPrefix}{RunId}",
                policy_version = PolicyVersions.Current
            }));
            Founder = await SignInAsync(founderEmail);

            Roles = (await Founder.From<Role>().Get()).Models ?? [];
            FounderProfile = (await Founder.From<Profile>().Get()).Models!.Single();
            FamilyId = FounderProfile.FamilyId;

            // Member joins through the real invitation flow (create_invitation RPC).
            var memberEmail = TestEmail("member");
            var motherRoleId = Roles.First(r => r.RoleName.Equals("mother", StringComparison.OrdinalIgnoreCase)).Id;
            InviteToken = await CreateInvitationAsync(Founder, memberEmail, motherRoleId);
            _userIds.Add(await _admin.CreateConfirmedUserAsync(memberEmail, Password, new
            {
                full_name = "E2E Member",
                invite_token = InviteToken,
                policy_version = PolicyVersions.Current
            }));
            Member = await SignInAsync(memberEmail);
            MemberProfile = (await Founder.From<Profile>().Get()).Models!.Single(p => p.Id != FounderProfile.Id);

            // Family B: single founder, for cross-family RLS assertions.
            var founderBEmail = TestEmail("founder-b");
            _userIds.Add(await _admin.CreateConfirmedUserAsync(founderBEmail, Password, new
            {
                full_name = "E2E Founder B",
                role = "father",
                family_name = $"{TestEnv.E2eFamilyPrefix}{RunId}-B",
                policy_version = PolicyVersions.Current
            }));
            FounderB = await SignInAsync(founderBEmail);
            FounderBProfile = (await FounderB.From<Profile>().Get()).Models!.Single();
            FamilyBId = FounderBProfile.FamilyId;

            await MarkOnboardedAsync(FounderProfile.Id, MemberProfile.Id, FounderBProfile.Id);
        }

        /// <summary>
        /// Stamps profiles as "the first-run onboarding already ran".
        ///
        /// <para><b>Why every fixture profile needs this.</b> They are all born
        /// from the REAL sign-up flow, so <c>onboarding_tour_seen_at</c> is NULL —
        /// which is exactly the condition that makes the U-23 guided tour open
        /// over the calendar on first entry. For a real user that is the feature.
        /// For a test it is a spotlight overlay that swallows every click, and the
        /// symptom is a 20s timeout naming the widget the test wanted, never the
        /// tour. Three SmokeTests died that way the first time the tour reached
        /// CI, and the traces that would have shown it could not be uploaded
        /// because the artifact quota was full.</para>
        ///
        /// <para><b>The tour's OWN tests are unaffected</b> — <c>FirstRunUiTests</c>
        /// clears these three columns back to NULL before logging in, on purpose,
        /// so it still exercises a genuine first entry.</para>
        ///
        /// <para>Same class of trap as the <c>Locale = "pt-BR"</c> pin and the
        /// store-shell flag: state that changes what the app renders BEFORE a
        /// single assertion runs, so the failure never points at its cause.</para>
        /// </summary>
        private async Task MarkOnboardedAsync(params long[] profileIds)
        {
            var seenAt = DateTime.UtcNow;
            foreach (var id in profileIds)
            {
                // ALL THREE stamps, not just the tour. The first version of this
                // helper stamped only `OnboardingTourSeenAt`, which stopped the
                // overlay but left the "Primeiros passos" CARD on screen — and the
                // card renders ABOVE the calendar, pushing the day cells down. That
                // is invisible to any test that clicks (Playwright's ClickAsync
                // scrolls the target into view) and fatal to the ones that drive the
                // MOUSE by coordinates, which do not. Four `BulkUiTests` timed out
                // waiting for `.selection-action-bar` because the long press landed
                // somewhere else entirely.
                //
                // The fixture's job is to present the app in its STEADY state; only
                // `FirstRunUiTests` wants a first entry, and it clears these three
                // columns itself before logging in.
                await Service.From<Profile>().Where(p => p.Id == id)
                    .Set(p => p.OnboardingTourSeenAt!, seenAt).Update();
                await Service.From<Profile>().Where(p => p.Id == id)
                    .Set(p => p.OnboardingSwapExplainedAt!, seenAt).Update();
                await Service.From<Profile>().Where(p => p.Id == id)
                    .Set(p => p.OnboardingDismissedAt!, seenAt).Update();
            }
        }

        // S-11: a fresh, isolated 2-member family (admin + member) for the
        // DESTRUCTIVE deletion tests — leaving a member mutates the family, so
        // it must not touch the shared FamilyId used by the rest of the suite.
        // Purged (and its auth users removed) in DisposeAsync.
        public sealed record ThrowawayFamily(
            Supabase.Client Admin, Supabase.Client Member,
            Profile AdminProfile, Profile MemberProfile, long FamilyId);

        public async Task<ThrowawayFamily> CreateFamilyAsync(string tag)
        {
            var adminEmail = TestEmail($"{tag}-adm");
            _userIds.Add(await _admin.CreateConfirmedUserAsync(adminEmail, Password, new
            {
                full_name = $"E2E {tag} Adm",
                role = "father",
                family_name = $"{TestEnv.E2eFamilyPrefix}{RunId}-{tag}",
                policy_version = PolicyVersions.Current
            }));
            var adminClient  = await SignInAsync(adminEmail);
            var adminProfile = (await adminClient.From<Profile>().Get()).Models!.Single();
            _extraFamilyIds.Add(adminProfile.FamilyId);

            var memberEmail  = TestEmail($"{tag}-mbr");
            var motherRoleId = Roles.First(r => r.RoleName.Equals("mother", StringComparison.OrdinalIgnoreCase)).Id;
            var token = await CreateInvitationAsync(adminClient, memberEmail, motherRoleId);
            _userIds.Add(await _admin.CreateConfirmedUserAsync(memberEmail, Password, new
            {
                full_name = $"E2E {tag} Mbr",
                invite_token = token,
                policy_version = PolicyVersions.Current
            }));
            var memberClient  = await SignInAsync(memberEmail);
            var memberProfile = (await adminClient.From<Profile>().Get()).Models!.Single(p => p.Id != adminProfile.Id);

            await MarkOnboardedAsync(adminProfile.Id, memberProfile.Id);

            return new ThrowawayFamily(adminClient, memberClient, adminProfile, memberProfile, adminProfile.FamilyId);
        }

        public async Task DisposeAsync()
        {
            try
            {
                if (FamilyId != 0) await PurgeFamilyAsync(FamilyId);
                if (FamilyBId != 0) await PurgeFamilyAsync(FamilyBId);
                foreach (var id in _extraFamilyIds) await PurgeFamilyAsync(id);
            }
            finally
            {
                foreach (var id in _userIds)
                {
                    try { await _admin.DeleteUserAsync(id); } catch { /* best effort */ }
                }
                _admin.Dispose();
            }
        }

        public string InviteToken { get; private set; } = string.Empty;

        // F-28: lazily add a THIRD caregiver to family A through the real
        // invitation flow, shared by every test in the collection that needs a
        // multi-caregiver family (one GoTrue user for the whole run; the purge
        // removes it with the family).
        private Profile? _thirdProfile;
        public async Task<Profile> EnsureThirdMemberAsync()
        {
            if (_thirdProfile is not null) return _thirdProfile;

            var email = TestEmail("third");
            var grandmotherRoleId = Roles
                .First(r => r.RoleName.Equals("grandmother", StringComparison.OrdinalIgnoreCase)).Id;
            var token = await CreateInvitationAsync(Founder, email, grandmotherRoleId);
            _userIds.Add(await _admin.CreateConfirmedUserAsync(email, Password, new
            {
                full_name = "E2E Grandmother",
                invite_token = token,
                // S-15: without this the profile is created with
                // consent_policy_version NULL — a legacy profile — and the gate
                // BOUNCES every UI flow to the acceptance screen once
                // policy.enforce_from has passed. The other five creation sites
                // stamp it; this one was missed, and the miss was invisible
                // while enforce_from (2026-08-16) was still in the future.
                // Its cost: the p1 pack only runs on master, so the three
                // MultiCaregiverUiTests failed for the first time at a
                // PROMOTION (20/08), with nothing in the diff to explain it —
                // the trap the migration 20260730160000 already described once.
                policy_version = PolicyVersions.Current
            }));
            _thirdProfile = (await Founder.From<Profile>().Get()).Models!.Single(p => p.Email == email);
            await MarkOnboardedAsync(_thirdProfile.Id);
            return _thirdProfile;
        }

        public string TestEmail(string who) => $"delivered+e2e-{RunId}-{who}{TestEnv.E2eEmailDomain}";

        // ── S-10: sudo elevations seeded straight into auth_elevations via the
        // service client — simpler than driving the elevate Edge Function in
        // every RPC test (the function itself has its own coverage).
        public async Task ElevateAsync(Profile who, int minutes = 10) =>
            await Service.From<AuthElevation>().Upsert(new AuthElevation
            {
                UserId = who.UserId,
                ElevatedUntil = DateTime.UtcNow.AddMinutes(minutes)
            });

        public async Task ClearElevationAsync(Profile who) =>
            await Service.From<AuthElevation>()
                .Where(e => e.UserId == who.UserId)
                .Delete();

        public static async Task<Supabase.Client> NewClientAsync(string key)
        {
            var client = new Supabase.Client(TestEnv.SupabaseUrl, key,
                new Supabase.SupabaseOptions { AutoConnectRealtime = false, AutoRefreshToken = false });
            await client.InitializeAsync();
            return client;
        }

        public async Task<Supabase.Client> SignInAsync(string email)
        {
            var client = await NewClientAsync(TestEnv.AnonKey);
            // T-32: the growing suite creates many throwaway families, each with
            // several sign-ins; GoTrue's request rate limit (HTTP 429) then flakes
            // the whole run. Back off and retry on 429 so scale doesn't break CI.
            await SignInWithBackoffAsync(client, email);
            return client;
        }

        private async Task SignInWithBackoffAsync(Supabase.Client client, string email)
        {
            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    await client.Auth.SignInWithPassword(email, Password);
                    return;
                }
                catch (Supabase.Gotrue.Exceptions.GotrueException ex)
                    when (attempt < 5 && ex.Message.Contains("rate_limit"))
                {
                    await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt)));   // 1,2,4,8,16s
                }
            }
        }

        public static async Task<string> CreateInvitationAsync(Supabase.Client inviter, string email, long roleId)
        {
            var response = await inviter.Rpc("create_invitation", new Dictionary<string, object>
            {
                ["p_email"] = email,
                ["p_role_id"] = roleId
            });
            using var doc = JsonDocument.Parse(response.Content ?? "[]");
            return doc.RootElement[0].GetProperty("token").GetString()!;
        }

        /// <summary>Purge via the guarded RPC, then remove the returned auth users.</summary>
        public async Task PurgeFamilyAsync(long familyId)
        {
            var response = await Service.Rpc("purge_e2e_family", new Dictionary<string, object>
            {
                ["p_family_id"] = familyId
            });
            using var doc = JsonDocument.Parse(response.Content ?? "[]");
            foreach (var element in doc.RootElement.EnumerateArray())
            {
                if (Guid.TryParse(element.GetString(), out var userId))
                {
                    try { await _admin.DeleteUserAsync(userId); } catch { /* best effort */ }
                }
            }
        }

        /// <summary>T-39 billing seeds use FIXED external ids (sub_e2e_*). A CI run
        /// CANCELLED by the concurrency group dies before DisposeAsync purges, and the
        /// startup sweep below deliberately spares anything younger than 2h — so the
        /// next run finds the id already taken (23505). Seeds call this first.</summary>
        public async Task DeleteSubscriptionSeedAsync(string externalSubscriptionId) =>
            await Service.From<Subscription>()
                .Filter("external_subscription_id", Operator.Equals, externalSubscriptionId)
                .Delete();

        private async Task SweepOrphanedFamiliesAsync()
        {
            var families = (await Service.From<Family>()
                .Filter("name", Operator.Like, $"{TestEnv.E2eFamilyPrefix}%")
                .Get()).Models ?? [];

            var cutoff = DateTime.UtcNow.AddHours(-2);
            foreach (var family in families.Where(f => f.CreatedAt < cutoff))
            {
                // The RPC re-validates the double signature server-side.
                try { await PurgeFamilyAsync(family.Id); } catch { /* leave for manual inspection */ }
            }
        }
    }
}
