# Archive — Phase 6 (Growth, Analytics & Monetization)

Implementation records of items completed in Phase 6 (product analytics, the freemium
foundation + per-feature gates, the lawyer/court PDF wedge, and the supporting technical
work). Conventions and the summary table: [`../README.md`](../README.md).

---

### F-31 — Co-caregiver invite growth loop optimization

| Field | Value |
|---|---|
| **Status** | `completed` (v1.6.8 — QA approved July 2026) |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `high` |
| **Roadmap** | Phase 6.2 (Growth track) |
| **Depends on** | T-37 (needs the funnel metrics to prove the lift) |

**Implementation record (v1.6.6, QA-refined v1.6.7):** `Home.razor` shows a dismissible
invite-nudge to the family **admin while `ActiveProfiles.Count() == 1`** (the family isn't
useful yet); it disappears on its own once a second active member joins. **v1.6.7→1.6.8 (QA):** iterated to the final
design — the invite lives **permanently in the TodayCard's bottom half** (`ShowInviteNudge` +
`OnInvite` params on `TodayCard`). The card's top (greeting + date + return-to-today) is always
useful; only its bottom ("who has the child") is meaningless with one caregiver, so that half
becomes the invite prompt (👋 + title + "Convidar"), keeping the exact footprint the card has
once the co-caregiver joins and **inheriting the user's colour** via `CardBottomAccent` (their
real `color_slot` — not always slot 1). No dismiss/snooze anymore (it's part of the card). **Dispensar** snoozes 7 days via
`localStorage` (`gc-invite-nudge-snooze-until`); the CTA navigates to `/family`. No new
backend — reuses the F-15/F-28 invitation flow. Analytics (T-37): `invite_nudge_shown` (once
per session when visible), `invite_nudge_click`, `invite_nudge_dismiss`. Delivered with landing
**L-02**. **Fast-follow (documented):** a Playwright E2E asserting the nudge appears for a
one-member family and hides after a second member joins (needs a dedicated single-member
fixture — deferred to keep this delivery additive/low-risk). Possible refinement: also hide the
nudge when an open invitation is already pending (currently it shows until the invitee joins).

**Description**
The product's built-in viral loop is the co-caregiver invitation — a family is only
useful with ≥2 members in. Make that loop deliberate and measured (no new backend;
reuses `create_invitation` / `register-invitee` from F-15/F-28):

- An onboarding nudge right after `family_created` — "Seu calendário fica útil quando o
  outro responsável entra" with a one-tap invite (WhatsApp copyable link already exists).
- A low-value empty-state prompt on `Home.razor` when the family has a single active caregiver.
- Surface `invite_sent` / `invite_accepted` rates (feeds T-37).

**Justification**
Cheapest durable growth lever: the app already creates the invite; we only raise the rate
at which founders complete it — the moment a family becomes genuinely useful and sticky.

**Files affected**
- `Pages/Register.razor` / post-signup flow — invite nudge
- `Pages/Home.razor` — single-caregiver empty-state prompt
- `Services/AnalyticsService.cs` (T-37) — loop metrics
- E2E: invite-nudge appears for a one-member family

---

### F-32 — Freemium tiering + premium waitlist (no gateway yet)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.6.11 — QA approved July 2026) |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |
| **Roadmap** | Phase 6.3 (Growth track) |
| **Depends on** | T-37 (intent measurement) |

**Implementation record (v1.6.11):** foundation ONLY — no feature is gated here (each
gate ships separately: F-37…F-41). Migration `20260723120000_f32_family_plan_and_premium_interest.sql`
adds `families.plan` (`free`/`premium`, default `free`, CHECK) + `families.trial_ends_at`
(default `now()+30 days`), so every **new** family gets a full 30-day Premium trial while
**existing** families (created before the migration, founder included) are grandfathered to
permanent `premium` (`trial_ends_at` NULL). The DB is the single source of truth via
`is_premium(bigint)`/`is_premium()` (premium ⇔ `plan='premium'` **OR** trial still running);
`set_family_plan(family_id, plan)` is the only writer and is **granted to `service_role` only**
(REVOKE from authenticated/anon) — no client can self-upgrade. The soft waitlist is
`premium_interest` (one row per family, `UNIQUE(family_id)`, family-scoped RLS SELECT, written
via the `register_premium_interest` SECURITY DEFINER RPC, idempotent per family). Client:
`Family.Plan`/`Family.TrialEndsAt`; new `EntitlementService` mirrors the exact DB rule
(`ComputeIsPremium`/`DescribePlan`, pure + unit-tested; fail-closed `IsPremiumAsync`);
`FamilyService.RegisterPremiumInterestAsync`/`HasRegisteredPremiumInterestAsync`. UI: a
**Premium** section on `FamilyPage` shows the plan/trial status badge, previews the planned
premium features (no price, "sem data"), and offers a no-commitment CTA ("Quero recursos
premium" / "Tenho interesse em manter o Premium" during trial) that records interest + fires a
coarse `premium-interest` analytics event; grandfathered-premium families see a thank-you
instead of the CTA. Tests: `EntitlementServiceTests` (rule/boundary/trial-days) + integration
`PremiumEntitlementTests` (no self-upgrade incl. admin, default free+trial, service-role
set_family_plan + trial clearing, waitlist per-family + family-scoped). **Not yet:** billing
gateway (T-39) and the per-feature gates (F-37…F-41 below).

**Free/Premium line (LOCKED July 2026 — product owner).** Everything essential stays free
forever; the two-party collaborative core (calendar, swap approvals, notifications-in-app) and
the immutable audit log are **never** gated. Premium is additive convenience/scale:

| Capability | Free | Premium | Ships in |
|---|---|---|---|
| Calendar, swaps, approvals, history, in-app notifications | ✅ | ✅ | — (core, never gated) |
| Caregivers per family | 2 | 3+ | **F-37** |
| Transactional e-mails / month | capped (generous) | unlimited | **F-38** |
| Planning horizon (forward) | 6 months | 24 months | **F-39** |
| Admin override (correct past/frozen days) | limited window | full | **F-40** |
| Custom per-family roles | — | ✅ | **F-41** (future) |
| Lawyer/court PDF report | — | ✅ | F-33 |
| Multi-child, iCal, advanced exports | — | ✅ | F-07 / F-08 / later |

Hard technical caps (independent of tier, decided July 2026): forward planning is capped at
**24 months** for everyone (DB/cost bound); admin retroactive correction reaches back **6 months**.

**Description**
Introduce the freemium model **without building billing yet**, to validate intent before
committing to a gateway (T-39):

- A `family_plan` concept (`free` / `premium`) as a column on `families`, written only via
  SECURITY DEFINER RPC, defaulted to `free`.
- An **entitlement helper** (`is_premium(family_id)`) used to gate premium features (starts
  gating F-33). Client mirrors it; the DB is the source of truth.
- A **"Quero recursos premium"** intent capture (soft waitlist) — records interest per family
  (feeds T-37) and previews the planned premium features.
- Define and document the **free/paid line** (see the Guiding Principles in the Phase 6
  roadmap): everything essential stays free forever; premium = lawyer PDF report (F-33), then
  multi-child (F-07), extra caregivers beyond 2, iCal (F-08), advanced exports.

**Justification**
De-risks monetization: we learn whether people want premium (and which feature) before paying
the cost of a payment integration. The entitlement plumbing is also the foundation T-39 builds on.

**Files affected**
- Migration: `families.plan` + `is_premium()` + `set_family_plan` RPC
- `Services/FamilyService.cs` — read plan; new `EntitlementService.cs` — gate helper
- A "Premium" section (Profile or Família page) — waitlist CTA + feature preview
- Cross-repo: coordinates with landing `L-08` (pricing section update when premium launches)
- Privacy policy / terms note on plans (S-15 legal review); tests: RLS blocks self-upgrade + gate unit tests

---

### F-33 — Lawyer/court PDF report (paid wedge)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.6.12 — QA approved July 2026) |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |
| **Roadmap** | Phase 6.4 (Growth track) — **primary paid wedge** (product-owner decision, July 2026) |
| **Depends on** | F-32 (entitlement gate) |

**Implementation record (v1.6.12).** Decisions locked with the product owner:
**client-side print-to-PDF** for v1 (no server, no dependency, respects the CSP — a
server-signed canonical artifact + verification hash/QR is a possible future evolution);
period selector = month/year presets **plus** a custom start–end range; child identified by an
**optional free-text field at generation** (not stored — no child entity yet, that's F-07);
any active member may generate; parties shown by **name + role** (no e-mails); **honest tone**
(a factual immutability statement, no fake verification seal). New `/reports/pdf` page
(`ReportsPdf.razor`) gated by `EntitlementService.IsPremium` (F-32) — a free family sees an
upsell to the Premium section instead. `ReportPdfService.Build` (pure, unit-tested in
`ReportPdfServiceTests`) assembles a `CustodyReport` from the existing services:
`CustodyService` (planned/actual per caregiver + swaps — **identical semantics to the on-screen
Resumo** so numbers match) and `AuditService.GetAuditLogsAsync` + `ComputeDiff` (the F-02
field-level timeline). `wwwroot/js/print.js` arms a body class and calls `window.print()`; a
global `@media print` rule in `app.css` shows ONLY the `.report-print` document (scoped to the
body class so a normal Ctrl+P elsewhere is unaffected). **Nav consolidation (product-owner
request, same delivery):** Resumo + Histórico + Relatório PDF now live under one **📊
Relatórios** entry with a shared `ReportsTabs` sub-switcher (`/reports` redirects to the Resumo
tab; frees a bottom-nav slot); the nav is reordered to **Calendário · Família · Avisos ·
Relatórios · Sair** and the desktop top bar is centred with the app-name brand removed. **Not
yet:** server-signed PDF + a public verification mechanism (future); a shared period across the
three report tabs (each keeps its own for now).

**Repositioning (July 2026, v1.6.23 — product-owner request):** the feature was renamed from
*"Relatório para advogado/juiz"* to **"Relatório do histórico em PDF"** and its copy softened
across the app (page title/subtitle, Premium upsell, the printed document's subtitle → "Histórico
consolidado do período") and the landing (Preços + FAQ + JSON-LD). Rationale: framing it as a
court/lawyer document over-promised legal weight and implied a responsibility the app shouldn't
carry for what is simply a consolidated, formatted export of the history. The honest immutability
statement and the fidelity footer stay — they describe the data factually without claiming legal
authority. The "à prova de disputa" tagline for the **immutable log itself** (hero/feature/badge on
the landing) was intentionally kept. Copy-only change; no logic, data or gate touched.

**Description**
Package the already-existing **immutable audit log** (`activity_logs`) plus the
planned-vs-actual summary into a shareable, professional **PDF report** — positioned as a
*"relatório à prova de disputa"* for lawyers, mediators and family court. Contents:

- Header: family, child, period, generation timestamp, and a statement that the history is
  append-only/immutable (the legal-grade differentiator).
- Planned-vs-actual summary per caregiver (reuses `ReportsSummary` data).
- Full audit timeline for the period (reuses `AuditService`) with field-level diffs (F-02) —
  who changed what, when, old → new.
- Optional handoff-time detail; a subtle watermark + verification note.

Gated behind `is_premium()` (F-32). Generation can be **client-side** (Blazor → HTML →
print/JS PDF) for v1 or a **Supabase Edge Function** (server-rendered, signed) if a canonical
artifact is wanted — decide during analysis. Reuses the `ExportService` pattern (F-17 already
does one-tap JSON export).

**Justification**
Highest willingness-to-pay per unit of build effort in this domain: the audit log that powers
it **already exists and is trustworthy**. In a custody dispute a credible, immutable,
court-presentable history is acutely valuable — and nothing in the Brazilian market
communicates this well today.

**Files affected**
- `Services/ExportService.cs` — extend, or new `ReportPdfService.cs`
- `wwwroot/js/pdf.js` — client-side PDF (or) `supabase/functions/render-report-pdf/`
- `Pages/ReportsSummary.razor` / `ReportsAudit.razor` — "Gerar relatório (PDF)" (premium-gated)
- `EntitlementService.cs` (F-32) — gate; tests: report contains the period's audit rows; free family blocked

---

### F-37 — Gate: 3rd+ caregiver is Premium (add-only + grandfather)

| Field | Value |
|---|---|
| **Status** | `in-progress` (v1.6.15 — QA pending) |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |
| **Roadmap** | Phase 6 (Growth track) — freemium gate block (post-F-32, first gate) |
| **Depends on** | F-32 (entitlement); cross-repo landing marketing reposition |

**Implementation record (v1.6.15).** DB enforcement in the two add points
(migration `20260724120000_f37_gate_third_caregiver_premium.sql`, both functions
CREATE OR REPLACE'd from their latest bodies with only the guard inserted):
`create_invitation` (admin-facing) refuses a new invite when seats taken (active
members + open invitations) already reach **2** and `NOT is_premium(family)`;
`handle_new_user` (invitee-facing) carries the identical guard as a backstop for
the trial-expired / parallel-invite race. **Decisions (locked, product owner):**
(1) the gate is **live now** — the upsell CTA is the F-32 waitlist since billing
(T-39) doesn't exist yet; real impact today is ~zero because F-32 backfilled all
existing families to permanent premium and new families are premium during the
30-day trial, so the gate only bites a *free, post-trial* family. (2) **Uniform
rule** — any addition beyond 2 active on a free family is Premium, including
re-adding after a departure (no historical-peak tracking). **Grandfather is
automatic** (no data migration): add-only enforcement never touches existing
members, and the F-32 premium backfill + trial mean no current family is blocked.
**App:** `FamilyPage` computes `AtFreeCaregiverCap` (`!premium && seatsTaken >= 2`)
and, at the cap, replaces the invite form with a Premium hint linking to
`#premium-section` (the waitlist); the CTA fires a `premium-gate-click` event
(T-37). **Tests:** `CaregiverGateTests` (integration) — a free family blocked at
the 3rd invite + unblocked on upgrade, and a trial family allowed; the
`handle_new_user` backstop is identical logic and, per the MultiCaregiverTests
rationale, not re-proven with extra GoTrue users. The hard 4-seat cap (F-28)
still applies above this gate for premium families. **Cross-repo:** landing
marketing reposition (two free / 3+ premium) shipped in the same delivery.

**Description**
First concrete freemium gate (F-32 locked the line). Free families keep **two** caregivers;
adding a **3rd+** caregiver requires premium. Rules (locked July 2026):
- **Add-only**: the gate blocks *inviting/accepting* a 3rd member on a free family — it never
  removes or freezes members a family already has.
- **Grandfather**: families that already hold 3+ members stay fully functional on free (they
  predate the gate); the gate only prevents *new* over-cap additions.
- Enforced in the **DB** (`create_invitation` / `handle_new_user` check `is_premium()` when the
  active-member count would exceed 2), with a friendly PT-BR upsell error; the UI mirrors it
  (invite form shows a premium hint at the cap) and links to the Premium section.
- **Cross-repo:** reposition the landing's marketing — two caregivers is the free promise; 3+
  (grandparents, etc.) is a premium capability. Update `guardacompartilhada-site` benefits/pricing.

**Justification**
The extra-caregiver scenario (grandparents, nannies) is genuine added scale/value and a clean,
non-punitive wedge — nobody loses what they have, and the free product is still a complete
two-parent calendar.

**Files affected**
- Migration: `is_premium()` guard inside `create_invitation` + `handle_new_user` (over-cap only)
- `Services/FamilyService.cs` / `FamilyPage.razor` — premium hint at the seat cap
- Integration: free family blocked at 3rd invite; premium/grandfathered family allowed
- Cross-repo landing (`guardacompartilhada-site`): marketing reposition

---

### F-38 — Gate: monthly transactional-email cap (Free) vs unlimited (Premium)

| Field | Value |
|---|---|
| **Status** | `in-progress` (v1.6.17 — QA pending) |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |
| **Roadmap** | Phase 6 (Growth track) — freemium gate block (post-F-32) |
| **Depends on** | F-32 (entitlement); T-37 (usage baseline to size the cap) |

**Implementation record (v1.6.17).** All state in the DB (migration
`20260724160000_f38_email_quota_gate.sql`): an `email_usage(family_id, year_month, sent_count,
warned_80, warned_last, upsell_notified)` counter (PK `(family_id, year_month)`, RLS on, no
authenticated policy — system-owned) + `consume_email_quota(p_family_id) RETURNS text`
(SECURITY DEFINER, service_role only), returning `allowed` / `warn_80` / `warn_last` / `denied`.
The cap is per-tier (T-41: `email_cap_free`=100 / `email_cap_premium`=10000 — a high anti-abuse
cap, since nothing is truly unlimited); **both tiers are counted**. An atomic `INSERT … ON CONFLICT
DO UPDATE SET sent_count = sent_count + 1 WHERE sent_count < cap RETURNING` — NULL means it was at
the cap → `denied` (counter never climbs past it). The proactive heads-ups (80%/último) are
**free-tier only**; premium just runs against its high cap. **Three once-per-month milestones** (flag-guarded)
each fan out an in-app notification to every active member via `notify_family_email_cap`:
**80%** (`email_cap_80`, does NOT consume a slot), the **last e-mail** (`email_cap_last`, fired at
`cap-1` where the function sets `sent_count = cap` so the warning e-mail itself is the final slot),
and **over-cap** first denial (`email_cap_reached`, upsell). **Locked decisions (product owner):**
cap = **100 / family / calendar month** (America/Sao_Paulo); counting per e-mail EVENT (one
`send-swap-email` invocation); the **último** warning e-mail counts (it is the last slot), the 80%
one does not; heads-up **e-mails go to family ADMINS only** (they own the upgrade), while the in-app
goes to all active members. **Edge Function** `send-swap-email` (single choke point for swap +
invitation e-mails; auth e-mails go through `send-account-email` and are NOT capped): resolves
`family_id` (added to the invitation select), calls `consume_email_quota`, **skips the real send on
`denied`** (200 `{skipped:"email_cap"}`), and on `warn_80`/`warn_last` sends the admin heads-up
e-mail (`templateEmailCap80` / `templateEmailCapLast`) after the real send — **fail-open** on any
error so a counter fault never blocks e-mail. Client: `Notifications.razor` maps `email_cap_80` → ⚠️
and `email_cap_last` / `email_cap_reached` → ✉️ (unknown types already fall back to 🔔). **Tests:**
`EmailQuotaGateTests` (integration) — 80%/último/over-cap fire once each with their in-app rows, the
último warning consumes the final slot (counter → cap), then over-cap denies (deduped); premium
bypasses and is never counted (seeded near thresholds to avoid 100 calls). **Note:** `send-swap-email`
is redeployed by CI on every dev push (payload/logic changed here).

**Description**
Resend has a per-message cost, so free families get a **generous** monthly cap on transactional
e-mails (swap requested/approved/reverted, invitations); premium is unlimited. Design constraints
(locked July 2026):
- The cap is **generous** (sized from real usage via T-37 — a normal 2-parent family never hits
  it in ordinary use); it protects against cost abuse, not normal collaboration.
- **In-app notifications are the fallback and are NEVER capped** — when the e-mail cap is reached
  the family keeps every in-app notification (push + realtime), so the collaborative core still
  works; only the *e-mail* copy pauses until the next month or an upgrade.
- Counter lives in the DB (per family, per calendar month, `America/Sao_Paulo`); the
  `send-swap-email` path checks `is_premium()` OR under-cap before dispatching.

**Justification**
Directly caps the only real per-user variable cost while never degrading the product's core
signal (in-app stays whole). Premium's "unlimited e-mail" is a concrete, honest benefit.

**Files affected**
- Migration: monthly email-counter table/function; check in the `send-swap-email` Edge Function
- `send-swap-email` — count + gate (premium OR under-cap), else skip e-mail (in-app still sent)
- Integration/Edge tests: cap enforced for free, bypassed for premium, in-app unaffected

---

### F-39 — Gate: planning horizon (Free 6 months / Premium 24 months)

| Field | Value |
|---|---|
| **Status** | `in-progress` (v1.6.16 — QA pending) |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |
| **Roadmap** | Phase 6 (Growth track) — freemium gate block (post-F-32) |
| **Depends on** | F-32 (entitlement) |

**Implementation record (v1.6.16).** DB enforcement in `enforce_day_protection`
(migration `20260724140000_f39_planning_horizon_gate.sql` — the trigger body copied
verbatim from `20260721250000` with only the horizon guard + its `horizon_months`
declaration inserted, right after `the_date`/`fam` are resolved). The guard fires on
**new far-future writes only** — `TG_OP='INSERT'`, or an `UPDATE` that moves
`schedule_date` further out — comparing `the_date` against `today + (is_premium(fam) ?
24 : 6) months` (America/Sao_Paulo). DELETEs and edits to an existing far-future row are
untouched (**add-only + grandfather**; grandfather is automatic via F-32's premium
backfill + trial). **Locked decisions (product owner):** (1) the horizon is a
**monetization/cost gate, not admin-bypassable** — placed *before* the admin bypasses, so
the free 6-month limit applies to everyone in a free family, admins included; only the
service/system early-return (service_role) stays exempt, and 24 months is the hard ceiling
for all. (2) **Calendar UI stops paging + upsell** (not browse-locked): `Home.razor` loads
`EntitlementService.IsPremiumAsync()` once, computes `HorizonDate`, and `NextMonth`
(covering swipe) shows an upsell toast + `premium-gate-click` event instead of advancing
past the horizon month; the rotation **wizard** (`ScheduleWizard`) takes `MaxScheduleDate` +
`IsFreeTier`, validates the start date, clamps its generated range to the horizon, and
appends a truncation/upsell note. **Tests:** `PlanningHorizonGateTests` (integration) — free
blocked past 6mo, premium allowed to 24mo, everyone blocked past 24mo. Tail note: the paging
stop is month-granular, so a day in the *horizon month* beyond the exact day-count is caught
by the DB message (acceptable — friendly PT-BR).

**Description**
Scheduling far into the future is DB/cost load, so free families plan up to **6 months** ahead;
premium up to **24 months**. A **hard 24-month cap applies to everyone** (technical bound). Rules:
- Enforced in the **DB** (the day-write triggers reject a `schedule_date` beyond the tier's
  forward horizon, admin-bypass unchanged; 24 months is the absolute ceiling).
- The calendar UI stops paging / shows an upsell at the free horizon; premium reaches 24 months.
- **Grandfather**: already-scheduled days beyond a family's horizon are never deleted — the gate
  only blocks *new* far-future writes.

**Justification**
Real infrastructure cost (rows scale with horizon) mapped to a benefit families actually feel
(long-range planning). 6 months covers ordinary custody planning; 24 is the premium/technical max.

**Files affected**
- Migration: forward-horizon check in the day-protection triggers (tier-aware + hard 24-month cap)
- `Pages/Home.razor` / calendar paging — stop + upsell at the free horizon
- Integration: free blocked past 6mo, premium allowed to 24mo, everyone blocked past 24mo

---

### F-40 — Gate: Manager vs Administrator (override is Premium)

| Field | Value |
|---|---|
| **Status** | `in-progress` (v1.6.19 — QA pending) |
| **Priority** | `medium` |
| **Complexity** | `high` |
| **Impact** | `medium` |
| **Roadmap** | Phase 6 (Growth track) — freemium gate block (post-F-32) |
| **Depends on** | F-32 (entitlement); interacts with V008 day-protection triggers + admin-mode |

**Implementation record (v1.6.19).** Migration `20260724180000_f40_admin_override_tier.sql`:
seeds `override_free_days`=7 + `override_premium_months`=6 (public, T-41 app_settings) and
CREATE OR REPLACEs `enforce_day_protection` (from the 20260724150000 body) with a **tier-aware
past-day check** — the ONLY behavioural change. **Locked decisions (product owner):** (1) free
window = **7 days**; (2) only **retroactive correction** is premium — a free admin (Gestor) fixes
past days within the last 7 days, premium (Administrador) reaches back 6 months (the hard cap for
all, beyond which it's blocked even for premium); **frozen-day override, changing a FUTURE planned
parent, and clearing a future day stay free** (`cur_is_admin`, unchanged). Family-management RPCs
(rename/invite/roles/promote) were already free and untouched. The past-actual-parent correction
(`IF cur_is_admin AND the_date < today RETURN NEW`) needs no separate gate — it is reached only
after the tier-aware past-day check has already validated the reach. **Client:** `SettingsService`
gains `OverrideFreeDays`/`OverridePremiumMonths`; the `FamilyPage` admin-mode card explains Gestor
vs Administrador + the window/reach and links free admins to the Premium section. **Grandfather
automatic** (F-32 backfill + trial → the free window only bites a free, post-trial admin).
**Tests:** `AdminOverrideTierTests` — free admin fixes a 3-day-old day but is blocked at 30 days
(premium upsell); premium admin fixes 30 days but is blocked past 6 months. **Note:** S-10 sudo
elevation is unchanged; the DB day-override was never elevation-gated (only `is_admin`).

**Description**
Split today's admin capability into two levels (locked July 2026):
- **Modo Gestor (Free):** manage the family — rename, invite/revoke, set roles, promote/demote
  admins. Everything about *running* the family stays free.
- **Modo Administrador (Premium):** Manager **plus override** — correcting past/frozen days
  outside the two-party workflow (today's "admin mode").
- Free still gets a **limited correction window**: a short opportunity-to-fix (e.g. recent days)
  so honest mistakes are fixable without paying; the retroactive reach is capped at **6 months**
  for premium (the hard backward cap), and much shorter for free.
- Override remains DB-enforced (V008 triggers already gate it); the new work is making the
  bypass tier-aware (`is_premium()` + the free window) instead of a single admin flag.

**Justification**
Family administration (the collaborative essential) stays free; the *power-tool* override — a
convenience that also carries audit-integrity weight — is the premium capability. The limited
free window keeps the product fair for ordinary corrections.

**Files affected**
- Migration: tier-aware override in the day-protection triggers (premium OR within the free
  correction window; 6-month retroactive cap for premium)
- `Services/AdminModeService.cs` / `FamilyPage.razor` — Gestor vs Administrador surfaces + upsell
- Integration: free window boundary, premium full override to 6mo, beyond-cap blocked for all

---

### T-34 — Create the dedicated privacy e-mail address

| Field | Value |
|---|---|
| **Status** | `completed` (July 2026) |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Implementation record (July 2026).** Done via Cloudflare Email Routing on
`guardacompartilhada.com`. Three addresses created and routed to the operator's inbox:
**`privacidade@`** (the LGPD controller/data-subject channel printed in Privacy §1 / Terms §8
and used by the incident-response runbook §8), plus **`contato@`** (general contact) and
**`suporte@`** (support). Same routing covers the breach-communication address. No code change
(Dashboard operation).

**Description**
S-13 designated the controller contact channel as **`privacidade@guardacompartilhada.com`** — it is now printed in the Privacy Policy (§1) and Terms (§8), but the address does not exist yet. Create it before public availability (and ideally before directing any real data-subject request to it):

- Cloudflare **Email Routing** on `guardacompartilhada.com` → route `privacidade@` to the operator's inbox (irineus@gmail.com), or a dedicated mailbox if preferred.
- Send a test message end-to-end and reply from it (reply-as alias or the mailbox itself) to confirm both directions work.
- The incident-response runbook (supabase/README.md §8) also uses this address for breach communications — same routing covers it.

**Justification**
The published policies point data subjects to this channel (LGPD art. 41 §1 — the contact must be functional); a dead address would itself be a compliance failure.

**Files affected**
- None (Cloudflare Dashboard operation); optionally note the routing in README's LGPD Accountability section once live.

---

### T-37 — Product analytics & funnel instrumentation (LGPD-safe)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.6.5 — QA approved July 2026) |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |
| **Roadmap** | Phase 6.1 (Growth track) — **first item; prerequisite for the whole track** |
| **Cross-repo** | Coordinated with landing `L-01` (cookieless analytics + CTA tracking) — landing CTR and app funnel are one funnel |

**Implementation record (v1.6.2→1.6.5, decisions locked with product owner):** tool =
**Umami cookieless** (v1.6.5 — switched from Plausible to avoid its subscription while
keeping the cookieless/no-PII posture; **PostHog** reconsidered for later, when
experimentation/feature-flags land in the monetization phase); **no consent banner**
(cookieless → LGPD-exempt, one-line policy mention only); delivered **together with L-01**
(landing). `AnalyticsService` (Scoped) + `wwwroot/js/analytics.js` POST directly to the
Umami `/api/send` endpoint (`Content-Type: text/plain` to skip the CORS preflight) — no
third-party `<script>`, so `script-src` stays `'self'` (F-29 posture); only `connect-src`
gained `https://cloud.umami.is`. Config: `UmamiWebsiteId` (prod-only, from the
`UMAMI_APP_WEBSITE_ID` repo variable) + `UmamiHost`. `SanitizePath` (static, unit-tested)
strips query + fragment (invite token/recovery hash never leave) and masks GUID
segments (`/profile/:id`). Pageviews fire from `MainLayout` (`LocationChanged` +
entry render); events wired: `signup_started`/`family_created`/`invitee_joined`
(Register), `wizard_completed` (ScheduleWizard), `invite_sent` (FamilyPage),
`swap_requested` (SwapRequestService). Config-gated: empty `UmamiWebsiteId` = no-op
(dev/QA/CI off; CI enables prod only). Privacy policy §4/§9 + operator table (S-13)
updated; policy version → `2026-07-23`. **Fast-follow (small):** `swap_resolved`
across the approve/reject/cancel + revert resolvers (deferred to keep the critical
swap workflow low-risk this PR). **External prerequisite:** create the two Umami
websites and set the `UMAMI_APP_WEBSITE_ID` repo variable (app) + the landing
`data-website-id` (currently `PLACEHOLDER_LANDING_WEBSITE_ID`), else events are
accepted-and-dropped.

**Description**
Add privacy-respecting product analytics so the activation funnel is measurable end to end.
Instrument the key events (**no PII in any payload** — preserve the "PII out of logs"
invariant from T-12/S-13):

- `signup_started`, `email_confirmed`, `family_created`
- `wizard_completed` (activation), `first_schedule_saved`
- `invite_sent`, `invite_accepted` (the viral-loop moment)
- `swap_requested`, `swap_resolved`
- retention markers (D1 / D7 / D30 return)

Emit through a thin scoped `AnalyticsService` (mirrors the existing service pattern) that
no-ops when an opt-out flag is off. Tool options, in order of LGPD fit: **cookieless first**
(Cloudflare Web Analytics / Plausible for pageview-level), then **PostHog EU cloud** or
self-hosted for event funnels. Because the design is cookieless and PII-free it should not
need a new consent banner — confirm with the S-15 legal review and add a one-line privacy-policy
mention (operators/DPA table, S-13).

**Justification**
Nothing downstream (growth experiments, the free/paid line, store-listing copy) can be
evaluated without a funnel. Highest-leverage item in the track — build it first.

**Files affected**
- `SharedParentalCustody/Services/AnalyticsService.cs` — new; DI in `Program.cs`
- `wwwroot/js/analytics.js` — thin interop to the chosen SDK (CSP: self-host or allowlist the endpoint in `connect-src`)
- Call sites: `Register.razor`, `ScheduleWizard.razor`, `FamilyPage.razor`, `SwapRequestService.cs`, `NotificationService.cs`
- Privacy policy operators table (S-13); tests: events carry no PII and respect the opt-out flag

---

### T-41 — Central application-configuration table (operational parameters)

| Field | Value |
|---|---|
| **Status** | `in-progress` (v1.6.18 — QA pending) |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |
| **Roadmap** | Phase 6 (Growth track) — infra, shipped alongside F-38 |

**Implementation record (v1.6.18).** A general key/value store for app-wide operational
parameters — **not limited to freemium**. Table `app_settings(key PK, value text, value_type
CHECK int/decimal/bool/string/json, category, description, is_public, updated_at, updated_by)`
(migration `20260724150000_t41_app_settings.sql`) + typed accessors `setting_int/text/bool(key,
default)` (the default is the safety net if a key is missing). Seeded: `email_cap_free`=100,
`email_cap_premium`=10000 (a high anti-abuse cap — nothing is truly unlimited),
`calendar_months_free`=6, `calendar_months_premium`=24, `free_caregivers`=2, `max_caregivers`=4.
The DB gates now read from it: `consume_email_quota` → `email_cap_free`/`email_cap_premium` (F-38
migration edited, same delivery — premium is now counted against its high cap, free-tier heads-ups
only); `enforce_day_protection` → `calendar_months_free/premium` (CREATE OR REPLACE from the F-39
body, messages number-agnostic); `create_invitation` + `handle_new_user` → `free_caregivers`/
`max_caregivers` (CREATE OR REPLACE from the F-37 bodies). **Security model (locked with product owner):** the
client only READS `is_public` rows for UX mirroring; **enforcement is always server-side**, so a
tampered client that reads a different value gains nothing — the trigger/function reads the true
value. RLS: `SELECT` policy `USING (is_public)` for authenticated. **Gotcha (fixed in
`20260724170000`):** Supabase's *default privileges* grant `authenticated`/`anon` write access on
new public tables, so RLS blocked a client UPDATE only *silently* (0 rows, no error) — the
corrective migration `REVOKE`s all writes from `anon`/`authenticated` on `app_settings` (SELECT
re-granted) and `email_usage`, so a tampering write now fails loudly at the privilege level.
`service_role` has full access (managed via migration/dashboard —
no in-app admin UI yet). The `setting_int` accessor is SECURITY DEFINER and **not** granted to
authenticated (it would bypass RLS). **Client:** `SettingsService` loads the public settings once;
`Home.razor` mirrors the calendar horizon and `FamilyPage.razor` the caregiver cap from them
(paging + wizard + invite hints no longer hardcode 6/24/2/4). `Models/AppSetting.cs` maps the
public columns. **Tests:** `AppSettingsTests` (integration) — authenticated reads only public rows
(calendar horizons + caregiver limits, never the e-mail caps), service role sees all, an
authenticated user cannot write any setting. **Extensibility:** future entries are retention
windows, behaviour flags, and any other operational parameter — the pattern (seed + accessor +
`is_public` for UX + server-side enforcement) generalises.

**Justification**
Operational parameters were scattered as hardcoded constants across SQL functions and Razor. A
single audited, RLS-guarded config table makes them tunable without a code deploy, keeps the DB as
the enforcement authority, and gives the app one place to grow its runtime configuration.

**Files affected**
- `supabase/migrations/20260724150000_t41_app_settings.sql` — table, accessors, seed, F-39 + F-37 refactors
- `supabase/migrations/20260724160000_f38_email_quota_gate.sql` — F-38 caps (free + premium) now from settings
- `SharedParentalCustody/Services/SettingsService.cs`, `Models/AppSetting.cs`, `Program.cs`, `Pages/Home.razor`, `Pages/FamilyPage.razor`
- `SharedParentalCustody.IntegrationTests/AppSettingsTests.cs`

---

### T-42 — Vendor the Edge Functions' Deno imports (kill the esm.sh flakiness)

| Field | Value |
|---|---|
| **Status** | `in-progress` (v1.6.20 — QA pending) |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |
| **Roadmap** | Phase 6 (Growth track) — CI reliability / ops |

**Implementation record (v1.6.20).** All six Edge Functions now import `supabase-js` via the
**`npm:` specifier** (`npm:@supabase/supabase-js@2`) instead of `https://esm.sh/...`, so the
`supabase functions deploy` bundle resolves from the **npm registry** (Supabase's recommended
pattern) and never touches the flaky esm.sh CDN — the sole source of the observed HTTP 522s. The
`deno.land/std` `serve` import is kept (it never 522'd). Full `deno vendor` (a committed local
copy) was **not possible in this environment** (no Deno CLI to run/validate the vendor), and the
CI deploy step already wraps each function in a `retry` (which a *sustained* esm.sh outage still
exhausts) — so switching the source to npm is the robust, testable fix that removes the external
dependency at bundle time. No runtime behaviour change (identical `createClient` API). If a future
need arises, a true `deno vendor` + `--import-map` can still be layered on. Verified by the CI
deploy itself bundling + deploying all functions from npm.

**Description**
The Edge Functions import `@supabase/supabase-js` (and `std/http/server`) directly from
`https://esm.sh/...` / `deno.land`. On every `dev`/`master` push CI redeploys ALL functions
(`supabase functions deploy`), which re-bundles those imports — and esm.sh intermittently returns
**HTTP 522** (Cloudflare "connection timed out"), failing the *whole* deploy step **before the test
gate even runs** (observed July 2026 on the F-39 push — a green-looking item was actually a red run
for this reason). It is pure external flakiness — no code is wrong — but it blocks QA/prod deploys
at random and forces a manual re-run.

Mirror what the front-end already does for the realtime bridge (F-29 vendored
`js/vendor/supabase.js`, self-hosted per CSP): **vendor the Deno imports** so bundling never hits a
third-party CDN.
- Pin + self-host the dependency: an **`import_map.json`** (or a vendored `supabase/functions/vendor/`
  via `deno vendor`) that maps `@supabase/supabase-js` to a committed copy, referenced by all
  functions; wire `--import-map` into the CLI deploy (or `supabase/config.toml`).
- Alternatively pin to a single reliable specifier and add a **retry** around the deploy step as a
  cheap stop-gap (less robust than vendoring).
- Verify every function still bundles/deploys offline-of-esm.sh and the suites stay green.

**Justification**
CI reliability directly gates the whole Phase-6 delivery cadence: a transient esm.sh 522 currently
turns any function-touching push into a coin-flip and hides real failures behind an infra error.
Vendoring removes the external dependency at deploy time (and is the same posture already chosen for
the front-end bundle), making deploys deterministic.

**Files affected**
- `supabase/functions/import_map.json` (or `vendor/`) + `supabase/config.toml` / CI deploy flags
- `supabase/functions/*/index.ts` — imports repointed to the vendored specifier
- `.github/workflows/deploy.yml` — pass `--import-map` (if not via config)
### U-18 — Hide the "Trocado" legend badge when the month has no swapped day

| Field | Value |
|---|---|
| **Status** | `in-progress` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
The calendar legend rendered the *Trocado* (swapped) badge unconditionally. For a
brand-new user who has never swapped a day — and for any month with no swaps — the
badge explains a color that never appears on screen, cluttering the legend and
confusing newcomers. The badge now shows only when the **month being viewed** has at
least one swapped day (past, present or future): any `monthlySchedules` entry whose
`ActualParentId` is set and differs from `ScheduledParentId`.

**Design decision**
The swap predicate was extracted into `CalendarHelpers.IsSwapped(CareSchedule?)` so the
legend gate and the day-cell `swapped` color share a single source of truth and cannot
drift apart (a legend that shows the badge without any swapped cell, or vice-versa, would
be a bug). Member badges and the ≥-departed-member legend logic (S-11) are untouched;
only the standalone Trocado badge became conditional. Delivered in **v1.6.9** with unit
tests for `IsSwapped`.

**Files affected**
- `SharedParentalCustody/Helpers/CalendarHelpers.cs` — new `IsSwapped` helper; `GetDayCssClass` reuses it
- `SharedParentalCustody/Pages/Home.razor` — gate the Trocado legend badge on `monthlySchedules.Any(CalendarHelpers.IsSwapped)`
- `SharedParentalCustody.Tests/CalendarHelpersTests.cs` — `IsSwapped` coverage

---

### U-19 — Show/hide (eye) toggle on password fields

| Field | Value |
|---|---|
| **Status** | `in-progress` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
Every password input now exposes the market-standard trailing **eye** button that lets the
user reveal the typed value in clear text and hide it again at will. Fields remain **hidden
by default**. Applied to all eight password inputs in the app: Login, Register (senha +
confirmação), UpdatePassword (nova + confirmação), ProfilePage (nova + confirmação) and the
SudoPrompt (senha atual).

**Design decision**
Implemented once as a reusable component `Pages/Components/PasswordInput.razor` rather than
per-page markup, so the behaviour and styling stay identical everywhere and future password
fields inherit the toggle for free. The component supports `@bind-Value` and splats the
remaining attributes (`id`, `placeholder`, `required`, `disabled`, `autocomplete`) straight
onto the underlying `<input>`, so callers use it just like a native input and every existing
`#id` selector (and the E2E suite) keeps working. Accessibility: 44 px touch target,
`aria-label`/`aria-pressed` reflecting state, keyboard-operable, and `type="button"` so it
never submits the surrounding form. Delivered in **v1.6.10** with an E2E smoke.

**Files affected**
- `SharedParentalCustody/Pages/Components/PasswordInput.razor` (+ `.razor.css`) — new reusable field
- `Pages/Login.razor`, `Pages/Register.razor`, `Pages/UpdatePassword.razor`, `Pages/ProfilePage.razor`, `Pages/Components/SudoPrompt.razor` — use `<PasswordInput>`
- `SharedParentalCustody.E2ETests/SmokeTests.cs` — reveal→hide smoke test
### S-14 — Drop the legacy always-true RLS policy on care_schedules

| Field | Value |
|---|---|
| **Status** | `completed` (v1.6.14 — QA approved July 2026) |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `high` |

**Implementation record (v1.6.14).** The `pg_policies` sweep (asked for in the Fix
below) found the leak was **broader than the single policy the Advisor flagged**: the
baseline-era `USING (true)` pattern was live on **three** tables, each already carrying a
family-scoped policy that the always-true one nullified via OR —
`care_schedules` (`ALL` → cross-family **read + write** of the calendar),
`activity_logs` (`SELECT` → cross-family read of the immutable audit history), and
`profiles` (`SELECT` → cross-family read of names/e-mails/roles). Product-owner decision
(July 2026): close **all three** in this item rather than only `care_schedules` — leaving
`profiles`/`activity_logs` leaking would defeat S-14's purpose (close cross-family exposure
before public availability). Migration
`20260723140000_s14_drop_legacy_always_true_policies.sql` drops the three plus the redundant
duplicate always-true read on `roles` (global reference data keeps ONE intended always-true
read via `roles_authenticated_read`). Verified safe: the family-scoped policies already cover
every real access pattern (own family + own profile); profile writes go through SECURITY
DEFINER RPCs, the audit log is append-only by trigger, and the legitimate cross-family invite
migration runs as `service_role` (bypasses RLS). Adversarial Suite-E probes added to
`AdversarialTests`: a family-A account cannot read a family-B calendar/audit-log/profile row,
nor delete a family-B calendar row, while it still sees its own family. No app-behaviour
change (the UI never used the leak). **Note:** applies to prod at the next promotion — prod
carries migration-state drift (reconcile per the runbook), and the `DROP POLICY IF EXISTS`
form is idempotent.

**Post-fix verification (QA, v1.6.14 — July 2026).** A direct `pg_policies` sweep on the DEV
project (`buroanotfjcgvbfmacuh`) after the migration confirmed **only the family-scoped
policies remain** on the three tables — `care_schedules_family_{select,insert,update,delete}`,
`activity_logs_family_read`, `profiles_family_read` + `profiles_own_update` — plus the single
**intended** always-true read on `roles` (`roles_authenticated_read`, global reference data).
**No always-true policy remains on `care_schedules`/`activity_logs`/`profiles` in DEV.**
Framing correction: the earlier "present on BOTH environments" wording overstated the live
exposure on DEV — the Advisor originally flagged the always-true policy during **prod-promotion
verification (prod side)**, and DEV is verified clean post-migration; the outstanding
remediation therefore lands on **prod at the next promotion**, where the drifted policies still
exist (idempotent `DROP IF EXISTS`; reconcile the drift per the runbook).

**Description**
Found by the Supabase Security Advisor (`rls_policy_always_true`) during the
v1.6.0 prod-promotion verification (July 2026). `care_schedules` carries **two
generations of policies at once**: the four family-scoped ones
(`care_schedules_family_select/insert/update/delete`, all
`family_id = get_my_family_id()`) **and** the baseline-era
`"Allow full access to care schedules for authenticated users"` (`ALL`,
`USING (true)`). Permissive policies combine with **OR**, so the legacy policy
**nullifies the family scoping**: any authenticated account can SELECT (and
target with UPDATE/DELETE) another family's calendar rows via direct PostgREST.
The day-protection/revision triggers still guard *semantics* (past days, frozen
days, planned-parent lock) but none of them checks family membership. Verified
present on BOTH environments (same migrations); the app UI never exposes it —
the exposure requires a hand-crafted API call by an authenticated user.

**Fix**
One-line migration: `DROP POLICY "Allow full access to care schedules for
authenticated users" ON public.care_schedules;` — the scoped policies already
cover every verb for the app's real access patterns. Ship with an adversarial
integration test (Suite E): authenticated user from family A reading/updating a
family-B schedule row must get zero rows / an RLS error. While there, sweep
`pg_policies` for any other lingering always-true policy (the Advisor flags
only this one today).

**Justification**
Cross-family exposure of child-related schedule data is the worst-case scenario
in the incident-response runbook (§8). Exploitation requires a valid account +
direct API use, and today's user base is a single family — but this must close
before wider availability. Two other Advisor warnings were triaged at the same
review and stay ACCEPTED: `auth_leaked_password_protection` (the HaveIBeenPwned
check is a **Pro-plan feature** — on Free the mitigation stays the server-side
8-char minimum; revisit at the "upgrade to Pro before public availability"
checkpoint, alongside PITR) and the SECURITY DEFINER / search_path warnings
(the documented S-12 posture).

**Files affected**
- `supabase/migrations/<ts>_s14_drop_legacy_care_schedules_policy.sql`
- `SharedParentalCustody.IntegrationTests/AdversarialTests.cs` — cross-family care_schedules probe

---

### T-39 — Subscription billing infrastructure (Pix, web-first)

| Field | Value |
|---|---|
| **Status** | `completed` (July 2026 — v1.6.29–1.6.31, PRs #113/#115/PR3) |
| **Priority** | `high` |
| **Complexity** | `high` |
| **Impact** | `high` |
| **Roadmap** | Phase 6.11 (Growth track) — **last in the track; build once demand is measured** |
| **Prerequisites** | F-32 + F-33 (validated demand + a proven wedge); **T-36** (item 6.8 — Supabase Pro, PITR/backups, rate limits) for paid-plan scale; the 6.5–6.9 public-availability gate |
| **Cross-repo** | Landing `L-08` (pricing section) updates in lockstep with the plan/price decided here |


**Decisions locked (July 2026, with the product owner)**
- **Gateway: Asaas** (native recurring Pix/Pix Automático at BR-friendly fees; card too; hosted checkout; webhooks + sandbox). Stripe rejected on Pix-recurrence + fees; Mercado Pago on API flexibility.
- **Price: R$ 14,90/month · R$ 149/year** (≈2 months free), per family. Values live in `app_settings` (`billing.price_*_cents`, public) — changeable without deploy; checkout reads the same rows server-side.
- **Checkout: hosted/redirect** (v1) — no card data ever touches our domain.
- **Activation: immediately for the current base** (owner's call, ahead of the S-15/S-16/T-36 gate) — but behind `billing.enabled` (default `false`) so go-live is a settings flip after the 3 PRs land and the gateway account is verified. Charging real users REQUIRES the Terms' subscription/refund section (CDC art. 49 — 7-day arrependimento) shipped in PR3 (fronts a slice of S-15).
- **Defaults**: 7-day grace on failed renewal (`billing.grace_days`, server-only) then downgrade to `free` — data never deleted; no boleto in v1 (Pix covers it cheaper).
- **Delivery: 3 PRs** — PR1 DB + `billing-webhook` (this one); PR2 `billing-checkout` + Premium page CTA/manage/return; PR3 grace cron + Terms (both repos, PolicyVersions bump) + landing L-08.

**PR2 design note (July 2026)**: checkout uses an Asaas **Payment Link** (`chargeType RECURRENT`), NOT an API-created customer+subscription — the payer fills name/CPF/e-mail on Asaas's PCI-scoped page, so the app never collects payment/identity data. The webhook ADOPTS the gateway-created subscription on its first event (match by `externalReference family:<id>`, fallback by stored payment link id). Validate in sandbox that externalReference propagates from link to payments; both fallbacks shipped. Cancel = DELETE the Asaas subscription (or the unpaid link); paid time honored, plan flip on lapse only (PR3 cron).

**Operational setup (out-of-band, needed before go-live)**
1. Create the Asaas account (sandbox first), get the API key.
2. `supabase secrets set ASAAS_WEBHOOK_TOKEN=<random>` (DEV and later PROD) + register the webhook URL `https://<project>.supabase.co/functions/v1/billing-webhook` with that token in the Asaas dashboard (payment + subscription events).
3. GitHub secret `ASAAS_WEBHOOK_TOKEN_DEV` (same value as the DEV function secret) arms the positive-path integration tests; absent, they self-disarm.
4. PR2 adds `ASAAS_API_KEY` (function secret) for checkout.

**Description**
Turn the F-32 entitlement into a real paid subscription — **only after F-32/F-33 validate
demand.** Brazil-first payment stack:

- **Pix is mandatory**; card and (optionally) boleto. Gateway options: a local provider with
  native recurring Pix/card (Asaas, Iugu, Mercado Pago) or Stripe + Pix — decide during
  analysis (recurring-Pix support and fees are the deciding factors; verify current terms).
- **Web-first checkout** on `app.guardacompartilhada.com` (avoids the 15–30% store cut); the
  TWA/iOS wrappers honour the web subscription ("gerencie sua assinatura no site").
- A **webhook Edge Function** receives payment events and flips `families.plan` via the F-32
  RPC (server-authoritative entitlement).
- Per-family subscription (one payer), monthly + discounted annual; entry price for BR should
  be low (validate — the market is price-sensitive vs. US-priced incumbents like OurFamilyWizard).
- Dunning / grace on failed renewal; downgrade to `free` on lapse (**never delete data** —
  premium features go read-only, essentials stay free).

**Justification**
The revenue mechanism. Deliberately last: build it once there is measured intent (F-32) and a
proven wedge (F-33), so the gateway/pricing choice is data-informed, not guessed.

**Files affected**
- `supabase/functions/billing-webhook/` — new (verify signature, flip plan)
- Migration: subscription/invoice bookkeeping table (write via service_role only)
- `Services/EntitlementService.cs` — checkout entry, manage-subscription link
- Web checkout flow + "gerencie no site" note in the wrappers
- Tests: webhook flips plan; lapse downgrades; data never deleted on downgrade

---

**Implementation record (July 2026, v1.6.29–1.6.31)**
- **PR1 (#113)**: `subscriptions` (one per family, family-scoped SELECT, service_role writes) + `billing_events` (idempotency ledger + raw audit, service_role only); `billing.*` settings (prices public; `billing.enabled=false` master switch; `billing.grace_days=7` server-only); `billing-webhook` (shared `asaas-access-token`, `--no-verify-jwt`, idempotent by `event_id`, effects via `set_family_plan`).
- **PR2 (#115)**: `billing-checkout` (user JWT, admin-only, guard chain 401→403→409→503; **Asaas Payment Link RECURRENT** — payer data only on Asaas's PCI page; cancel honors paid time); webhook ADOPTS the link-created subscription (`externalReference family:<id>` + link-id fallback); Premium section with the real offer/manage/cancel; `/premium/retorno` polling page.
- **PR3**: `billing_grace_downgrade()` on pg_cron (hourly :23) — canceled+lapsed or overdue beyond grace → `free`, data intact, `GRACE_DOWNGRADE` audited; **additive renewal** (period counts from the later of payment due date / previous period end — re-subscribing never wastes paid time); "Premium ativo até X" notice + dated cancel warning; `CHECKOUT_ERROR` gateway-failure audit; `dueDateLimitDays: 5` (payment-link API requires it); E2E purge sweeps the billing ledger; **Terms §10 rewritten + Asaas as operator in Privacy (both repos), PolicyVersions → 2026-07-28**; landing L-08 pricing in lockstep.
- **Sandbox E2E validated by the owner (28/07)**: checkout → Pix → webhook → premium; idempotent redelivery; refund → free; cancel honors period; re-subscribe adds time. Asaas ACCOUNT prerequisites discovered: registered site (callback domain), Pix key (else no Pix option at checkout).
- **Go-live checklist (production — still pending, do at activation)**: real Asaas account (site `app.guardacompartilhada.com` + Pix key + API key); prod secrets `ASAAS_API_KEY`, `ASAAS_WEBHOOK_TOKEN` (new value), **`ASAAS_API_URL=https://api.asaas.com/v3`** (sandbox is the code default — prod must OPT IN) and webhook registered in the real dashboard; flip `billing.enabled` in prod `app_settings`. Gate S-15/S-16/T-36 remains the owner's call (activation decision: immediate for current base). **The step-by-step version (dashboard paths, webhook auth smoke test, the SQL flip and the real-payment verification incl. the refund path) is the runbook's [section 9](../../supabase/README.md#9-billing-go-live-t-39--activating-real-charges-in-production)** — go-live is pure configuration, no deploy/promotion involved.
- **Follow-up spawned**: F-42 (scheduled reactivation without immediate charge — Pix/boleto feasible via stored customer).

---

### F-43 — Payment history for family admins (sanitized ledger timeline)

| Field | Value |
|---|---|
| **Status** | `completed` (July 2026 — v1.6.33) |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |
| **Depends on** | T-39 (billing_events ledger) |

**Description / decisions (locked with the owner, July 2026)**
Owner request after the T-39 sandbox QA: a user-visible payment history. Decisions: lives on
the **Família page under the subscription panel** (no new nav item — the bottom nav is at its
6-tab cap); **admins only** (the DB refuses non-admins, the UI never offers it); **full
timeline** (payments, refunds, overdue, cancellations, grace downgrades); **receipt links**
(the Asaas `invoiceUrl` already sat in the raw webhook payloads — no webhook change needed).

**Implementation record**
- RPC `get_billing_history()` (SECURITY DEFINER, STABLE): admin check via `auth.uid()`,
  family-scoped, SANITIZED projection of `billing_events` (the raw ledger stays
  service_role-only — gateway payloads may carry payer metadata). Categories mapped in SQL;
  `CHECKOUT_ERROR`/`PAYMENT_CREATED` never surface. **Dedupe**: `DISTINCT ON (category,
  payment id)` keeps one row per real payment (card emits CONFIRMED then RECEIVED). Newest
  first, LIMIT 100.
- Client: `BillingHistoryEntry` DTO + `GetHistoryAsync` (RetryHelper; RPC read) + pure label
  helpers (`DescribeHistoryCategory`/`DescribeBillingType`, unit-tested). Família page:
  lazy-loaded collapsible under the premium card, rows = date · label · method · amount ·
  "recibo" link.
- Tests: integration (admin timeline with dedupe + receipt URL; non-admin refused by the DB;
  cross-family isolation — events seeded via raw PostgREST exactly as the webhook writes
  them) + unit label maps.

---

### T-43 — Investigate & fix the master-only E2E seed collision (23505)

| Field | Value |
|---|---|
| **Status** | `completed` (July 2026 — PR #122, test-only fix, no version bump) |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Description**
The **full E2E pack** (which runs only on `master` / `workflow_dispatch`, not on the `dev`
`pack=p0` smoke) intermittently failed with a PostgREST **23505** — `duplicate key value violates
unique constraint "care_schedules_family_schedule_date_key"` — in
`MultiCaregiverUiTests.FrozenDay_VisibleToUninvolvedCaregiver` (the founder-day seed). It bit
**three `master` promotions** in July 2026; prod was never at risk (the deploy is gated), but every
promotion flaked until fixed.

**Investigation (rule-outs, kept for the record)**
- The "two overlapping date allocators" theory was **DISPROVEN** and turned out to be a red
  herring: `NextFutureDate` (base today+10) is used **only by integration tests**,
  `NextVisibleDays` (base today+3) **only by E2E**; each suite is its own process with its own
  family, so the ranges never coexist on one family.
- `NextVisibleDays` is monotonic + lock-guarded → unique within a family; `EnsureThirdMemberAsync`
  is cached and seeds no schedule; no write-retry on the fixture client.

**Root cause (found)**
The collision was with rows **generated by another test in the same collection**, not with another
allocator. The **rotation-wizard** test drove the UI to generate a 7/7 plan starting on **day 1 of
the NEXT month**, so the plan owned *every* date in that month. Near a month boundary
`NextVisibleDays` (today+3, growing) overflows into that same month — and when xUnit happened to
run the wizard test **before** `FrozenDay_VisibleToUninvolvedCaregiver`, the date the allocator
handed out already existed → 23505. Both conditions were required (month-end **and** that ordering),
which is exactly why it only ever showed up intermittently, at promotions.

**Implementation record**
- `MultiCaregiverUiTests.cs`: the wizard plan now starts **+2 months** (`AddMonths(2)` instead of
  `AddMonths(1)`) — beyond the allocator's reach *by construction*, not by luck. Test-only change;
  no app behaviour touched, so no version bump (per the versioning rule).
- `CLAUDE.md`: the open-mystery gotcha was replaced by the solved one, with the generalized lesson —
  **any E2E that BULK-GENERATES schedules must aim ≥2 months out**.
- The `E2EFamilyFixture` allocator was left unchanged: it was never the defect, and a delete-first /
  globally-unique-date helper (the fallback plan sketched while the cause was open) is unnecessary
  now that the two ranges cannot overlap.

**Files affected**
- `SharedParentalCustody.E2ETests/MultiCaregiverUiTests.cs`
- `CLAUDE.md` (gotcha rewritten: open flake → solved, with the lesson)

---

### T-44 — Keep the DEV Free-tier project awake (prevent the 7-day auto-pause)

| Field | Value |
|---|---|
| **Status** | `completed` (July 2026 — PRs #124 + #125; promoted to prod 30/07/2026; infra/ops, no version bump) |
| **Priority** | `low` |
| **Complexity** | `low` |
| **Impact** | `medium` |
| **Roadmap** | Phase 6 (Growth track) — CI reliability / ops |

**Description**
The July-2026 account consolidation put the **dev/QA** project (`buroanotfjcgvbfmacuh`) in a
**Free** Supabase org (prod runs in a separate Pro org — see the Environments note in `CLAUDE.md`
and the runbook). Free projects **auto-pause after 7 days of inactivity**, and that project is not
just for local dev — it also serves the **QA app deployed from `dev`** and every **CI test gate**
(integration + E2E run against it). A quiet week (holiday, no pushes) would pause it and take QA
down until someone resumed it by hand in the Dashboard.

**Implementation record (PRs #124 → #125).**
`.github/workflows/keepalive-dev.yml` pings the dev project **twice a week (Mon/Thu 08:37 UTC)** with
a trivial PostgREST read (`GET /rest/v1/roles?select=id&limit=1`); the request reaching the DB is
what resets the pause timer. The final working form took two corrective iterations, and the lesson
is the value of this record:
- **It must use the `service_role` key in BOTH the `apikey` AND `Authorization: Bearer` headers.**
  Two layered reasons, each found by a red run:
  1. The app is **100% RLS-locked**: `anon` has no SELECT on reference tables
     (`has_table_privilege('anon','public.roles','SELECT')` is **false**), so any anonymous ping
     returns **401** (permission denied) — it was never a key/format problem, and the first target
     table (`roles`) was simply unreadable by `anon`.
  2. In Supabase, **PostgREST derives the DB role from the JWT in `Authorization: Bearer`** (the
     `apikey` is only the Kong gate). `service_role` in `apikey` **alone** still leaves PostgREST on
     the `anon` role → 401. With `service_role` in the Bearer too it bypasses RLS → **200** + a real
     DB read. (This is exactly how the integration tests authenticate.)
- The cron minute is **`:37`, not `:00`** — GitHub drops top-of-hour scheduled crons on the
  private/Free tier (same reason the T-19 backup moved to `37 4`).
- Like every `schedule:` workflow it fires only from the **default branch (`master`)**; validate
  meanwhile with **Actions → Run workflow** (a `workflow_dispatch` on the branch verified green
  before each merge).
- **Infra/ops only — no app behaviour change, so no version bump** (per the versioning rule; same
  class as `backup.yml`).

**Files affected**
- `.github/workflows/keepalive-dev.yml` (new)
- `CLAUDE.md` (Environments note records the dev-Free auto-pause + this workflow)
- `README.md` (Dev keep-alive subsection)

---

### S-15 — Legal review of the policies + re-consent flow on policy change

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Description**
The two gap-closers S-13 left explicitly flagged, consolidated as the legal
half of the public-availability readiness phase:

1. **Legal review by a professional** of the Privacy Policy and Terms —
   especially the children's-data section (LGPD art. 14: the calendar is about
   a child; "best interest" wording and the legal basis need a lawyer's sign-off)
   and the retention/erasure wording settled by S-11/S-13.
2. **Re-consent flow on policy change**: consent is recorded per profile with
   `consent_policy_version` (`PolicyVersions.Current`), but nothing re-collects
   consent when the policy text changes — legacy profiles stay `NULL` and
   existing users never see updated terms. Implement the version-bump gate:
   on login, a profile whose `consent_policy_version` differs from current gets
   a blocking "policies changed" acceptance screen (diff-style summary), which
   stamps the new version. Legacy `NULL` profiles are captured by the same gate.

**Justification**
Both were accepted as pre-public-availability conditions when S-13 shipped
(July 2026). A policy pointing minors' data handling without legal review, or
consent records frozen at v1 while the text evolves, are compliance debts that
must not reach a public user base.

**Files affected**
- `SharedParentalCustody/Helpers/PolicyVersions.cs` — version bump + effective dates
- `SharedParentalCustody/Pages/` — re-consent gate (login interceptor or dedicated page)
- `supabase/migrations/<ts>_s15_reconsent.sql` — if a consent-history table is chosen over overwrite
- `Pages/Privacy.razor` / `Pages/Terms.razor` — post-review text
- Tests: integration (gate stamps version; NULL legacy captured) + E2E (blocking screen flow)

---

#### Legal review — outcome (30/07/2026)

The external review happened in two rounds (briefing → parecer → adendo → parecer
complementary), both delivered as a table of findings with severity, ready-to-publish
wording and a **materiality** flag per item. **19 findings total**; the Section-5
inventory of what was already built (consent records, export, erasure, retention,
security, incident procedure, channels) came back **approved without reservations**.

**The headline answer — A-3, the one that could have forced a redesign:** the
append-only history does **NOT** conflict with art. 18. Correction is exercised by
*"retificação por anotação"* — the corrected value enters as a NEW record, the previous
log is never erased — and that must be stated in the policy. The immutable-log design
is validated as-is.

**Blocking findings (5):** A-1 child-data consent (art. 14 §1 requires a specific,
highlighted accept — collected **only from whoever creates the family and enters the
child's data**; an invited caregiver instead accepts a **confidentiality declaration**,
and existing invited members must accept it on their next access — MATERIAL),
A-2 supplier identification (CPF/CNPJ + address; a **correspondence address satisfies
Decreto 7.962/2013**, so the founder's home address stays private; PJ recommended within
30–60 days), A-4 invite-e-mail transparency (state BOTH the 7-day link validity and the
≤30-day purge of the pending record — the purge routine did not exist), A-5 suspension
on formal judicial notice (MATERIAL), B-4 re-consent (**hard lock is valid and
proportionate**, with 15 days' notice).

**Non-material by verdict** — everything except A-1 and A-5, so only those two trigger a
re-consent wave. Also settled: C-2 operating **without a cookie banner is sustained**
(server-derived, cookieless, no profiling); C-4 the current transparency **satisfies
art. 46** — field-level encryption is not required; C-5 controller-as-DPO is acceptable at
this scale, the 6-month retention periods are correct, and the consumer's-domicile forum
is *imperative* (CDC art. 101, I); C-6 simple opt-in suffices **provided the opt-in log
(date, time, IP) is kept** — it was not being kept; C-7 replace the "à prova de disputa"
marketing claim (product-owner decision: a factual reformulation, keeping the L-10
differentiation without promising an outcome).

**Two defects in the returned wording, corrected on application:** every suggested text
came in **European Portuguese** ("registos", "conceção", "utilizador", "ficheiros") and is
converted to PT-BR per the language convention; and A-4's original 30-day-only wording
contradicted the implemented 7-day invite expiry — the complementary parecer confirmed
stating both periods.

**Delivery split** (A-4 deliberately moved out of PR1 — its wording depended on the
adendo answer, so PR1 carries no external dependency):
- **PR1 (v1.6.34, this delivery)** — B-4 re-consent gate: `accept_current_policy` RPC
  (validates the version against `policy.current_version` rather than trusting the
  client, since the burden of proof is the controller's — art. 8 §1),
  `policy.enforce_from` for the 15-day window, `PolicyVersions.Evaluate`, the notice
  banner and the non-dismissible `/policy-update` screen. Tests: `PolicyVersionsTests`
  (14 unit cases — notice window, hard lock, legacy NULL, exact version match, two
  authoring invariants) + `ReconsentGateTests` (5 integration cases — stamps the caller
  and nobody else, refuses an invented version **without writing anything**, refuses
  anon, refuses a frozen profile, and pins the code constant against
  `policy.current_version` so a half-done material bump is a red CI gate instead of a
  live lockout).
- **PR2** — the MATERIAL pair A-1 + A-5: child-data consent for the family creator, the
  confidentiality declaration for invited members (needs a reliable "joined via invite"
  marker — `family_invitations.accepted_at` gives an exact backfill, not a heuristic),
  the Terms' judicial-notice suspension clause, `PolicyVersions` bump + the app_settings
  rows, mirrored on the landing.
- **PR3** — the non-material text (A-2 identification with CPF + correspondence address,
  A-3 retificação por anotação, B-1 30-day notice + acquired-rights preservation, B-2,
  B-3, C-1 naming the USA + standard contractual clauses, C-3, C-5), A-4 (purge routine +
  invite copy), plus C-6 (opt-in log in Cloudflare KV) and C-7 on the landing.

**Still open with counsel:** nothing. Three rounds happened (briefing → parecer →
adendo v1 → parecer complementar → adendo v2 → parecer de revisão de premissa) and
every question is answered. The PJ constitution (30–60 days) is a management decision
tracked outside the backlog.

---

#### Third round (adendo v2) — a premise WE gave was wrong

While implementing A-1 we went to the schema to find where the child's data was stored
and **found nothing**: there is no child table, column or field anywhere. The briefing
had told counsel that *"the only child datum is the first name or nickname, entered by
the caregiver"* — a sentence lifted from our own Privacy Policy (§3) instead of verified
against the database. The policy had been overstating it for a long time; the briefing
propagated it into a parecer whose A-1 answer depended on it.

**What the app actually does:** sign-up collects the adult's name, e-mail, the FAMILY
name (free text, suggested as "Ex.: Família Silva & Souza"), role and password. The
child's name can only reach us incidentally — if a caregiver names the family after
them, writes it in a day's free-text note, or types it into the PDF report header field
(which is transient: used at generation, never persisted).

**Counsel's revised position (30/07/2026):**

| ID | Gravidade | Verdict | Material? |
|---|---|---|---|
| **A-1.1** | Obrigatório | With no structured collection, the strict art. 14 §1 consent stops being the primary mechanism. **Remove the extra checkbox**; fold a *termo de ciência e responsabilidade* into the GENERAL acceptance at sign-up. | **Sim** |
| **A-1.2** | Recomendado | The premise change does not affect the invitee: the confidentiality declaration from adendo v1 stands unchanged and remains necessary. | Não |
| **A-1.3** | Obrigatório | Align the Policy to reality. Describing a SMALLER treatment than previously declared is a clarification in the subject's favour — no re-consent needed for it. | Não |
| **C-4.1** | Opcional | Conclusion unchanged: field-level encryption on free text would hurt a transactional system and the existing safeguards satisfy art. 46. Keep the current wording. | Não |
| **C-8** | Recomendado | The PDF header name is "tratamento" (art. 5º, X) even though ephemeral. Disclose the ephemerality. | Não |

**Approved texts, converted to PT-BR** (all three pareceres arrived in European
Portuguese — "recolha", "utilizador", "ecrã", "ficheiros" — so every string below is the
converted form, content untouched):

- **A-1.1 — creator, inside the general acceptance:** "Ao criar a família, declaro estar
  ciente de que o sistema não possui campos próprios para dados da criança.
  Comprometo-me, no uso da minha autoridade parental, a inserir apenas informações
  estritamente necessárias à rotina nos campos de texto livre."
- **A-1.2 — invitee, when accepting the invitation:** "Declaro ter sido convidado(a) para
  acessar o calendário desta família e comprometo-me a manter estrita confidencialidade
  sobre as informações e a rotina da criança/adolescente, utilizando o aplicativo
  exclusivamente para a organização da convivência."
- **A-1.3 — Policy §3/§5:** "Não efetuamos a coleta estruturada de dados de crianças ou
  adolescentes em campos específicos. Sendo a plataforma destinada à organização da
  convivência, os dados da criança (como nome) serão tratados de forma meramente
  incidental, caso os responsáveis optem por inseri-los nos campos de texto livre da
  rotina."
- **C-8 — Policy:** "Na geração de relatórios em PDF, o usuário pode inserir um nome para
  o cabeçalho. Este dado é tratado de forma efêmera e estritamente em memória durante a
  exportação do documento, não sendo armazenado em nenhum banco de dados do Serviço."
- **A-5 — Terms, new subsection (from adendo v1):** "Ao sermos notificados formalmente com
  cópia integral de decisão judicial válida (por exemplo, medidas protetivas) que
  restrinja o contato ou o acesso às informações da criança ou do outro responsável,
  suspenderemos preventiva e imediatamente o acesso do usuário restrito."
- **A-2 — supplier identification (PR3), footer + both documents' preamble:** "Guarda
  Compartilhada é operado por Irineu Junior Pinheiro dos Santos, inscrito no CPF
  750.874.350-41, com endereço para correspondência em CP 4500 — Centro — Porto Alegre —
  RS." (Owner's decision, confirmed by counsel as satisfying Decreto 7.962/2013: a
  correspondence address, not the residential one — the operator is a natural person
  serving users in family conflict.)
- **B-1 — Terms, plan changes:** "As regras dos planos podem ser alteradas mediante aviso
  prévio de 30 dias. Contas ativas antes da referida mudança manterão os seus recursos
  originais (direito adquirido), desde que não cancelem ou alterem voluntariamente o seu
  plano."
- **B-2 — Terms, withdrawal:** "Em cumprimento ao art. 49 do CDC, você pode exercer o
  direito de arrependimento em até 7 dias corridos da contratação. O cancelamento neste
  prazo garante reembolso integral e imediato, processado pelo mesmo método de pagamento,
  independentemente do uso."
- **B-3 — Terms, grace:** "Se houver falha na cobrança, poderemos fornecer um breve período
  de carência a nosso critério. Esgotada a carência, o acesso retornará ao Plano Gratuito.
  Avisaremos por e-mail antes da indisponibilidade."
- **A-3 — Policy, rectification:** "Para garantir a confiabilidade dos registros da
  convivência, o histórico é inalterável por concepção. Exercemos o direito de retificação
  (art. 18, LGPD) exclusivamente por 'retificação por anotação', inserindo o dado correto
  como um novo registro, sem apagar o log anterior."
- **A-4 — invitation e-mail:** "Você foi convidado(a) por [Nome] para gerenciar o calendário
  familiar. Este convite é válido por 7 dias. Seu nome e e-mail foram inseridos sob o
  legítimo interesse do convidador. Caso este convite não seja aceito, seu registro será
  permanentemente expurgado de nossos sistemas em até 30 dias."
- **C-1 — Policy, international transfer:** "Os dados processados pelo Serviço encontram-se
  hospedados nos Estados Unidos. Esta transferência internacional é legitimada pela adoção
  de Cláusulas-Padrão Contratuais equivalentes às exigidas pela LGPD."
- **C-3 — Policy, retention after exit:** "Se optar por sair da família, o seu perfil será
  congelado, mas o seu nome permanecerá atrelado ao histórico das ações passadas, para
  garantia dos direitos dos demais titulares. A eliminação ocorre apenas se a família
  inteira for excluída."
- **C-5 — Policy:** "O Encarregado pelo Tratamento de Dados (DPO) é o próprio Controlador,
  Irineu Junior Pinheiro dos Santos, contatável pelo e-mail privacidade@guardacompartilhada.com.
  Retemos registros de acesso pelo prazo legal de 6 meses (art. 15 do Marco Civil da
  Internet) e notificações lidas por idêntico período. Para a solução de litígios, elege-se
  o foro do domicílio do consumidor."
- **C-7 — landing marketing (owner's decision):** replace "histórico à prova de disputa"
  with a factual reformulation such as "histórico que não pode ser editado nem apagado" —
  it removes the outcome promise counsel objected to while keeping the L-10 differentiation.
  Three occurrences, all in `public/index.html`.

**The enforcement-date decision (owner, 30/07/2026) — option (a).** `EnforceFrom` for the
PR2b material bump is set to a deliberately loose **2026-09-30**, and a one-line corrective
migration moves it to *promotion date + 15* when `dev`→`master` happens. Reason: the 15-day
notice exists so the subject can READ the new text before losing access, and they can only
do that once it is in PRODUCTION — counting from the QA merge would burn the whole window
while the text is invisible to the people it binds. Until then the gate only warns, which is
the correct behaviour anyway. **This is the same class of mistake already made once** (see
v1.6.35: the window was counted from the TEXT's date rather than from the gate's) — the rule
is now: the window starts when the user can actually see the text.

---

#### Delivery status (end of the 30/07/2026 session)

| Delivery | Content | State |
|---|---|---|
| **PR1** (#126–#129, v1.6.34–35) | B-4 re-consent gate: `accept_current_policy` RPC, `policy.*` settings, `PolicyVersions.Evaluate`, notice banner, `/policy-update` screen, 14 unit + 5 integration tests | **merged, green** |
| **PR2a** (#130, v1.6.36) | A-1 foundation: `profiles.joined_via_invite` plus exact backfill and freeze trigger, 5 integration tests | **merged, green** |
| **PR2b** (v1.6.37) | app: the declarations above (A-1.1 creator / A-1.2 invitee, branching on `joined_via_invite`), A-5 Terms clause, A-1.3 §2–§5 rewrite, C-8; `PolicyVersions.Current` → `2026-07-30`, `EnforceFrom` → `2026-09-30`, **plus the two `app_settings` rows in the same migration**; path-dependent text on `/policy-update`; 6 new unit + 1 new integration + 2 new E2E tests | **delivered, awaiting merge** |
| **PR2c** | landing mirror of every legal text changed in PR2b (`privacidade.html` 1.5→1.6, `termos.html` 1.2→1.3), same delivery, "Última atualização" 30/07/2026 on both sides | **delivered, awaiting merge** |
| **PR3a** (v1.6.38) | non-material TEXT: A-2 identification, A-3, C-1, C-3, C-5 (Policy) + A-2, B-1, B-2, B-3 (Terms), mirrored on the landing, plus C-7 (three occurrences in `index.html`). No `PolicyVersions` bump — the parecer was explicit that none of it is material | **delivered, awaiting merge** |
| **PR3b** (v1.6.39) | the CODE half — the two promises the PR3a text made that the code did not keep: A-4 (`purge_stale_invitations` plus invite e-mail copy) and B-3 (`billing_grace_warnings_due` plus `premium_grace_ending` e-mail), both wired into the existing `purge-deleted` daily cron; 11 integration tests. Landing: C-6 (opt-in log in Cloudflare KV) | **delivered, awaiting merge** |

**Traps to respect in PR2b, learned the hard way this session:**
1. `app_settings.value_type` only accepts `('int','decimal','bool','string','json')` — use
   `'string'`, never `'text'` (cost one red gate).
2. Bumping `PolicyVersions.Current` WITHOUT the matching `policy.current_version` row makes
   the RPC refuse every accept in production. `ReconsentGateTests.CodeConstant_MatchesServerSetting`
   turns that into a red CI gate instead of a live lockout — do not weaken it.
3. The E2E fixture signs users up WITH `policy_version`; tests that need a "behind" profile
   must set it themselves rather than assume the fixture's state (cost one red gate).
4. Do NOT edit `handle_new_user` unless unavoidable: ~100 lines re-emitted verbatim per
   migration, and a slip breaks every sign-up.

**Decisions taken while implementing PR2b (30/07/2026):**
- The two declarations live in `Helpers/ConsentDeclarations.cs`, not inline in the pages.
  TWO screens render them — `Register.razor` (which knows the path from the invite token)
  and `/policy-update` (which reads `profiles.joined_via_invite`) — and a shared constant
  is what stops the same person being shown two different legal texts.
- `/policy-update` renders **no declaration at all** until the profile is loaded, and hides
  the accept button meanwhile. Defaulting to either text while it loads would show one
  group the other's declaration and stamp a consent to something the person never
  declared — the exact opposite of what demonstrable consent is for.
- The migration UPSERTs both `policy.*` rows (`ON CONFLICT DO UPDATE`) rather than
  `UPDATE`-ing them: prod carries migration-state drift, so a row this delivery assumes
  exists may not.
- New integration test `EnforceFromConstant_MatchesServerSetting` pins the OTHER half of
  the two-place checklist. `policy.enforce_from` and `PolicyVersions.EnforceFrom` had
  nothing forcing them to agree — a drift would have the server warning while the client
  blocks (or the reverse), both silent. It also guards the promotion-time correction:
  moving only one of the two is now a red gate.
- **Promotion checklist (dev→master), one line each:** a corrective migration setting
  `policy.enforce_from` to *promotion date + 15*, and `PolicyVersions.EnforceFrom` to the
  same value, in the SAME delivery — the test above fails otherwise.

**Decisions taken in PR3a (30/07/2026):**
- **The documents keep 30/07/2026 and `Current` stays `2026-07-30`.** PR2b and PR3a are one
  publication from the reader's point of view — neither reached production. Advancing the
  date would show a document "updated on 31/07" whose consent record points at a version
  nobody in production ever saw; bumping `Current` would fire a second re-consent wave for
  text the parecer explicitly called non-material.
- **A-2 goes in the legal documents only, not in the site footer** (owner's decision). The
  parecer's wording said "footer + preamble"; the preamble of both documents satisfies
  Decreto 7.962/2013, and keeping the CPF off every indexable page limits scraping exposure.
- **C-3 was written from the CODE, not from the parecer's prose.** Counsel described a frozen
  profile whose name stays on the history; S-11 additionally hard-deletes the account after
  the 30-day grace. Both are true and the text now says both — the A-1.3 lesson (a policy
  sentence that had never been checked against the database) applies to any wording we
  receive, not just the one that already burned us.
- **C-7's replacement is the factual characteristic**, not a softer promise: "histórico
  inalterável" / "não pode ser editado nem apagado", which is also the vocabulary the legal
  texts use. Keeps the L-10 differentiation without promising an outcome.

**⚠️ B-3 ships a promise the code does not yet keep — PR3b must close it before promotion.**
While applying B-3 we checked it against the code (the A-1.3 lesson, now applied to every
wording we receive) and found that *"Avisaremos por e-mail antes da indisponibilidade"* has
no implementation: `send-account-email` supports only `member_left`, `member_joined`,
`member_returned` and the three family-deletion types, and `billing_grace_downgrade` (T-39
PR3) downgrades silently — no e-mail, no in-app notification. Owner's decision (30/07/2026):
publish the approved text in PR3a and **implement the notice in PR3b** — a new
`premium_grace_ending` type in `send-account-email`, dispatched from the grace cron before
the downgrade lands. Nothing has reached production yet, so the text binds nobody until the
promotion. **Do NOT promote dev→master while this is open**: on promotion the Terms would
promise a warning that never arrives. Strictly this belongs to T-39 (billing), not S-15 —
it is tracked here because S-15's text is what creates the obligation.
**CLOSED in PR3b (v1.6.39) — the promotion block is lifted.**

**Decisions taken in PR3b (31/07/2026):**
- **Both routines hang off the EXISTING `purge-deleted` daily cron**, next to the S-11
  account/family purges and the S-13 notification retention. No new schedule, no new Edge
  Function, no new runbook step — and the failure of one block cannot stop the others.
- **A-4 purges only `accepted_at IS NULL`.** `set_joined_via_invite()` (PR2a) derives the
  marker by looking this table up by e-mail, so deleting an ACCEPTED invitation would
  silently reclassify that person as a family creator and show them the *creator*
  declaration instead of the confidentiality one. `Accepted_IsNeverPurged_EvenWhenAncient`
  backdates the fixture's own real accepted invitation by 400 days and asserts both the row
  and the marker survive — the A-1/A-4 coupling is the least obvious thing in this delivery.
- **30 days counted from `created_at`**, not from `expires_at`: it is the literal reading of
  "em até 30 dias" and the one more favourable to the subject (37 days would overshoot the
  promise). The e-mail now states BOTH periods, which is what the complementary parecer
  settled — the link dies at 7 days, the record at 30.
- **B-3 warns ADMINS only.** Checkout and the subscription panel are admin-only (F-40/T-39),
  so warning a member would be an alarm they cannot answer.
- **The in-app notice is written by the RPC, inside the same transaction as the sent-marker;
  the e-mail is the best-effort twin** — the S-11 D-3 reminder's exact shape. If Resend is
  down the warning still reached the user, and the marker is deliberately not rolled back: a
  second wave is worse than a missing e-mail whose message already landed in the app.
- **A trigger resets the marker when `overdue_since` changes.** Without it a family warned
  once goes silent forever: it pays, falls overdue months later, and the stale marker
  suppresses the second warning. Keyed to the column the webhook already writes, so no
  webhook code had to change.
- `send-account-email` **refuses `premium_grace_ending` without `graceEndsAt`** rather than
  falling back: `formatDate`'s fallback is the literal string "30 dias", which belongs to the
  account-deletion grace and would state a period that is not this one.

---

### F-42 — Scheduled subscription reactivation (no immediate charge)

| Field | Value |
|---|---|
| **Status** | `completed` (August 2026 — v1.6.40 servidor + v1.6.41 UI) |
| **Priority** | `low` |
| **Complexity** | `medium` |
| **Impact** | `medium` |
| **Depends on** | T-39 (billing live); stored `external_customer_id` (PR2) |
| **Delivery** | PR1 server (`1.6.40`, #150) · PR2 UI (`1.6.41`) |

**Description**
Refinement identified during the T-39 sandbox QA (July 2026): a family that canceled but still
has paid time re-subscribes today by **paying now** — the webhook then ADDS the remaining time
(period counts from the later of payment date / previous period end), so nothing is lost. This
item is the alternative UX: **"Reativar assinatura"** with NO immediate charge — the next
invoice only arrives when the paid period ends.

**Feasibility analysis (recorded July 2026 — inverts the intuition):**
- **Pix/boleto: feasible.** Invoice-style billing needs no stored payment instrument — create an
  Asaas subscription via API for the ALREADY-STORED customer (`external_customer_id`) with
  `nextDueDate = current_period_end`; the charge is emitted at the due date.
- **Card: NOT feasible** under the hosted/no-PCI model — resuming auto-debit requires the card
  (token), which we deliberately never touch. Card re-subscription stays checkout-now +
  additive time (already fair).
- New states to design: a "scheduled" subscription with no payment yet; unpaid first invoice →
  overdue/grace flow; user-facing copy per method. Deliberately deferred so v1 keeps ONE simple,
  uniform model ("each payment buys a period; periods stack"), already made explicit in the UI.

**Files affected**
- `supabase/functions/billing-checkout` — new action `reactivate` (Pix/boleto only)
- Premium section — "Reativar" affordance when canceled-but-paid + method-aware copy
- Tests: scheduled subscription lifecycle; unpaid-first-invoice path

**PR1 — server (`1.6.40`)**
Split 2 PRs (server → UI) because the environment has no `dotnet`, so CI is the first
compiler and a red gate is cheaper to read on a smaller diff.

- **`subscriptions.billing_type`** (migration `20260801120000_f42_scheduled_reactivation`):
	the webhook already received `payment.billingType` but it only reached the raw
	`billing_events.payload` jsonb — unusable as a gate and invisible to the UI, which has to
	decide whether to show the button at all. Stored verbatim, with **no CHECK**: the gateway
	may add values and a webhook failing on an unknown method would stall entitlement for a
	family that actually paid. Readers treat unrecognised values as "not reactivatable".
	Written only when the event carries the field, so an event without it never erases a
	known method.
- **New status `scheduled`**, deliberately NOT a reuse of `pending`: `pending` means "checkout
	started, nobody paid, no gateway subscription", while a scheduled row owns a real
	`external_subscription_id` that emits a charge on its own. Collapsing them would make
	`cancel` (which branches on exactly that field) and the UI copy lie. It also blocks a new
	checkout — otherwise the family would end up with two gateway subscriptions.
- **The non-obvious part — `billing_grace_downgrade`.** It lapses premium for `canceled` rows
	whose paid period ran out, and a reactivated row is no longer canceled. Without adding
	`scheduled` to that rule, a family whose scheduled invoice was never paid — and whose
	`PAYMENT_OVERDUE` was missed or delayed — would keep premium forever, for free. The happy
	path never reaches it (a paid invoice flips the row to `active` and extends the period
	first). Both directions are tested.
- **Price = the currently configured one**, not the value frozen on the canceled row: the
	acquired-price guarantee in the Terms (S-15/B-1) protects **active** accounts, and the UI
	must never schedule a charge different from the one it displayed.
- Due date derived in `America/Sao_Paulo` (the gateway's calendar); no entitlement change at
	reactivation time — the family is premium until `current_period_end` by the F-32 rule
	either way.
- 8 integration tests (`BillingReactivateTests`): the guard chain, every case stopping before
	the gateway is touched, plus the cron's treatment of `scheduled` in both directions.

**PR2 — UI (`1.6.41`)**
- **New `ManageScheduled` block.** Its own state, not a variant of the active panel: this is the
	one situation where the family **owes money later without having authorised a payment today**,
	so the panel states that nothing was charged, WHEN the first charge lands, HOW MUCH and by
	which method, and offers to undo the schedule (canceling there emits no charge at all).
	Styled blue on purpose — neither the green of "already paid" nor the yellow of overdue:
	nothing was charged and nothing is wrong, a date is simply set.
- **The button appears only where the server would accept it.** `BillingService.CanReactivate`
	mirrors the Edge Function's guard chain exactly (canceled · paid time running · stored
	customer · invoice-style method). Offering a button for a call the server refuses is worse
	than not offering it, and duplicating the rule in prose would let the two drift — the unit
	tests pin all four conditions plus the whitelist behaviour.
- **Whitelist, not "not card".** An unrecognised `billing_type` means we cannot tell whether
	charging it needs a stored instrument, so the safe answer is no. Same rule server-side.
- Placed ABOVE the checkout buttons (cheaper for the family) but styled outline, so "pay now"
	stays the visually dominant CTA. Card families never see it and keep the pre-existing copy
	explaining that paying now ADDS the remaining time — nobody is left without a path.
- Own spinner flag (`isReactivating`): all billing buttons share `isBillingBusy`, so without it
	every button would spin at once. Funnel event `premium-reactivate` (T-37). 7 unit tests.

**What this item did NOT change**
Entitlement. The family is premium until `current_period_end` by the F-32 rule whether the row
is canceled or scheduled — reactivation moves bookkeeping and a future charge, nothing else.

---

### F-46 — Trial credit on first payment (additive activation)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.6.43 — delivered Aug 2026) |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `high` |

**What it fixes.** The billing webhook computed the new period end as
`max(dueDate, current_period_end) + 1 cycle`, reading only `subscriptions.current_period_end` —
it never consulted `families.trial_ends_at`. A family paying **during its 30-day trial** got the
paid cycle based at the payment date, silently forfeiting the remaining trial days (pay on day 8
→ ~22 days of Premium lost). The additive rule already existed for paid time (canceled family
with time left extends from the old period end, pinned by
`Renewal_WithPaidTimeLeft_ExtendsFromOldPeriodEnd`); the trial was left out only because it lives
on a column the webhook did not read.

**Rule (owner's model, locked Aug 2026): the trial is a first payment of R$ 0.**
`base = max(dueDate, current_period_end, trial_ends_at-when-future)` → `period_end = base + cycle`.

**Implementation record (v1.6.43):**
- Server-side only, in `billing-webhook/index.ts` (the single writer of the period): the
  ACTIVATING branch now reads `families.trial_ends_at` and a **still-running** trial joins the
  base `max`. A failed family read throws (500 → Asaas retries) instead of silently forfeiting
  the days. All candidates compare as plain UTC instants (`dueDate` parses as UTC midnight) —
  the same convention the existing `max` already used; no third timezone convention added.
- **The consumed trial is cleared** (decision settled at implementation): once folded into the
  paid period, `trial_ends_at` is set to NULL so the period is the single source of the
  entitlement window. Entitlement is unchanged either way (`is_premium()` ORs both) — the clear
  buys a single source, not a behaviour change. Ordered AFTER `set_family_plan('premium')`
  succeeds, so a half-applied event can never cost a family its running trial. An **expired**
  trial is left untouched (history — same stance as the lapsed-trial rule in U-13's record).
- UI: the Offer panel during an active trial gains the mirror of the additive-renewal copy —
  assinar agora **soma** os dias restantes da avaliação (`FamilyPage.razor`, reuses the
  `subscription-paid-until` styling; `else if` after the canceled-with-balance block, the two
  states are mutually exclusive in practice).
- Tests (`BillingGraceTests`): new `FirstPayment_DuringTrial_ExtendsFromTrialEnd` — trial pinned
  at +20d, first payment today, asserts `period_end ≈ trial_end + 1 month`, plan `premium`, and
  `trial_ends_at` cleared. Revealing side-fix: **fresh E2E families carry the +30d trial
  default**, so the post-trial renewal scenario (`t39add`) now clears it explicitly via the new
  `SetTrialAsync` helper — without that, the default would win the `max` and shift that test's
  expected base.
- Prod safety: `billing.enabled=false` in production — no real family ever lost days; this
  landed BEFORE the go-live checklist flips the flag (why it sat first in roadmap group 1).

---

### T-46 — Docs-only pushes skip the CI pipeline (paths-ignore)

| Field | Value |
|---|---|
| **Status** | `completed` (delivered Aug 2026 — no version bump: CI config, no runtime change) |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**What it fixes.** Every push to `dev`/`master` ran the FULL pipeline — setup, migrations +
functions redeploy, unit tests, publish, integration and E2E — even when the push only touched
`backlog/*.md`, `README.md` or `.claude/**`. That cost ~10 min per docs push on `dev` (~17+ on
`master`, full pack) against the private-repo Free budget of 2000 min/month, and every extra run
was one more cancel-in-progress window of the kind that produced the 31/07 orphaned-seed
incident (14 red integration tests on a docs-only commit).

**Implementation record (owner request, Aug 2026):**
- `deploy.yml` push trigger gains `paths-ignore: ['**.md', '.claude/**']`, valid for BOTH
  branches (single workflow). GitHub evaluates the UNION of the push's changed files, so a mixed
  docs+code push still runs everything — and every functional delivery touches code beside its
  README/backlog edits by construction.
- **`.github/**` is deliberately NOT ignored**: a CI change must run the pipeline to validate
  itself. No `.md` is served by the app (nothing under `wwwroot`), so the classification is safe;
  revisit the list if a served `.md` artifact ever appears.
- Consequence accepted: a docs-only push produces NO run (and no green check) — no rulesets
  depend on it (private repo, Free tier). `workflow_dispatch` remains the manual override for a
  full run on demand.
- **Landing mirrored in the same delivery** (`guardacompartilhada-site`): same `paths-ignore` on
  `deploy.yml` + `deploy-preview.yml` (root `*.md` — ROADMAP/README/CLAUDE — are never served;
  only `public/` is). `test.yml` left untouched ON PURPOSE: it is seconds-fast, and adding
  paths-ignore to a PR-gating workflow creates the "expected check that never runs" trap.
- `backup.yml` / `keepalive-dev.yml` untouched.

---

### U-22 — Subscription validity dates visible in every plan state

| Field | Value |
|---|---|
| **Status** | `completed` (delivered Aug 2026, `1.6.44`) |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**What it fixes.** The Premium section of the Família page showed a date in only three states
(`ManageActive`, `ManageScheduled`, canceled-with-paid-time); everything else was dateless —
the trial badge counted days without an end date, `PremiumForever` was a bare badge, lapsed
families got no "expirou em X" anywhere, and `ManageOverdue` never said when the grace window
ends. Scope decision (owner, Aug 2026): **Premium section of the Família page only** — the
scattered paywalls (PDF, calendar horizon, wizard) stay pure upsell copy.

**Implementation record (decisions locked Aug 2026):**
- **Trial badge**: "N dias restantes **(até DD/MM/AAAA)**" — same source
  (`families.trial_ends_at`) as the F-46 additive copy in the offer block, so the two dates
  cannot disagree by construction.
- **`PremiumForever`**: badge and block now say "**Premium permanente — sem expiração**"
  (no date BY DESIGN, said explicitly instead of implied by omission).
- **Lapsed families** (`DescribeExpiredPremium`, new pure helper): the note under the free
  badge renders in EVERY state including the prod waitlist (decision: it is plan information,
  not offer information). No schema migration — the data outlives the downgrade: a lapsed
  trial keeps its past `trial_ends_at` (only subscription downgrades null it), a lapsed payer
  keeps `current_period_end` on the canceled row. Both present → the LATER date wins (when
  access actually ended). Wording branches on the source ("avaliação terminou" vs "Premium
  expirou"). **Overdue rows are excluded** — the ManageOverdue panel owns that message; a
  second date next to the badge would fight it.
- **`ManageOverdue`** (`GraceDeadline`, new pure helper): deadline = `overdue_since +
  billing.grace_days` — the exact formula of the `billing_grace_downgrade` cron and of the
  S-15/B-3 warning e-mail, never a second computation. Past the deadline the copy switches to
  a dedicated "carência terminou em X — acesso encerrado; regularize para reativar" (decision:
  the status stays `overdue` on purpose so a late payment still reactivates, and the old
  static "recursos disponíveis" text would lie after the downgrade).
- **`billing.grace_days` flipped to public** (decision over exposing a server-computed
  deadline): one-UPDATE migration `20260802130000_u22_grace_days_public.sql`. The value is not
  sensitive — the grace-warning e-mail already announces it — and enforcement stays in the
  server cron, so a tampered client can only mis-render a date, never extend its own grace.
  Client reads it via `Settings.GraceDays` (fallback 7, mirroring the seed).

**Files touched**
- `SharedParentalCustody/Pages/FamilyPage.razor` + `.razor.css` — the four state blocks, `.premium-expired-note`
- `SharedParentalCustody/Services/BillingService.cs` — `GraceDeadline`, `ExpiredPremium`/`DescribeExpiredPremium`
- `SharedParentalCustody/Services/SettingsService.cs` — `GraceDays` accessor
- `supabase/migrations/20260802130000_u22_grace_days_public.sql` — is_public flip
- `SharedParentalCustody.Tests/BillingServiceTests.cs` — 5 new facts pinning the helpers
- `SharedParentalCustody.IntegrationTests/BillingWebhookTests.cs` — `BillingSettings_PublicRowsOnly`
  flipped to the new contract (`grace_days` public, value `7`); it asserted the OLD visibility and
  would gate red the moment the migration applied (CI applies migrations before the tests on `dev`)

---

### F-41 — Gate: custom per-family roles (Premium)

| Field | Value |
|---|---|
| **Status** | `in-progress` (v1.6.45 — QA pending) |
| **Priority** | `low` |
| **Complexity** | `medium` |
| **Impact** | `low` |
| **Roadmap** | Phase 6 (Growth track) — last freemium gate (post-F-37…F-40) |
| **Depends on** | F-32 (entitlement); F-37 (extra caregivers make custom roles meaningful); `RoleCatalog` |

**Implementation record (v1.6.45).** Migration `20260802170000_f41_custom_family_roles.sql`.
**Locked decisions (Aug 2026):** (1) custom roles are rows of the SAME `public.roles` table with
`family_id` set (NULL = built-in) — the `profiles`/`family_invitations` FKs keep pointing at one
table and the client keeps one list; a separate table would have forced a two-target `role_id`.
(2) The user's label is stored in BOTH `role` and `label_pt`: `RoleCatalog.Translate` passes
unknown values through unchanged, so the client needs NO new resolution layer (the "custom layer"
the original record imagined turned out to be this pass-through). (3) Creation is admin +
`is_premium()` (`create_custom_role`, optional emoji in the new `emoji` column, dedup
case-insensitive against built-ins AND the family's own rows — partial unique indexes back it:
built-in slugs global, custom labels per family). (4) **Add-only grandfather like F-37**: a family
that drops to free KEEPS its custom roles, visible and assignable — the gate is on creation only.
(5) Deletion (`delete_custom_role`) is admin + **unused-only** (any referencing profile/invitation
→ friendly refusal instead of a raw FK violation); no premium check — removing data is never an
upsell. (6) UI in both places (owner's pick): a "Papéis personalizados" management section on the
family page (list + create form + inline delete confirmation; free admins see the F-37-style
upsell card, funnel event `premium-gate-click`/`gate=custom-roles`) and a shortcut link under the
invite role select; the select shows custom roles emoji-prefixed (`CustomRoleRules.DisplayLabel`).
**Scope hardening the `family_id` column made necessary** (harmless before, a cross-family leak
after): `roles` RLS goes from `USING (true)` to family-scoped; `create_invitation` /
`set_member_role` now require the role to be built-in OR the caller's family's (without it,
family A could assign family B's custom role by id); the `handle_new_user` founder lookup gains
`family_id IS NULL` (a founder has no family — no custom row may resolve). All three replaced
VERBATIM from their latest bodies (T-41 / F-27) with only those guards added.

**QA adjustment 2 (v1.6.47).** The emoji grid outgrew the family page and the invite-form
shortcut was BROKEN — it was a fragment anchor (`href="#custom-roles-section"`), and Blazor's
router resolves `#...` against the root, landing on the calendar (the F-37/F-40
`#premium-section` CTAs share the pattern — watch them in QA). The whole management moved to
its own page **`/custom-roles`** (`Pages/CustomRolesPage.razor`): list with inline edit/delete,
one create-or-edit form with the curated grid, admin guard (non-admins bounce to /family) and
the F-37-style upsell for free; the family page keeps only the renamed link
("✨ Papéis personalizados", a real page route now). **EDIT is new** (`update_custom_role` RPC):
admin + **Premium** (owner decision: editing is premium like creation; deletion stays free),
same bounds/dedup as create (excluding self), and renaming an IN-USE role is allowed by design
(`role_id` is the identity, the label is display; an omitted emoji clears it). 3 new integration
facts (in-use rename + emoji clear; free blocked from edit; dedup + foreign/built-in out of
reach) and the E2E redone for the full page flow (create → edit → invite select → delete).

**QA adjustment (v1.6.46).** The free-text emoji input confused users (no emoji keyboard on
desktop; an open field doesn't communicate what belongs in it). Replaced by a **curated picker
grid** — `CustomRoleRules.EmojiPalette`, ~56 domain-picked emojis (people/ages, family/care,
hearts, nature, home/activities, affectionate nicknames), an explicit "Sem emoji" option and
`aria-pressed` selected state. Grounding: the palette entries are valid **Unicode Emoji
(UTS #51)** sequences; a full searchable picker (CLDR dataset, ~1,900 emojis + PT-BR
annotations) was considered and rejected as WASM weight for marginal gain. **UX-only by
decision**: `create_custom_role` keeps validating length only, so palette changes never need a
migration; a tampered client can only change its own displayed emoji. E2E clicks the grid
(`data-emoji` marker); 2 new unit facts pin the palette (distinct; every entry passes the
validation the server mirrors — a palette emoji the RPC refused would be a trap).

**Description**
Free families use the **built-in role vocabulary** (Pai, Mãe, and the standard caregiver roles);
premium families may define **custom per-family roles** (e.g. a specific relative or arrangement).
- Custom roles are family-scoped rows; `RoleCatalog` stays the client vocabulary source (custom
  labels pass through its unknown-value fallback); `is_premium()` gates creation (existing roles
  keep working on free).

**Justification**
A genuine personalization premium families ask for, but not essential and only meaningful once
3+ caregivers exist (F-37). Kept low/future so the core wedges (F-33, F-37…F-40) shipped first;
delivered Aug 2026 as the closing item of the freemium gate block.

**Files affected**
- `supabase/migrations/20260802170000_f41_custom_family_roles.sql` — schema (family_id, emoji,
  partial unique indexes), RLS, `create_custom_role`/`delete_custom_role`, scope guards in
  `create_invitation`/`set_member_role`/`handle_new_user`
- `Models/Role.cs` — `FamilyId`/`Emoji`/`IsCustom`
- `Helpers/CustomRoleRules.cs` — new; pure validation mirror + display text
- `Services/FamilyService.cs` — `CreateCustomRoleAsync`/`DeleteCustomRoleAsync`
- `Pages/FamilyPage.razor` (+ `.razor.css`) — management section, invite-form shortcut,
  emoji-prefixed select options and member-card labels, upsell card + funnel event
- `Pages/ProfilePage.razor` — role select + header label emoji-prefixed (built-ins unchanged:
  their `emoji` column is NULL, so `DisplayLabel` passes the plain label through)
- Tests: `CustomRoleRulesTests` (12 unit), `CustomRoleTests` (7 integration: free blocked /
  premium allowed / admin-only / cross-family RLS + unassignability / dedup / delete in-use vs
  unused / free keeps existing), `CustomRolesUiTests` (1 E2E, pack p1: create → invite select →
  delete)
