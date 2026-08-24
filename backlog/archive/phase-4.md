# Archive — Phase 4: Quality & Testing (in progress)

Implementation records of the items delivered in Phase 4. Immutable history — new work never goes here.

---

### T-29 — Adopt Supabase CLI for migrations + apply them in CI/CD

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Description**
Database migrations were applied **manually** via the Supabase SQL Editor (the deliberate V005 interim: `database/migrations/VNNN__*` files + the `public.schema_migrations` tracking table). T-29 graduated this to the **Supabase CLI wired into CI/CD**: schema changes now deploy automatically, in the same push as the app, in the runbook's mandatory order.

**Implemented design**
- **Pipeline** (`deploy.yml`, after the test step): `supabase/setup-cli` → `supabase link` → **`supabase db push`** (applies only pending `supabase/migrations/*`, tracked per environment in `supabase_migrations.schema_migrations`, idempotent) → **deploy of both Edge Functions** → app publish. A schema failure **aborts the app publish** — an environment can never end up with new app + old schema. Branch selects the target: `dev` → dev/QA project, `master` → prod.
- **Baseline** (decision): the v1.4.0 schema snapshot became the first CLI migration (`20260713000000_baseline_v1_4_0.sql`) instead of converting V001–V010 individually. ⚠️ Hard-won addition: the **`on_auth_user_created` trigger had to be appended manually** — `db dump` does not capture auth-schema objects, and without it a fresh environment would silently break F-15 sign-up (the Realtime publication, by contrast, IS captured).
- **Cutover** (executed 2026-07-14): baseline marked as already applied on both projects via `supabase migration repair --status applied 20260713000000`; validated end to end — QA and prod runs showed `db push` recognizing the baseline (nothing to apply), both functions redeployed, app published.
- **Secrets** (six): `SUPABASE_ACCESS_TOKEN_DEV`/`_PROD`, `SUPABASE_PROJECT_REF_DEV`/`_PROD`, `SUPABASE_DB_PASSWORD_DEV`/`_PROD`. Two access tokens (named `ci-qa`/`ci-prod`) because dev and prod live in **separate Supabase accounts/orgs** — a deliberate architecture (tokens are account-scoped, so this is the only real isolation; free-plan quotas are per project, so no resource penalty; revisit only on a Pro upgrade, which is billed per org).
- **Decisions resolved during analysis:** 2 Supabase projects (dev/QA shared + prod); prod migrations fully automatic (the `--ff-only` promotion means master only ever receives a SHA whose migrations QA already validated); Edge Function deploy automated in the same item (eliminates the historical "stale `send-swap-email` sends 0 e-mails" gotcha); hosted-dev workflow kept (`supabase start`/local Docker stack documented as optional, not adopted).
- **Authoring flow** (documented in `database/README.md`): `supabase migration new` → SQL → `supabase db push` to dev while developing → commit with the feature code; CI carries it to QA/prod. The V001–V010 era and `public.schema_migrations` are **frozen as immutable history**. No down-migrations — fix forward.

**Justification**
Manual SQL-Editor application relied on human memory of what ran where — exactly the "a migration is lost on the way to production" risk, and the schema↔app coupling documented in the runbook (V010 broke the old app) had no structural guarantee. Now schema, functions and app ship atomically per environment.

**Files affected**
- `supabase/config.toml`, `supabase/.gitignore` — CLI project structure (`supabase init`)
- `supabase/migrations/20260713000000_baseline_v1_4_0.sql` — baseline (snapshot + auth-trigger appendix)
- `.github/workflows/deploy.yml` — setup-cli, `db push`, functions deploy (per-branch secrets)
- `database/README.md` — rewritten for the CLI authoring flow; `supabase/README.md` — steps 1–3 marked automated (manual fallbacks kept), CI-secrets table, account-architecture note
- `CLAUDE.md` — working agreement updated
- Validated: PR #4 → QA run 29325975970 ✔ → prod run 29326339381 ✔

---

### T-08 — Add unit test project

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `low` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Description**
There were no automated tests — the CI `dotnet test` step (T-17) built the solution and passed trivially with zero test projects. Created **`SharedParentalCustody.Tests`** (xUnit, net10.0), referenced from the root `.slnx`, so the existing CI step became a real quality gate **with zero workflow changes**. **73 tests, all pure logic, no mocks** (~2s suite).

