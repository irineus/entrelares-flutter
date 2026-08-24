using System.Net;
using System.Text;
using System.Text.Json;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-58 — platform-operator console, DB foundation:
    //   · every admin_* RPC refuses a caller who is not in platform_operators,
    //     no matter how elevated or family-admin they are;
    //   · writes additionally require an ACTIVE S-10 elevation (ELEVATION_REQUIRED);
    //   · admin_update_setting validates against value_type and refuses policy.*;
    //   · the comp flows through is_premium() itself (never a parallel check) and
    //     survives a billing-style plan downgrade;
    //   · every operator action leaves its operator_audit_logs trail, and a comp
    //     grant/revoke also lands in the FAMILY's own account_logs (transparency);
    //   · neither operator table is readable by any authenticated client.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class PlatformOperatorTests(E2EFamilyFixture fx)
    {
        private async Task MakeOperatorAsync(Profile who)
        {
            // Idempotent (delete-first): a fixed-key seed must clean its own
            // leftover — a cancelled run never reaches the finally blocks.
            await RemoveOperatorAsync(who);
            await fx.Service.From<PlatformOperator>().Insert(new PlatformOperator
            {
                UserId = who.UserId,
                Note = "e2e throwaway operator"
            });
        }

        private async Task RemoveOperatorAsync(Profile who) =>
            await fx.Service.From<PlatformOperator>()
                .Where(o => o.UserId == who.UserId)
                .Delete();

        private async Task<bool> IsPremiumAsync(long familyId)
        {
            var response = await fx.Service.Rpc("is_premium", new Dictionary<string, object>
            {
                ["p_family_id"] = familyId
            });
            return (response.Content ?? "").Contains("true");
        }

        private async Task<List<OperatorAuditLog>> AuditRowsAsync(string operatorUserId) =>
            ((await fx.Service.From<OperatorAuditLog>()
                .Where(l => l.OperatorUserId == operatorUserId)
                .Get()).Models ?? []);

        // ── The operator gate itself ─────────────────────────────────────────

        [Fact] // A family admin, even elevated, is NOT the platform operator:
               // all four RPCs refuse before anything else is checked.
        public async Task NonOperator_AllAdminRpcs_AreRejected()
        {
            await RemoveOperatorAsync(fx.FounderProfile);
            await fx.ElevateAsync(fx.FounderProfile);
            try
            {
                var calls = new (string Rpc, Dictionary<string, object> Args)[]
                {
                    ("admin_list_settings", new Dictionary<string, object>()),
                    ("admin_list_families", new Dictionary<string, object>()),
                    ("admin_list_audit", new Dictionary<string, object>()),
                    ("admin_update_setting", new Dictionary<string, object> { ["p_key"] = "free_caregivers", ["p_value"] = "2" }),
                    ("admin_lookup_family", new Dictionary<string, object> { ["p_email"] = fx.FounderProfile.Email }),
                    ("admin_set_comp", new Dictionary<string, object> { ["p_family_id"] = fx.FamilyId, ["p_granted"] = true }),
                };
                foreach (var (rpc, args) in calls)
                {
                    var ex = await Assert.ThrowsAnyAsync<Exception>(() => fx.Founder.Rpc(rpc, args));
                    Assert.Contains("restrito", ex.Message);
                }
            }
            finally
            {
                await fx.ClearElevationAsync(fx.FounderProfile);
            }
        }

        [Fact] // Neither operator table leaks to authenticated clients — not even
               // to the operator themselves (the console goes through the RPCs).
        public async Task OperatorTables_HaveNoClientAccess()
        {
            var operators = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Founder.From<PlatformOperator>().Get());
            Assert.NotNull(operators);

            var audit = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Founder.From<OperatorAuditLog>().Get());
            Assert.NotNull(audit);
        }

        // ── Sudo on writes ───────────────────────────────────────────────────

        [Fact] // An operator WITHOUT an active elevation can read but not write —
               // the ELEVATION_REQUIRED contract the console retries on.
        public async Task Operator_WithoutElevation_WritesAreRejected()
        {
            await MakeOperatorAsync(fx.FounderProfile);
            await fx.ClearElevationAsync(fx.FounderProfile);
            try
            {
                // Reads pass without sudo.
                var settings = await fx.Founder.Rpc("admin_list_settings", new Dictionary<string, object>());
                Assert.Contains("email_cap_free", settings.Content ?? "");

                var update = await Assert.ThrowsAnyAsync<Exception>(() =>
                    fx.Founder.Rpc("admin_update_setting", new Dictionary<string, object>
                    {
                        ["p_key"] = "free_caregivers",
                        ["p_value"] = "2"
                    }));
                Assert.Contains("ELEVATION_REQUIRED", update.Message);

                var comp = await Assert.ThrowsAnyAsync<Exception>(() =>
                    fx.Founder.Rpc("admin_set_comp", new Dictionary<string, object>
                    {
                        ["p_family_id"] = fx.FamilyId,
                        ["p_granted"] = true
                    }));
                Assert.Contains("ELEVATION_REQUIRED", comp.Message);
            }
            finally
            {
                await RemoveOperatorAsync(fx.FounderProfile);
            }
        }

        // ── Settings editor rules ────────────────────────────────────────────

        [Fact] // value_type is the validation contract; policy.* is refused even
               // for a valid value; a key the table does not hold is refused
               // (the console edits, never creates).
        public async Task Operator_UpdateSetting_ValidatesTypeAndRefusesPolicy()
        {
            await MakeOperatorAsync(fx.FounderProfile);
            await fx.ElevateAsync(fx.FounderProfile);
            try
            {
                var badInt = await Assert.ThrowsAnyAsync<Exception>(() =>
                    fx.Founder.Rpc("admin_update_setting", new Dictionary<string, object>
                    {
                        ["p_key"] = "free_caregivers",
                        ["p_value"] = "abc"
                    }));
                Assert.Contains("int", badInt.Message);

                var policy = await Assert.ThrowsAnyAsync<Exception>(() =>
                    fx.Founder.Rpc("admin_update_setting", new Dictionary<string, object>
                    {
                        ["p_key"] = "policy.current_version",
                        ["p_value"] = "9.9"
                    }));
                Assert.Contains("policy", policy.Message);

                var unknown = await Assert.ThrowsAnyAsync<Exception>(() =>
                    fx.Founder.Rpc("admin_update_setting", new Dictionary<string, object>
                    {
                        ["p_key"] = "no_such_setting",
                        ["p_value"] = "1"
                    }));
                Assert.Contains("inexistente", unknown.Message);
            }
            finally
            {
                await fx.ClearElevationAsync(fx.FounderProfile);
                await RemoveOperatorAsync(fx.FounderProfile);
            }
        }

        [Fact] // A valid update persists and leaves its audit row (before/after).
               // Runs against a THROWAWAY setting row so the shared dev config is
               // never mutated by the suite (delete-first idempotent seed).
        public async Task Operator_UpdateSetting_Persists_AndAudits()
        {
            const string probeKey = "e2e.console_probe";

            await MakeOperatorAsync(fx.FounderProfile);
            await fx.ElevateAsync(fx.FounderProfile);
            await fx.Service.From<AppSettingSeed>().Where(s => s.Key == probeKey).Delete();
            await fx.Service.From<AppSettingSeed>().Insert(new AppSettingSeed
            {
                Key = probeKey,
                Value = "1",
                ValueType = "int",
                Category = "e2e"
            });
            try
            {
                await fx.Founder.Rpc("admin_update_setting", new Dictionary<string, object>
                {
                    ["p_key"] = probeKey,
                    ["p_value"] = "2"
                });

                var row = (await fx.Service.From<AppSettingSeed>()
                    .Where(s => s.Key == probeKey).Get()).Models!.Single();
                Assert.Equal("2", row.Value);

                var audit = (await AuditRowsAsync(fx.FounderProfile.UserId))
                    .Single(l => l.Action == "setting_updated" && l.SettingKey == probeKey);
                Assert.Equal("1", audit.OldValue);
                Assert.Equal("2", audit.NewValue);
            }
            finally
            {
                await fx.Service.From<AppSettingSeed>().Where(s => s.Key == probeKey).Delete();
                await fx.ClearElevationAsync(fx.FounderProfile);
                await RemoveOperatorAsync(fx.FounderProfile);
            }
        }

        // ── Comp Premium ─────────────────────────────────────────────────────

        [Fact] // The comp turns a REAL free family premium through is_premium()
               // itself, survives a billing-style downgrade (set_family_plan
               // free), is idempotent, and both audit trails record it. Revoke
               // undoes everything and is likewise recorded.
        public async Task Operator_SetComp_FlowsThroughEntitlement_AndIsAudited()
        {
            var fam = await fx.CreateFamilyAsync("f58-comp");
            await fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = fam.FamilyId,
                ["p_plan"] = "free"
            });
            Assert.False(await IsPremiumAsync(fam.FamilyId));

            await MakeOperatorAsync(fx.FounderProfile);
            await fx.ElevateAsync(fx.FounderProfile);
            try
            {
                await fx.Founder.Rpc("admin_set_comp", new Dictionary<string, object>
                {
                    ["p_family_id"] = fam.FamilyId,
                    ["p_granted"] = true,
                    ["p_note"] = "e2e comp"
                });
                Assert.True(await IsPremiumAsync(fam.FamilyId));

                // A billing-style downgrade must NOT clobber the courtesy.
                await fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
                {
                    ["p_family_id"] = fam.FamilyId,
                    ["p_plan"] = "free"
                });
                Assert.True(await IsPremiumAsync(fam.FamilyId));

                // Idempotent: a repeated grant keeps the ORIGINAL timestamp.
                var first = (await fx.Service.From<Family>()
                    .Where(f => f.Id == fam.FamilyId).Get()).Models!.Single().CompPremiumAt;
                await fx.Founder.Rpc("admin_set_comp", new Dictionary<string, object>
                {
                    ["p_family_id"] = fam.FamilyId,
                    ["p_granted"] = true
                });
                var second = (await fx.Service.From<Family>()
                    .Where(f => f.Id == fam.FamilyId).Get()).Models!.Single().CompPremiumAt;
                Assert.Equal(first, second);

                // Transparency: the FAMILY's own history shows the act — WITH
                // the reason (QA 3: the note travels in the visible entry).
                var familyLogs = (await fx.Service.From<AccountLog>()
                    .Where(l => l.FamilyId == fam.FamilyId).Get()).Models ?? [];
                Assert.Single(familyLogs, l => l.Action == "comp_premium_granted"
                    && l.NewValue == "e2e comp");

                // …and the operator trail keeps the grant.
                var audit = await AuditRowsAsync(fx.FounderProfile.UserId);
                Assert.Single(audit, l => l.Action == "comp_granted" && l.FamilyId == fam.FamilyId);

                // Revoke — with ITS OWN reason (QA 4): entitlement drops and
                // the entry reads "courtesy's note → revoke's reason".
                await fx.Founder.Rpc("admin_set_comp", new Dictionary<string, object>
                {
                    ["p_family_id"] = fam.FamilyId,
                    ["p_granted"] = false,
                    ["p_note"] = "e2e revoke"
                });
                Assert.False(await IsPremiumAsync(fam.FamilyId));

                familyLogs = (await fx.Service.From<AccountLog>()
                    .Where(l => l.FamilyId == fam.FamilyId).Get()).Models ?? [];
                Assert.Single(familyLogs, l => l.Action == "comp_premium_revoked"
                    && l.OldValue == "e2e comp" && l.NewValue == "e2e revoke");

                audit = await AuditRowsAsync(fx.FounderProfile.UserId);
                Assert.Single(audit, l => l.Action == "comp_revoked" && l.FamilyId == fam.FamilyId);
            }
            finally
            {
                await fx.ClearElevationAsync(fx.FounderProfile);
                await RemoveOperatorAsync(fx.FounderProfile);
            }
        }

        // ── Support lookup ───────────────────────────────────────────────────

        [Fact] // The lookup crosses the family RLS on purpose (that is what the
               // operator gate exists for), returns NULL on a miss, and EVERY
               // call — hit or miss — lands in the audit trail.
        public async Task Operator_LookupFamily_CrossesFamilies_AndLogsEveryCall()
        {
            await MakeOperatorAsync(fx.FounderProfile);
            try
            {
                // Founder (family A) looks up family B's founder by e-mail.
                var hit = await fx.Founder.Rpc("admin_lookup_family", new Dictionary<string, object>
                {
                    ["p_email"] = fx.FounderBProfile.Email!
                });
                using var doc = JsonDocument.Parse(hit.Content ?? "null");
                Assert.Equal(JsonValueKind.Object, doc.RootElement.ValueKind);
                Assert.Equal(fx.FamilyBId, doc.RootElement.GetProperty("family").GetProperty("id").GetInt64());
                var members = doc.RootElement.GetProperty("members").EnumerateArray()
                    .Select(m => m.GetProperty("email").GetString()).ToList();
                Assert.Contains(fx.FounderBProfile.Email, members);

                // A miss returns null — and is still an audited access attempt.
                var missEmail = fx.TestEmail("f58-nobody");
                var miss = await fx.Founder.Rpc("admin_lookup_family", new Dictionary<string, object>
                {
                    ["p_email"] = missEmail
                });
                Assert.DoesNotContain("family", miss.Content ?? "");

                var audit = await AuditRowsAsync(fx.FounderProfile.UserId);
                Assert.Contains(audit, l => l.Action == "family_lookup"
                    && l.FamilyId == fx.FamilyBId
                    && l.NewValue == fx.FounderBProfile.Email!.ToLowerInvariant());
                Assert.Contains(audit, l => l.Action == "family_lookup"
                    && l.FamilyId == null
                    && l.NewValue == missEmail.ToLowerInvariant());
            }
            finally
            {
                await RemoveOperatorAsync(fx.FounderProfile);
            }
        }

        // ── QA round: full listing + login e-mail change ─────────────────────

        [Fact] // The console lists EVERYTHING upfront and filters locally, so
               // the RPC returns every family with its members — and the bulk
               // read itself is an audited act.
        public async Task Operator_ListFamilies_ReturnsAllWithMembers_AndAudits()
        {
            await MakeOperatorAsync(fx.FounderProfile);
            try
            {
                var response = await fx.Founder.Rpc("admin_list_families", new Dictionary<string, object>());
                using var doc = JsonDocument.Parse(response.Content ?? "[]");
                Assert.Equal(JsonValueKind.Array, doc.RootElement.ValueKind);

                var ids = doc.RootElement.EnumerateArray()
                    .Select(f => f.GetProperty("id").GetInt64()).ToHashSet();
                Assert.Contains(fx.FamilyId, ids);
                Assert.Contains(fx.FamilyBId, ids);

                var familyA = doc.RootElement.EnumerateArray()
                    .Single(f => f.GetProperty("id").GetInt64() == fx.FamilyId);
                var emails = familyA.GetProperty("members").EnumerateArray()
                    .Select(m => m.GetProperty("email").GetString()).ToList();
                Assert.Contains(fx.FounderProfile.Email, emails);
                Assert.Contains(fx.MemberProfile.Email, emails);

                var audit = await AuditRowsAsync(fx.FounderProfile.UserId);
                Assert.Contains(audit, l => l.Action == "families_listed");
            }
            finally
            {
                await RemoveOperatorAsync(fx.FounderProfile);
            }
        }

        [Fact] // QA 2: the operator reads their own trail in the console — the
               // listing is newest-first and carries the family name inline.
        public async Task Operator_ListAudit_ReturnsTrail_NewestFirst()
        {
            await MakeOperatorAsync(fx.FounderProfile);
            try
            {
                // Leave a fresh, recognizable footprint to find in the trail.
                await fx.Founder.Rpc("admin_lookup_family", new Dictionary<string, object>
                {
                    ["p_email"] = fx.FounderBProfile.Email
                });

                var response = await fx.Founder.Rpc("admin_list_audit", new Dictionary<string, object>
                {
                    ["p_limit"] = 50
                });
                using var doc = JsonDocument.Parse(response.Content ?? "[]");
                Assert.Equal(JsonValueKind.Array, doc.RootElement.ValueKind);

                var entries = doc.RootElement.EnumerateArray().ToList();
                Assert.Contains(entries, e => e.GetProperty("action").GetString() == "family_lookup"
                    && e.GetProperty("family_name").GetString() is not null);

                var ids = entries.Select(e => e.GetProperty("id").GetInt64()).ToList();
                Assert.Equal(ids.OrderByDescending(i => i).ToList(), ids);
            }
            finally
            {
                await RemoveOperatorAsync(fx.FounderProfile);
            }
        }

        [Fact] // QA 2: plan flips narrate themselves in the FAMILY's history,
               // with the reason inferred from the subscription state — a paid
               // activation and a dunning downgrade, through the real writers.
        public async Task PlanChange_WritesFamilyHistory_WithInferredReason()
        {
            var fam = await fx.CreateFamilyAsync("f58-hist");
            await fx.DeleteSubscriptionSeedAsync("sub_e2e_f58-hist");
            var sub = (await fx.Service.From<Subscription>().Insert(new Subscription
            {
                FamilyId = fam.FamilyId,
                ExternalSubscriptionId = "sub_e2e_f58-hist",
                Cycle = "monthly",
                PriceCents = 549
            })).Models!.Single();

            sub.Status = "active";
            await fx.Service.From<Subscription>().Update(sub);
            await fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = fam.FamilyId,
                ["p_plan"] = "premium"
            });

            sub.Status = "overdue";
            sub.OverdueSince = DateTime.UtcNow.AddDays(-10);
            await fx.Service.From<Subscription>().Update(sub);
            // The grace cron downgrades by DIRECT UPDATE — reproduce that path.
            var famRow = (await fx.Service.From<Family>()
                .Where(f => f.Id == fam.FamilyId).Get()).Models!.Single();
            famRow.Plan = "free";
            famRow.TrialEndsAt = null;
            await fx.Service.From<Family>().Update(famRow);

            var logs = (await fx.Service.From<AccountLog>()
                .Where(l => l.FamilyId == fam.FamilyId).Get()).Models ?? [];
            Assert.Single(logs, l => l.Action == "plan_premium_payment"
                && l.OldValue == "free" && l.NewValue == "premium");
            Assert.Single(logs, l => l.Action == "plan_free_overdue"
                && l.OldValue == "premium" && l.NewValue == "free");
        }

        private static async Task<(HttpStatusCode Status, string Body)> ChangeEmailAsync(
            string bearer, long profileId, string newEmail)
        {
            using var http = new HttpClient();
            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"{TestEnv.SupabaseUrl.TrimEnd('/')}/functions/v1/admin-update-member-email");
            request.Headers.Add("apikey", TestEnv.AnonKey);
            request.Headers.Add("Authorization", $"Bearer {bearer}");
            request.Content = new StringContent(
                JsonSerializer.Serialize(new { profile_id = profileId, new_email = newEmail }),
                Encoding.UTF8, "application/json");
            using var response = await http.SendAsync(request);
            return (response.StatusCode, await response.Content.ReadAsStringAsync());
        }

        [Fact] // The deployed function: non-operator and unelevated callers are
               // refused; an elevated operator really changes the LOGIN — the
               // member signs in with the NEW address — and both trails record
               // it (the family's own account_logs via sync_profile_email).
        public async Task Operator_ChangesMemberLoginEmail_EndToEnd()
        {
            var fam = await fx.CreateFamilyAsync("f58-mail");
            var token = fx.Founder.Auth.CurrentSession!.AccessToken!;
            var newEmail = fx.TestEmail("f58-mail-new");

            // Not an operator yet → refused before anything else.
            await RemoveOperatorAsync(fx.FounderProfile);
            var refused = await ChangeEmailAsync(token, fam.MemberProfile.Id, newEmail);
            Assert.Equal(HttpStatusCode.Forbidden, refused.Status);
            Assert.Contains("restrito", refused.Body);

            await MakeOperatorAsync(fx.FounderProfile);
            try
            {
                // Operator without sudo → the ELEVATION_REQUIRED contract.
                await fx.ClearElevationAsync(fx.FounderProfile);
                var unelevated = await ChangeEmailAsync(token, fam.MemberProfile.Id, newEmail);
                Assert.Equal(HttpStatusCode.Forbidden, unelevated.Status);
                Assert.Contains("ELEVATION_REQUIRED", unelevated.Body);

                await fx.ElevateAsync(fx.FounderProfile);

                // Duplicate of another account's address → refused by GoTrue.
                var duplicate = await ChangeEmailAsync(token, fam.MemberProfile.Id, fam.AdminProfile.Email);
                Assert.Equal(HttpStatusCode.Conflict, duplicate.Status);

                var ok = await ChangeEmailAsync(token, fam.MemberProfile.Id, newEmail);
                Assert.Equal(HttpStatusCode.OK, ok.Status);

                // profiles.email followed via sync_profile_email…
                var profile = (await fx.Service.From<Profile>()
                    .Where(p => p.Id == fam.MemberProfile.Id).Get()).Models!.Single();
                Assert.Equal(newEmail.ToLowerInvariant(), profile.Email);

                // …the LOGIN really moved (password unchanged, new address)…
                var signedIn = await fx.SignInAsync(newEmail);
                Assert.NotNull(signedIn.Auth.CurrentSession);

                // …and both trails carry the act.
                var audit = await AuditRowsAsync(fx.FounderProfile.UserId);
                Assert.Contains(audit, l => l.Action == "member_email_changed"
                    && l.FamilyId == fam.FamilyId
                    && l.NewValue == newEmail.ToLowerInvariant());

                var familyLogs = (await fx.Service.From<AccountLog>()
                    .Where(l => l.FamilyId == fam.FamilyId).Get()).Models ?? [];
                Assert.Contains(familyLogs, l => l.Action == "email_changed");
            }
            finally
            {
                await fx.ClearElevationAsync(fx.FounderProfile);
                await RemoveOperatorAsync(fx.FounderProfile);
            }
        }
    }
}