**Coverage (5 test classes)**
- `SwapRequestServiceLogicTests` (25): the F-20/F-22 urgency formula at its exact boundaries (24h sharp → no tag; handoff instant → overdue; midnight fallback; resolved requests frozen at `resolved_at`, asserted timezone-independently by building the UTC instant from a local reference) + the `ShouldTriggerWorkflow`/`ShouldRequestRevert` workflow gates (scenarios A/B, past days blocked, today allowed).
- `RoleCatalogTests` (16): both role vocabularies (`father`/`pai`, `mother`/`mãe`/`mae`), case/trim tolerance, unknown-role passthrough — the production sign-up incident (divergent seeds) is now a regression test.
- `CalendarHelpersTests` (20): relative PT-BR day labels, handoff formatting (explicit pt-BR culture), urgency/day/swap CSS classes, parent initials.
- `ProfileServiceHelpersTests` (9): role names and the 4-slot color mapping — including a test **documenting the 5th-role fallback limitation for F-27**. Tested via an instance with a `null` Supabase client (the helpers never touch it) — zero production change.
- `RetryHelperTests` (7): transient errors retry (network drop, timeout, 5xx), business errors and 4xx pass through immediately, exhaustion after 3 attempts. Real backoff delays accepted (no test seams in production code).

**Fix shipped alongside (analysis finding)**
`CalendarHelpers.GetDaysUntil` rendered past dates as "em -3 dias"; now returns "ontem"/"há N dias" (unreachable in the current UI, fixed while writing its tests).

**Decisions**
Pure-logic scope only (bUnit component tests deferred as a future item if needed); `dotnet new xunit` defaults kept (xunit 2.9 + VS runner); no coverage gate yet.

**Files affected**
- `SharedParentalCustody.Tests/` — new project (5 test classes) + `SharedParentalCustody.slnx` reference
- `SharedParentalCustody/Helpers/CalendarHelpers.cs` — `GetDaysUntil` past-date fix
- CI: no change needed — root `dotnet test` picks the project up via the solution

---

### T-11 + T-09 — In-flight request cancellation (IAsyncDisposable + CancellationToken)

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` / `low` |
| **Complexity** | `low` / `medium` |
| **Impact** | `low` |

**Description**
Delivered together (Phase 4 item 4.3). Navigating away from a page — or rapidly navigating between calendar months — left Supabase requests running: slow queries called `StateHasChanged` on disposed components (silent console exceptions), and on Home the **last month to RETURN won**, occasionally rendering a stale month over the one the user had navigated to.

**Implemented design**
- **`RetryHelper` became token-aware** — the key correctness point: a user cancellation surfaces as `TaskCanceledException`, which the T-14 classifier treated as a retryable timeout. Retrying an abandoned navigation's query twice more would be the opposite of the goal. Rule: caller's token canceled → propagate immediately; same exception with the token intact (a real HttpClient timeout) → still transient. The backoff `Task.Delay` also honours the token.
- **Services**: optional `CancellationToken` (default keeps all call sites compiling) on every `CustodyService` method, both `AuditService` reads, and `SwapRequestService.GetFrozenDatesForMonthAsync` (scope extension: Home's month load calls it — without it the month race would stay half-fixed). Tokens flow into PostgREST `Get`/`Insert`/`Update`/`Delete`.
- **T-11 — Reports pages**: `@implements IAsyncDisposable` + a page-lifetime `CancellationTokenSource` on `ReportsSummary` and `ReportsAudit` (including "Carregar mais"); `DisposeAsync` cancels. `OperationCanceledException` is swallowed silently — a navigation-away is not an error, no banner.
- **Home**: `RenewLoadToken()` — each `LoadMonthData` creates a fresh CTS and **cancels the previous load**, eliminating the rapid-navigation race; `LoadTodayStatusAsync` shares the current token; `DisposeAsync` aborts in-flight loads.
- **Tests**: +2 on `RetryHelperTests` pinning the cancellation×timeout distinction (75 total, green).

**Files affected**
- `SharedParentalCustody/Services/RetryHelper.cs` — token parameter + cancellation-vs-timeout rule
- `SharedParentalCustody/Services/CustodyService.cs`, `AuditService.cs`, `SwapRequestService.cs` — token parameters
- `SharedParentalCustody/Pages/ReportsSummary.razor`, `ReportsAudit.razor` — IAsyncDisposable + CTS
- `SharedParentalCustody/Pages/Home.razor` — per-load CTS renewal + dispose
- `SharedParentalCustody.Tests/RetryHelperTests.cs` — cancellation behavior tests

---

### T-07 + T-13 + T-27 — Small correctness cleanups (Phase 4 item 4.4)

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` / `low` / `low` |
| **Complexity** | `low` |
| **Impact** | `low` |

**T-07 — `GetNextHandoffDateAsync` returns `DateOnly?`**
The old `DateTime?` stuffed midnight into a date-only value, inviting wrong comparisons against `DateTime.Now`. The whole chain converted: service return type, Home's `nextHandoffDate` field, `TodayCard`'s parameter, and the three `CalendarHelpers` signatures (`GetDaysUntil`/`FormatHandoffDate`/`GetHandoffUrgencyClass` now take `DateOnly` — they are date-only semantics), with their tests updated. Three orphaned `DateTime` wrappers in Home (unreferenced) were removed when the build flagged them.

**T-13 — DI lifetime: premise was stale**
The backlog claimed the Supabase Client was registered as Singleton; the current `Program.cs` already registers it **Scoped**, aligned with the services (fixed in some earlier refactor without closing the item). Delivered the entry's alternative: a comment in `Program.cs` documenting the WASM nuance (one DI container per tab → Scoped behaves as Singleton) and the mandatory-review warning before any port to Blazor Server/MAUI Hybrid.

**T-27 — Handoff time only on transition days**
Rule: a day is a **transition** when its effective responsible (`actual ?? scheduled`) differs from the previous day's; no previous schedule = custody starts = transition (mirrors the wizard, which already did `HandoffTime = isTransitionDay ? … : null`).
- **Single-day editor** (decision: warn + clear): a live amber hint appears when a time is picked on a non-transition day ("o horário não terá efeito e será removido ao salvar"), reacting to responsible changes in the form (previous day's effective parent precomputed on day open — a fetch only when the day is the 1st of the month); the save clears the time — including on the **swap-request path** (proposing a parent adjacent to their own day is not a transition either).
- **Bulk edit** (decision: same rule as the wizard): a bulk-set time lands only on transition days, evaluated against the **post-edit state** (a selected day's previous day may itself be in the selection); the result summary reports "horário aplicado em X de Y dias (somente dias com troca de responsável)".
- Untouched by design: the revert flow (restores the F-26 snapshot verbatim).

**Files affected**
- `SharedParentalCustody/Services/CustodyService.cs` — T-07 return type
- `SharedParentalCustody/Helpers/CalendarHelpers.cs` (+tests) — `DateOnly` signatures
- `SharedParentalCustody/Pages/Home.razor` (+`.css`) / `TodayCard.razor` — T-07 field/param; T-27 hint, save rule, bulk rule + summary
- `SharedParentalCustody/Program.cs` — T-13 lifetime comment

---

### S-09 — Bulk edit bypasses the scheduled-parent lock (Phase 4 item 4.5)

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**The bug (found during 4.4 manual testing)**
The single-day editor locked the scheduled parent once a day is assigned, but the lock was **UI-only** — and the bulk edit sheet had no lock at all: `SaveBulkChanges` wrote `ScheduledParentId = bulkScheduledParentId` unconditionally, letting any regular user rewrite the planned schedule in bulk (or via a direct API PATCH), a trivial evasion of the swap approval workflow. The V008 `enforce_day_protection` trigger had no rule for `scheduled_parent_id`.

**Fix — two layers**

*Database — `20260714225153_protect_scheduled_parent.sql` (first migration shipped through the T-29 CI/CD pipeline)*
`CREATE OR REPLACE` of `enforce_day_protection` (V008 body verbatim) adding one rule: changing `scheduled_parent_id` on UPDATE requires a **family admin** (explicit, audited — F-14 pattern), the **system context** (`auth.uid()` null: F-24 auto-approve, migrations), or the pending request's **target** (the F-26 revert-restore writes `scheduled_parent_id` back from the audit snapshot while the request is `revert_pending`). INSERT stays free — assigning an unassigned day is planning (F-05), not evasion.

*UI — `Home.razor`*
- **Non-admin bulk**: already-assigned days **keep** their planned parent — the sheet's choice applies only to unassigned days. A 🔒 hint under the select warns when the selection contains assigned days, and the result toast reports "responsável planejado mantido em N dias já definidos". All other bulk fields (actual→workflow, notes, handoff) keep working on every selected day.
- **Admin (admin mode ON), bulk**: overwriting the planned parent of N assigned days shows an explicit confirmation dialog first — the change rewrites the original planning; the correct path for responsibility changes is the swap workflow (actual parent). Changing the select invalidates a pending confirmation.
- **Single-day editor**: the same confirmation dialog appears when the admin saves a CHANGED planned parent on an assigned day — both entry points warn identically.
- **Consistency**: workflow routing (`ShouldTriggerWorkflow`/`ShouldRequestRevert`) and the T-27 transition rule (`EffectiveAfterBulk`) now use the per-day **effective** planned parent (kept vs overwritten), not the raw sheet value.

**Follow-ups (QA validation, July 2026)**
- **No-op days**: a bulk day whose final state equals the current one (e.g. the kept planned parent was the only "change") no longer counts as "atualizado" — the API call is skipped and the summary reports "N dias sem alterações" (fallback: "Nenhuma alteração necessária"). The old wording claimed updates that never happened.
- **Admin mode + past days in bulk**: the F-13 past-day filter in `SaveBulkChanges` gained the admin-mode exemption the single-day editor and the DB trigger already had — admins can bulk-edit past days (F-14). Frozen days stay excluded from bulk for everyone (pending requests have their own F-25 bulk sheet).
- Not a bug (understanding): a day with a realized swap keeps displaying the **actual** responsible regardless of planned-parent changes — effective = `actual ?? scheduled`.

**Files affected**
- `supabase/migrations/20260714225153_protect_scheduled_parent.sql` — trigger extension
- `SharedParentalCustody/Pages/Home.razor` — bulk keep-rule + hint + summary; admin confirmation dialogs (bulk + single-day); per-day effective planned parent; follow-ups above

---

### T-22 — Upgrade Supabase .NET SDK (Phase 4 item 4.6) — SKIPPED

| Field | Value |
|---|---|
| **Status** | `skipped` (not applicable — no newer SDK exists) |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Investigation (July 2026)**
The item's goal was to replace the Phase 1.3 session-lifecycle workarounds (`IsAuthenticated` fallback, `Program.cs` startup restore, `Task.Delay` in `UpdatePassword`, the spurious-`SignedOut` guards in `AuthService`) with native behavior from a newer SDK. Findings:

- **`Supabase` 1.1.1 (umbrella) is the newest version on NuGet** — exactly what the project uses. A v1.1.2 exists on GitHub only (July→Sep 2025) and is a dependency-bump; it never reached NuGet because the upstream release pipeline broke (the monorepo's release-please config had a csproj filename typo — fixed upstream on 2026-07-14, so new releases should resume).
- **`Supabase.Gotrue` 6.0.3 — the auth library where every workaround lives — is already the latest published version** (resolved transitively). There is nothing to upgrade to; the workarounds remain necessary by definition.
- Satellite minors exist but bring no value today: Postgrest 4.0.3→4.1.0 (undocumented), Functions 2.0.0→2.1.0 (chore-only release), Realtime 7.0.2→7.2.0 and Storage 2.0.2→2.4.1 (both unused — `AutoConnectRealtime=false`, no Storage). Pinning them would diverge from the umbrella's tested version matrix for marginal gain.

**Decision** (recorded July 2026): skip with no code change. **Revisit trigger**: when F-23 (Realtime sync, Phase 5) starts — the only concrete consumer of a satellite upgrade — or when upstream resumes publishing umbrella releases.

> **The revisit trigger FIRED — and this record was never corrected until now (31/07/2026).**
> Upstream resumed publishing: the umbrella went 1.1.1 → 1.2.0 (noted in the `1.6.1` changelog
> entry, which explicitly called it "the T-22 revisit trigger" — but the note stopped at the
> changelog and never reached this item) → 1.3.0 → 1.4.0, where the project sits today
> (Dependabot #110, merged on `dev`, CI green). "There is nothing to upgrade to", the entire
> basis for skipping, has therefore been false for over a week.
>
> **What the upgrade did NOT do is the item's actual goal.** T-22 was never about the version
> number — it was about deleting the Phase 1.3 session-lifecycle workarounds (`IsAuthenticated`
> fallback, the `Program.cs` startup restore, the `Task.Delay` in `UpdatePassword`, and the
> spurious-`SignedOut` guards in `AuthService`) once the SDK behaved natively. **Nobody has
> re-checked whether 1.4.0 makes any of them unnecessary**; they are all still in place, and the
> merge was a dependency bump, not an investigation.
>
> The item stays `skipped` rather than reopening — reopening a skipped ID would misrepresent the
> history, and the workarounds are working. But the honest status is: **the reason recorded above
> expired, and the re-evaluation is open work**. If it is picked up, it deserves a NEW technical
> item (IDs are stable and never reused), scoped as "re-test the Gotrue session workarounds
> against the current SDK and delete what is no longer needed" — with the standing warning that
> `Supabase.Realtime`'s WebSocket still throws `Arg_PlatformNotSupported` in Blazor WASM, so any
> such work must be validated with a full-pack E2E run (the Realtime E2E are `p1`).

**Files affected**
- None (documentation only)

---

### F-27 — Expanded caregiver-role catalog (Phase 4 item 4.7)

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**What shipped (decisions of July 2026)**
The fixed father/mother pair became a **21-role catalog** (Pai, Mãe, Avô, Avó, Bisavô, Bisavó, Padrasto, Madrasta, Tio, Tia, Padrinho, Madrinha, Irmão, Irmã, Primo, Prima, Amigo, Amiga, Tutor, Tutora, Babá), keeping the two-member family model (F-28 lifts it).

*Migration `20260715043019_role_catalog.sql`* (second through the T-29 pipeline)
- `roles.label_pt` + idempotent normalization of the divergent seeds (dev `Pai`/`Mãe`, prod `father`/`mother`) to canonical slug + PT-BR label; `roles_id_seq` resync (hand-seeded environments); seed of the 19 new roles; unique index on the slug.
- `handle_new_user`: the hardcoded alias `CASE` became a table lookup (canonical slug or PT-BR label, case-insensitive).
- New RPC **`set_member_role`** (mirror of `set_member_admin`): family admins change any member's role — their own included (a role is descriptive, not a privilege; no lockout invariant needed).

*Client*
- `RoleCatalog.cs` mirrors the seed (labels, emojis, aliases incl. unaccented forms); a test pins the invariants (21 roles, unique canonicals, no ambiguous alias). Kept as a client mirror — Register is pre-auth and cannot read `roles` under RLS, so a server-driven catalog was rejected.
- Register: wrapping chip grid replaces the two big buttons (holds 21 roles at 344px).
- FamilyPage: the invite now asks the inviter to **pick the invitee's role** (the auto-complementary father/mother logic is gone); **duplicate roles per family are allowed** (Avó materna + paterna). Admins get an inline role select per member card.
- **Colors are per family member** (founder = slot 1, second member = slot 2 — `GetProfileSlotIndex` replaced `GetRoleIndex` everywhere): survives any catalog size and duplicate roles, and is the F-28 groundwork. The calendar legend lists members ("Irineu (Pai)") and Reports cards show name + role. Visible effect: families founded by the mother swapped colors (founder is now color 1).
- `send-swap-email` invitation template reads `label_pt` from the join (legacy ternary kept only as pre-migration fallback).

**Validation**: QA (dev project) July 2026 — founder sign-up with new roles, invite with chosen/duplicate role, admin role change (incl. self), member-slot colors across calendar/TodayCard/legend/Reports, father/mother regression. 84 unit tests green.

**Files affected**
- `supabase/migrations/20260715043019_role_catalog.sql` — catalog, handle_new_user, set_member_role
- `SharedParentalCustody/Services/RoleCatalog.cs` / `ProfileService.cs` / `FamilyService.cs` — catalog mirror, slot colors, SetMemberRoleAsync
- `SharedParentalCustody/Pages/Register.razor(.css)` / `FamilyPage.razor(.css)` — chip grid, invite role picker, admin role select
- `SharedParentalCustody/Pages/Home.razor` / `ReportsSummary.razor` / `Helpers/CalendarHelpers.cs` — member-slot colors, member legend
- `supabase/functions/send-swap-email/index.ts` — label_pt in the invitation template
