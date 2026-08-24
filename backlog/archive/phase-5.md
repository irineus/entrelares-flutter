# Archive — Phase 5 (Account Management & Compliance)

Implementation records of items completed in Phase 5. Conventions and the summary table: [`../README.md`](../README.md).

---

### T-30 — Automated integration/regression test suite in CI/CD (Phase 5 item 5.1)

| Field | Value |
|---|---|
| **Status** | `completed` (first delivery — scenario expansion continues in T-31/T-32) |
| **Priority** | `high` |
| **Complexity** | `high` |
| **Impact** | `high` |

**What shipped (July 2026)**

*Architecture (decisions recorded in the item's analysis)*
- Runs against the **REAL dev Supabase project**; isolation via the product's own multi-tenancy: each run creates a throwaway **E2E family** (RLS hides it; concurrent runs don't collide). Users are created pre-confirmed via the GoTrue Admin API with real metadata — exercising the actual `handle_new_user`/`create_invitation` path; e-mails use the Resend test domain (`delivered+…@resend.dev`).
- **Cleanup in three layers**: teardown always purges (green or red); pre-run sweep purges orphaned E2E families older than 2h (crashed runs); the `purge_e2e_family` RPC (service_role only) validates the **double signature in the database** (name `E2E-…` AND all e-mails `@resend.dev`) — a fixture bug cannot delete a real family. Auth users removed via Admin API (no FK cascade).
- Two layers: `SharedParentalCustody.IntegrationTests` (PostgREST/RPC direct — DB rules) and `SharedParentalCustody.E2ETests` (Playwright .NET, headless Chromium — UI flows). Local secrets via the git-ignored `e2e.local.env`.

*Delivered tests* — 14 integration (Suite D: S-09 lock, workflow-only actual changes incl. admin on future days, past/frozen days, approved-swap delete, cross-family RLS isolation, last-admin invariant, `set_member_role` rules, invitation single-use) + 6 E2E smoke (founder sign-up with catalog role, invite-link onboarding, wrong password, day assignment reflected on the calendar, swap request→frozen→approved across two browsers, logout). All green against dev, zero residue verified after the runs.

*CI gates (deploy.yml)* — unit → integration → E2E, all **before** any Supabase/deploy step, in the same fail-fast job: a red suite blocks the QA deploy on `dev` pushes and **blocks the PRODUCTION deploy on `master` pushes** (the suite runs against dev, which at ff-only promote time is exactly the code+schema prod receives). Requires the `SUPABASE_SERVICE_ROLE_DEV` secret. Note: the gate runs before `db push`, so migrations a test depends on must already be applied to dev (the normal authoring flow — local push during development — guarantees this).

**Incidents & fixes during the first execution (the suite earning its keep)**
- Test host ran under pt-BR culture → dates like `26/07/2026` in PostgREST filters (22008). Fixed with `TestCulture` module initializers mirroring `Program.cs`.
- `purge_e2e_family` fix-forward #1: `notifications` has no `family_id` (recipient-scoped) — delete now scoped via the family's profiles.
- Fix-forward #2: the audit trigger logs the purge's own `care_schedules` deletes, re-populating `activity_logs` mid-purge — the log delete moved to after the schedules delete.
- **Process incident**: the local Supabase CLI was still linked to PROD (stale `supabase/.temp/project-ref` from an old backup dump) and the first `db push` applied the purge migration to production (harmless: guarded, service_role-only function that would ship there anyway). Lesson recorded in the runbook and memory: **always check `supabase/.temp/project-ref` before a local push**.

**Files affected**
- `SharedParentalCustody.IntegrationTests/` — TestEnv (+`e2e.local.env` support), TestCulture, AdminApi, E2EFamilyFixture, Suite D (3 test classes)
- `SharedParentalCustody.E2ETests/` — TestCulture, UiFixture (Playwright), SmokeTests (6 scenarios)
- `supabase/migrations/20260715152254_purge_e2e_family.sql` + two fix-forwards (`…160546`, `…160718`)
- `.github/workflows/deploy.yml` — regression gate; scoped `dotnet test`/`publish`
- `.gitignore` — `e2e.local.env`

---

### T-31 — Expanded E2E/UI scenario pack (Phase 5 item 5.2)

| Field | Value |
|---|---|
| **Status** | `completed` (3 incremental PRs) |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |

Built on the T-30 infrastructure; grew the suites from D+smoke to full A–F coverage. **18 E2E + 8 integration tests added** (final local run: 22 integration + 24 E2E green; unit unchanged at 84). Delivered in three PRs so each batch stabilized in CI before the next (E2E-against-a-real-runner reliably needs one tuning pass).

**PR 1 — Suites A, B, D+**
- `OnboardingUiTests` (E2E): invalid/expired invite token → friendly message; invite via the Família page UI with role picker.
- `InvitationLifecycleTests` (integration): revoke/resend invalidating old tokens; anon `get_invite_info` (hides garbage); full family cannot issue an invite.
- `PlanningUiTests` (E2E): rotation wizard 7/7 (handoff only on transitions — and the *first* generated day is not a transition); T-27 non-transition hint clears the time, transition persists it; S-09 visual lock for non-admins.
- `RlsHardeningTests` (integration): notification privacy, admin-only `rename_family`, append-only audit log.
- Infra: `[Trait("pack","p0"/"p1")]` (dev gate runs `pack=p0`, master runs all); Playwright **traces uploaded on failure** (`E2E_TRACE_DIR`); per-suite dedicated E2E families; `[assembly: CollectionBehavior(DisableTestParallelization)]`.

**PR 2 — Suite C (workflow)**
- `WorkflowUiTests` (E2E, two browser contexts): reject with reason (calendar unchanged), requester cancel (day thaws), scenario-B message semantics (the production-bug regression), full revert restoring the F-26 snapshot (notes preserved).
- `AutoApprovalTests` (integration): F-24 auto-approve as `system` (>48h) and 24h reminder, via the `auto_approve_expired` RPC with backdated-expiry seeds (deterministic; no e-mails, no clock waits).
- Infra: `NextVisibleDay()`, `UiFixture.ReloadCalendarAsync`. Lesson: service-client DB reads bypass RLS → scope by `family_id`.

**PR 3 — Suites E, F**
- `BulkUiTests` (E2E): the **long-press** that enters selection mode solved once in `UiFixture.LongPressDayAsync` (mouse down held past the 500ms threshold); direct bulk notes; S-09 non-admin keep vs admin overwrite dialog; bulk clear.
- `AdminNotificationsUiTests` (E2E): admin-mode past-day edit (F-14); notifications incoming tab + badge with the overdue flag (folds the C5 urgency badge).
- `ReportsUiTests` (E2E): report totals match a deterministic seed. Isolated in its **own family** — it asserts aggregate totals, so no sibling test's seeded days may leak into the counts (found when it passed alone but failed in-collection).

**CI gates**: `dev` push runs unit + all integration + E2E `pack=p0` (smoke); `master` push runs the full pack before the production deploy. Playwright traces upload as an artifact on any E2E failure.

**Files affected**
- `SharedParentalCustody.E2ETests/` — OnboardingUiTests, PlanningUiTests, WorkflowUiTests, BulkUiTests, AdminReportsUiTests, UiFixture helpers, AssemblyInfo
- `SharedParentalCustody.IntegrationTests/` — InvitationLifecycleTests, RlsHardeningTests, AutoApprovalTests, E2EFamilyFixture helpers
- `.github/workflows/deploy.yml` — pack filter + trace artifact

---

### U-11 — Accessibility (ARIA) sweep (Phase 5 item 5.5)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.5) |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**What shipped (July 2026)** — a pragmatic (not full-WCAG-AA) accessibility pass across the real flows. Baseline was already partial (`<html lang="pt-BR">`, `aria-live` on the toast/progress).

- **Calendar**: each day cell (a real `<button>`) gets a descriptive `aria-label` (date, responsible person, swap/handoff/frozen state, today/selected) built by `GetDayAriaLabel`; the visual spans + badges are `aria-hidden`; the grid is a labelled `role="group"`; `aria-pressed` reflects selection.
- **Bottom sheets** (5 of them): `role="dialog"` + `aria-modal="true"` + `aria-label`; focus moves into the sheet on open (one focus per open, tracked in `OnAfterRenderAsync`); **Esc closes** the open sheet (`OnSheetKeyDown`). Pragmatic level — no full focus trap (that was the WCAG-AA option, declined).
- **Keyboard-accessible bulk entry**: a "Selecionar vários" (☑️) button ARMS selection mode without the mobile long-press — helps keyboard/SR users *and* desktop mouse users. New `selectionArmed` flag feeds `isSelectionMode`.
- **Nav**: the bell icon/badge is `aria-hidden`; the link's name carries the unread count (`NotificationsAriaLabel`); decorative tab/top-link emojis `aria-hidden`; admin toggle gets `aria-pressed` + `aria-label`; logout `aria-label`.
- **Icon-only buttons** across pages (session dismiss ✕, copy invite 📋, rename family ✏️) get `aria-label` with the emoji `aria-hidden`.
- **Family member cards** (clickable `role="button"` divs from F-16) made keyboard-operable: `tabindex="0"` + Enter/Space handler + `aria-label`.
- **Toggle groups** (Notifications tabs, Reports period): `role="group"` + `aria-pressed` per button (deliberately NOT `role="tab"` — avoids promising arrow-key nav we don't implement).
- **Toast**: `role="status"`.

**Testing** — `AccessibilityTests` runs **axe-core** (via `Deque.AxeCore.Playwright`) on login, calendar and profile, failing on critical/serious violations; `color-contrast` excluded for now (palette tuning belongs to U-12). All three green — zero critical/serious. Plus an E2E for the "Selecionar vários" entry point. Full local run: 84 unit + 36 E2E green.

**Deferred (would be full WCAG 2.1 AA)**: calendar arrow-key grid navigation, full focus trapping in dialogs, `role="tab"` tablist semantics with arrow keys, colour-contrast audit (U-12).

**Files affected**
- `SharedParentalCustody/Pages/Home.razor(.css)` — calendar labels, dialog semantics + focus/Esc, selection button
- `SharedParentalCustody/Layout/NavMenu.razor`, `MainLayout.razor` — nav/badge/toast ARIA
- `SharedParentalCustody/Pages/Notifications.razor`, `ReportsSummary.razor`, `FamilyPage.razor`, `Login.razor` — toggle groups, icon buttons, keyboard-operable cards
- `SharedParentalCustody.E2ETests/AccessibilityTests.cs` (+ `Deque.AxeCore.Playwright`), `BulkUiTests.cs`

---

### T-19 — Backup & disaster-recovery documentation (Phase 5 item 5.6)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.6) |
| **Priority** | `low` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**What shipped (July 2026)** — documentation-first, with automation ready to enable.

- **README "Backup & Recovery" section**: what is already protected (schema, functions, front-end are all reproducible from git; migrations are the schema source of truth), the honest **Free-plan limitation** (no automated backups, no PITR — Pro is the recommended durability step before public launch), the logical-dump **strategy** (schema snapshot committed; row data **and** `auth.users` dumped, age-encrypted, never committed, kept local + a second offline copy, ~3-month retention), and a step-by-step **restore procedure** (fresh project → `db push` for schema → auth users before row data for the `profiles.user_id` FK → functions/cron → repoint app → verify). RPO/RTO stated for the current plan.
- **`.github/workflows/backup.yml`** — optional weekly encrypted backup, **disabled by default** (only `workflow_dispatch`; the `schedule:` is commented). Recipient-based age encryption (public key as a secret; private key kept offline — non-interactive, unlike `age -p`). Dumps auth + row data, concatenates, encrypts, deletes plaintext, uploads a 90-day artifact.
- Runbook (`supabase/README.md`) cross-links the new section and workflow; reiterates the CLI-link check before any dump.

**Decisions (July 2026)**: document now + ship automation ready-to-enable (not enabled); primary storage = local + a second offline/personal-cloud copy, always encrypted, never in git.

**Files affected**
- `README.md` — Backup & Recovery section + TOC entry
- `.github/workflows/backup.yml` — ready-to-enable encrypted weekly backup
- `supabase/README.md` — cross-reference

---

### F-16 + F-17 — Profile self-service + LGPD data export (Phase 5 item 5.3)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.3) |
| **Priority** | `medium` |
| **Complexity** | `low` / `medium` |
| **Impact** | `medium` |

**What shipped (July 2026)** — `/profile` (own) and `/profile/{id}` (admin viewing a member). Own: edit name; change e-mail (GoTrue confirmation link → a DB trigger syncs `profiles.email`); password change moved to reset-e-mail only (QA/S-10 decision — no inline form). Admin editing another member: name + role + admin toggle + "send password reset" — **e-mail and password stay personal** (an admin changing the co-parent's login e-mail would enable account takeover). Migration `profile_self_service`: e-mail sync trigger, a `role_id` guard in `enforce_profile_protection` (the own-row policy must not be a side door for self role edits — F-27 coherence), and the `update_member_name` RPC. **F-17**: a "📦 Exportar meus dados" button builds a single JSON (profile, family, members, full calendar, swap requests, own notifications, audit log; accents kept readable) client-side via `ExportService` + `js/download.js`. Family page became read-only navigation (cards → profiles). Tests: 5 integration (name rules, role guard, RPC, e-mail sync) + 4 E2E.

**Files affected**: `supabase/migrations/20260716113637_profile_self_service.sql`; `Pages/ProfilePage.razor(.css)`, `FamilyPage.razor`; `Services/ProfileService.cs`, `FamilyService.cs`, `AuthService.cs`, `ExportService.cs`; `wwwroot/js/download.js`.

---

### F-18 — Terms of Service + Privacy Policy pages with sign-up consent (Phase 5 item 5.4)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.4) |
| **Priority** | `low` |
| **Complexity** | `low` |
| **Impact** | `low` |

**What shipped (July 2026)** — in-app `/privacy` and `/terms` pages (public routes in `EnforceAuth`, reachable pre-sign-up), PT-BR LGPD/terms **drafts** with a "pending legal review" banner and `[ ]` placeholders (controller, contact, foro, retention). Links in the Login and Profile footers. **Consent gate** on Register: a required "Li e aceito…" checkbox that disables "Criar conta" until checked (validated on submit too), for founder and invitee. 4 E2E (public pages + cross-link, login links, consent gate, profile links); the two sign-up smokes updated to tick consent. Note: consent is not yet *recorded* (timestamp + policy version) — tracked in S-13.

**Files affected**: `Pages/Privacy.razor`, `Terms.razor`, `Register.razor(.css)`, `Login.razor`, `ProfilePage.razor`; `Layout/MainLayout.razor` (public routes); `wwwroot/css/shared.css`.

---

### F-23 — Near-live calendar sync by polling (Phase 5 item 5.7)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.7) |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Key finding (July 2026):** **Supabase Realtime's WebSocket transport is unsupported in Blazor WASM** — the SDK's `Websocket.Client`/`ClientWebSocket` throws `Arg_PlatformNotSupported` in the browser sandbox (verified live in the browser console). The pre-existing `NotificationService` "Realtime" had been silently failing for the same reason (its try/catch swallowed it; the badge updated via refresh fallbacks). So the backlog's "depends on T-22 (SDK upgrade)" was wrong about the cause — the blocker is the WASM platform, not the SDK version. True push is deferred to **F-29** (supabase-js interop bridge).

**What shipped instead — polling (user-approved):** the calendar refreshes itself every **25s** (paused while the tab is hidden) and **immediately on tab focus** (`visibilitychange` via `js/swipe.js` → `[JSInvokable] OnVisibilityChanged`). The refresh is **quiet** — no loading skeleton, no state churn — and **only re-renders when the data actually changed** (signature comparison of schedules + frozen requests + today). Critically, it is **suppressed while the user is interacting** (selecting days, any sheet/wizard open, saving), so it never clears a bulk selection or interrupts an edit; it resumes when idle. Subscribes conceptually to both schedules and swap-request (frozen) state. Verified live in the browser: a change to a *different* day did NOT disturb an active 2-day selection, and appeared right after the selection was cancelled. Tests: 2 E2E (other-parent edit + swap-freeze appearing within the poll window).

**Files affected**: `Pages/Home.razor` (poll timer, `RefreshCalendarQuietlyAsync`, signatures, visibility handler; removed the dead Realtime wiring), `Services/CustodyService.cs` (removed the non-working Realtime methods), `wwwroot/js/swipe.js` (`registerVisibility`).

---

### F-28 — Multiple caregivers per family (Phase 5 item 5.8)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.8) |
| **Priority** | `low` |
| **Complexity** | `high` |
| **Impact** | `high` |

**Design decisions (July 2026)** — cap of **4 caregivers** per family (matches the F-27 member-slot palette; raising it later = bump `max_seats` in `create_invitation`/`handle_new_user` + extend the role-1..4 CSS themes). **Scenario C forbidden**: a swap may only be OPENED by a participant — the day's planned responsible (giving the day, scenario A) or a member proposing themselves (taking it, scenario B); a third member proposing someone else would hand that person the day without consent. Key consequence: with C forbidden, the proposed parent is always requester or approver, so every existing two-party workflow text ("você…") remains semantically correct with N members — the feared full text rewrite shrank to fan-out messages (new, explicit names by design) and cosmetic fallbacks. **Fan-out**: in-app-only informational notification (`swap_family_info`, 👪) to uninvolved caregivers on CALENDAR-CHANGING events only (approval, revert approval, auto-approval) — requests/rejections/cancellations stay between the two parties; no e-mail.

**What shipped — PR1 (#29, membership)**: migration `multi_caregiver_membership` — `create_invitation` cap = members + OPEN invitations (an open invite reserves a seat, so parallel invites cannot overshoot at acceptance; expired/revoked can't be accepted, making the acceptance-time check pure defense-in-depth) and per-e-mail resend revocation (the old rule revoked ALL pending invites — inviting a 2nd person would kill the 1st's invite); `handle_new_user` acceptance cap 2→4. Família page: open invitations as a card LIST + the invite form visible while seats remain (`btn-invite-send` distinct hook — `.btn-invite` was ambiguous with the cards' resend button, same trap as U-11's `.btn-wizard`).

**PR2 (workflow)**: `RequesterParticipates` gate (static, unit-tested) enforced in `CreateSwapRequestAsync` (throws), in the day editor (the "Responsável real" select offers only self/planned/current-actual when the user is not the day's planned parent) and per-day in bulk (scenario-C days are counted as skipped, not failed — a bulk proposing someone else lands only on the user's own planned days). `NotifyUninvolvedMembersAsync` in approve/revert-approve; migration `auto_approve_family_fanout` mirrors it in `auto_approve_expired` (explicit-name messages built in SQL). Rotation wizard freed from the "every member must appear in the cycle" rule (a Babá/Avó outside the rotation no longer blocks generation; min = 1 block). Frozen-badge tooltip names the approver. `E2EFamilyFixture.EnsureThirdMemberAsync` (lazy shared 3rd member via the real invite flow).

**Tests**: unit +4 (gate scenarios A/B/C + two-member sanity); integration +4 (3rd member joins, invites coexist/per-e-mail resend, 5th-seat block, auto-approve fan-out — the last one seeds expiry at 84h because C6's 60h backdated date collided with UNIQUE(family, date)); E2E +4 (multi-invite family page; scenario-C options hidden in the editor; approved swap notifying the uninvolved caregiver end-to-end incl. the Notifications UI; wizard generating without every member). Full packs green: 88 unit + 30 integration + 42 E2E.

**Files**: `supabase/migrations/20260717023010_multi_caregiver_membership.sql`, `20260717025853_auto_approve_family_fanout.sql`; `Services/SwapRequestService.cs`, `FamilyService.cs`; `Pages/FamilyPage.razor`, `Home.razor`, `Notifications.razor` (👪 icon), `Components/ScheduleWizard.razor`; `IntegrationTests/{E2EFamilyFixture,MultiCaregiverTests,AutoApprovalTests,InvitationLifecycleTests}.cs`; `E2ETests/{OnboardingUiTests,MultiCaregiverUiTests}.cs`.

---

### U-17 — Auto-confirm invitee sign-ups (Phase 5 item 5.9)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.9) |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Origin (July 2026)** — QA feedback while testing F-28: "why must an invitee confirm their e-mail if the invitation ARRIVED at that e-mail and the address is locked at registration?" Assessment: for the mailbox-link path the confirmation is fully redundant (clicking the invite link already proves mailbox control); the copied-link (WhatsApp) path is the only case where it adds anything — catching a founder's typo before it silently sticks to the account. Product decision: **auto-confirm invitees** (industry-standard for invite flows; the token gates who may register and the account e-mail is always the invitation's address, never caller-chosen; a wrong address remains fixable via the F-16 profile e-mail change). **Founders keep the confirmation e-mail** — their address is free-typed, so confirmation is the only ownership check there.

**What shipped** — new Edge Function `register-invitee` (service role, anon-invokable): validates the payload (mirrors the form's 8-char password rule — the Admin API bypasses the sign-up password policy), resolves the token to a pending unexpired invitation, and creates the user **pre-confirmed** via the GoTrue Admin API with the same `user_metadata` shape as a normal sign-up — so the `handle_new_user` trigger does everything it always did (re-validate, create profile, join family, mark invite accepted). PT-BR error contract (invalid token, duplicate e-mail 409, trigger messages passed through). Client: `AuthService.RegisterInviteeAsync` calls it via plain `HttpClient` with the anon key (the Functions client hides error bodies) and `Register.razor`'s invite branch signs in right after and `forceLoad`s home (DI-scope invariant) — the "Confirme seu e-mail" screen no longer appears for invitees. CI deploys the new function (deploy.yml).

**Tests** — integration +3 (valid token → immediate sign-in proves confirmed + profile in family; garbage token refused; weak password refused); E2E smoke A2 updated: the invitee lands on the home calendar directly. Packs: 88 unit + 34 integration + 43 E2E green.

**Files**: `supabase/functions/register-invitee/index.ts`; `Services/AuthService.cs`; `Pages/Register.razor`; `.github/workflows/deploy.yml`; `IntegrationTests/RegisterInviteeTests.cs`; `E2ETests/SmokeTests.cs`.

**Residual risk, accepted knowingly (desktop-session record, July 2026)** — an invitee arriving via a copied/WhatsApp link never proves mailbox ownership; a founder's typo in the invite address then sticks silently (notifications lost; reset e-mails land in a stranger's mailbox). Accepted because the invite e-mail itself would reach the wrong mailbox anyway (confirmation would add little), and the profile e-mail change (F-16) is the correction path. If this ever surfaces in support, this analysis is why.

---

### S-10 — Re-authentication layer for sensitive account operations (Phase 5 item 5.10)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.10) |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Origin (July 2026)** — F-16 QA review: a device left unlocked with the app signed in could perform every account operation with no extra barrier. Threat model: the co-parent is a realistic adversary with physical-access opportunities (shared child devices, family gatherings); secondarily, a stolen session token. The calendar already has two-party consent — the ACCOUNT layer trusted any open session completely.

**Design decisions**
- **"Sudo mode"**: touching a protected action without an active elevation opens a 🔐 password bottom-sheet; a correct password grants a **5-minute elevation window** during which protected actions flow without re-asking. Client throttle mirrors the login rule (3 failures → 60 s cooldown); GoTrue's own password-grant rate limits cover the server side.
- **Verification mechanics**: the `elevate` Edge Function resolves the user FROM THE JWT, verifies the password via a **throwaway GoTrue password grant** with the anon key (tokens discarded — the caller's session is never touched, same `HttpClient` pattern as U-17), then upserts `auth_elevations.elevated_until` with the service role.
- **Server-enforced depth**: `is_elevated()` (SECURITY DEFINER) is checked INSIDE `set_member_admin` — a stolen token cannot flip admin flags without the password. The RPC raises the detectable `ELEVATION_REQUIRED:` contract so the client reopens the prompt and retries. E-mail change and password resets ride GoTrue (client gate + GoTrue's own double-confirmation); the LGPD export is client-gated only (RLS already grants read). S-11's deletion RPCs will reuse this exact foundation.
- **Scope gated in the UI**: e-mail change, admin toggle, other-member password reset, LGPD export, and the NEW inline password change (current password always demanded first; the reset e-mail stays as the forgot-password path — GoTrue "secure password change" not needed on top). Invitations and admin mode stayed ungated (decision), but ARE audited.
- **Audit trail**: new append-only `account_logs` (separate from the calendar-shaped `activity_logs`; family FK CASCADE, profile FKs SET NULL — `purge_e2e_family` needs no change). Written ONLY by SECURITY DEFINER triggers on `profiles` (is_admin/role_id/full_name/email — the latter also captures the GoTrue e-mail sync), `families` (rename) and `family_invitations` (created/revoked/accepted), plus the whitelisted self-action RPC `log_account_action` (`password_changed`, `email_change_requested`, `data_exported` — at worst a user pollutes their OWN trail with true action names). Surfaced in a new **"Conta" tab** on the audit report with PT-BR labels.
- **Session hardening (item 3)**: the 5-minute elevation already IS the "shorter window for sensitive actions"; the 30-minute inactivity timeout (S-04) stays as is.

**What shipped** — migration `s10_sudo_elevation_account_logs` (auth_elevations + RLS own-read, `is_elevated()`, `set_member_admin` gate, `account_logs` + family-scoped RLS + triggers + `log_account_action`); Edge Function `elevate` (PT-BR errors, 429 passthrough) wired into deploy.yml; client `SudoService` (elevation mirror, 3×/60 s throttle, `ELEVATION_REQUIRED` detection helpers) + `SudoPrompt` sheet component (chrome in ProfilePage, per the bottom-sheet pattern); ProfilePage gates via a `RequireSudoAsync` wrapper that parks the pending action and replays it after confirmation; `AuditService.GetAccountLogsAsync`/`LogAccountActionAsync` + the ReportsAudit "Conta" tab.

**Tests** — integration +6 (`SudoElevationTests`: rejection without/with expired elevation; elevated toggle with `admin_granted`/`admin_revoked` audit rows; whitelist forgery rejected + real self-action logged; family-B cannot read family-A logs; deployed `elevate` refuses a wrong password 401). `AdminRpcTests.LastAdmin_CannotBeDemoted` now elevates first (the gate runs before the invariant). E2E: ProfileUiTests handle the sudo sheet on admin toggle and export; the own-profile test asserts the inline password form EXISTS (S-10 reversed the F-16 stopgap). Elevation seeding helper on the fixture (service client, 10-min rows). Unit pack unchanged (93 green) — the new logic lives in the database and the function.

**Files**: `supabase/migrations/20260718113000_s10_sudo_elevation_account_logs.sql`; `supabase/functions/elevate/index.ts`; `.github/workflows/deploy.yml`; `Services/{SudoService,AuditService}.cs`; `Models/AccountLog.cs`; `Pages/{ProfilePage.razor,ProfilePage.razor.css,ReportsAudit.razor}`; `Pages/Components/{SudoPrompt.razor,SudoPrompt.razor.css}`; `Program.cs`; `IntegrationTests/{SudoElevationTests,AuthElevation,E2EFamilyFixture,AdminRpcTests}.cs`; `E2ETests/ProfileUiTests.cs`.

**QA refinement (July 2026, same release)** — family-wide visibility of `account_logs` was narrowed: the whitelisted **self-actions** (`password_changed`, `email_change_requested`, `data_exported`) are now visible **only to their author** (migration `s10_self_actions_owner_only` rewrites the SELECT policy). Rationale: governance events demand two-party oversight, but the personal signals are sensitive in a custody dispute (a data export may reveal litigation prep; a password change reads as "locking down") and exist for the account OWNER to detect misuse of their own account. Governance events stay family-wide. Locked by `SudoElevationTests.SelfActions_VisibleOnlyToAuthor_GovernanceVisibleToFamily`.

---

### S-11 — Right to erasure: account and family deletion (Phase 5 item 5.11)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.11–v1.5.29 across PR1, PR2 and the QA pass; in production with v1.6.0) |
| **Priority** | `high` |
| **Complexity** | `high` |
| **Impact** | `high` |

**Decisions settled with the product owner (July 2026)** — two distinct operations:

*Individual exit (leave the family) — PR1, shipped v1.5.11:*
- Always available (individual right). PAST is immutable and KEEPS the leaving member's full name (anti-tamper: who did each past action stays knowable; retention grounded in art. 16 — legal defense; wording to be aligned in S-13). FUTURE is cleared at request: planned days deleted, approved swaps where they are the real parent reverted to the planned parent, their pending swaps cancelled.
- The seat frees IMMEDIATELY on request (an admin may invite a replacement at once). 30-day grace with a `/leaving` restore/wait screen; cancel restores membership only if a seat is still free (accepted trade-off: if the seat was refilled, no return, and cleared future days are not auto-restored). Sudo-gated (S-10).
- After 30 days the `purge-deleted` cron deletes the GoTrue user and tombstones the profile (name kept, e-mail scrubbed, `user_id` NULL via ON DELETE SET NULL).
- **Admin succession (v1.5.12):** if the leaver is the ONLY admin and other members remain, the exit screen requires a **successor** (chosen from the active members), promoted to admin BEFORE the leave — the >= 1 admin invariant never breaks.
- **Last-member family removal (v1.5.12, no-consent case moved here from PR2):** the last active member's exit is no longer blocked — it schedules the WHOLE family for removal (own warning, no successor selector). The `purge-deleted` cron detects "no active members remain" and runs `purge_family_data` (ordered teardown of all family rows + returns the member auth uids); cancel within the grace restores everything. Admin-initiated deletion of a family that still has OTHER members (multi-party consent) remains PR2.
- **Departed member is frozen (v1.5.13, QA fix):** the `left_at` flag was not enforced — an admin could still rename/promote a departed member and assign them days. Enforcement now lives in the DB: `enforce_profile_protection` makes a `left_at` profile immutable (only the erasure cleanup or the owner cancelling their own exit may write it) and `enforce_day_protection` blocks NEW assignment of a departed member to any day (past history keeps their name). UI mirrors it: read-only profile with a banner, active-only parent selectors (day/bulk/wizard), and a "Saiu" badge on the family page (excluded from the seat count).
- **Transparency / informed consent (product owner, July 2026):** the confirmation screen enumerates ALL consequences before the member confirms (30-day grace + how to cancel; future days affected IRREVERSIBLY — manual re-adjustment if they return; past kept with their name; other members will be notified). On leave, **every other active member is notified in-app AND by e-mail** (`send-account-email`, `member_left`), and the **leaver receives a confirmation e-mail** with the same consequence details. Reliable channel = the DB-created in-app notifications; e-mail is best-effort (like invitation e-mail). *Future improvement (not scheduled):* include, in the others' notice, a concrete report of the freed future days each member now needs to cover.
- **Roster-change notices (v1.5.14):** a member JOINING notifies every existing active member (in-app trigger `notify_member_joined` + e-mail `member_joined` from `register-invitee`); a member RETURNING (cancelling their exit) notifies every other active member (in-app in `cancel_account_deletion` + e-mail `member_returned`). Distinct texts per case.
- **Persistent color slots (v1.5.15, QA fix):** the calendar color was the position among the family's first 4 profiles by id — a departed member stayed colored in the legend forever (the tombstone never leaves) and a 5th joiner rendered with the FOUNDER's color. Now `profiles.color_slot` (1–4) is bound to the PERSON: assigned at join (lowest slot free among ACTIVE members — reuses the departed's color), never changed by others' moves, reclaimed on return if still free (else next free), guarded in `enforce_profile_protection` (system-managed). Inactive members render in a single gray hatched theme (`role-0`) everywhere, past days included (accepted: history is consult-only); the legend names in-grace members ("(saiu)") until replaced, plus a generic "Saiu da família" badge when the visible month shows older ex-members' days.
- **Live roster sync + today-as-future (v1.5.16, QA fix):** the F-23 calendar poll now also refreshes the roster (`ProfileService.GetAllProfilesFreshAsync`, bypassing the 5-min TTL) with a `RosterSignature`, so a departure/join/return/color/admin change reflects live for other open sessions — legend, colors, cleared days and the today card update without reopening the app. And the exit cleanup now treats TODAY as a future day (`schedule_date >= today`, even past the handoff), so a departed member's current-day assignment is cleared instead of getting stuck (a regular member cannot reassign a day's planned parent). Also in v1.5.16: the day editor honors its own "view-only" banner — on past/frozen days, regular members get every field (planned, actual, notes, handoff) and the Save button DISABLED (`IsSaveDayBlocked`, previously only checked at save time), and a departed assignee shows by NAME ("Fulano (saiu)") in the day's selects instead of disappearing from the active-only lists (consult mode).

- **Cross-family migration (v1.5.19, QA follow-up):** a caregiver who LEFT a family (30-day grace, GoTrue user still alive) and is then invited to a DIFFERENT family could not finish sign-up — `auth.admin.createUser` failed with "already registered" (the **1 e-mail = 1 família** limitation). Now `register-invitee` detects the departed member (`departed_member_family`), returns `needsMigration` + the previous family's name so the register page **warns** that joining permanently erases the old registration, and on `confirmMigration` runs the definitive erasure NOW via `purge_departed_member_by_email` (same branch as the grace cron — whole-family purge if they were the last active member, else tombstone scrub) + deletes the freed GoTrue user(s), then retries the creation for the new family. Both DB helpers are service_role only; the invite token stays the capability and `create_invitation` still forbids inviting ACTIVE members, so only a genuinely departed e-mail reaches this path. True multi-family membership (1 e-mail ↔ N famílias) is deferred to **F-30**.

*Whole-family deletion — PR2, shipped v1.5.20 (QA pending):*
- Last active member leaving → family purged 30 days later (no consent needed — shipped in PR1, v1.5.12).
- Admin-initiated → all other active members must consent within 30 days. **Silence for 30 days counts as consent (yes).** **Any explicit refusal ends the request immediately** (family continues). **The requester may withdraw** (sudo) at any time — a new request restarts the 30 days. The app stays usable during the window with a persistent banner ("Exclusão solicitada — responda até DD/MM"); invitations are blocked while pending. In-app + Resend e-mail notifications to all members. After 30 days without refusal/withdrawal → full purge (history included) + GoTrue users via Admin API, reusing the `purge_family_data` ordered teardown. An individual exit is blocked while a family deletion is pending (one destructive flow at a time).
- Audit log of the family (custody history) is purged in full after the grace (art. 16 retention satisfied by the 30-day window + the F-17 export available before approving).
- **Same transparency process as the individual exit, analogously (product owner, July 2026):** the requester sees a full-consequence confirmation before requesting; all members are notified in-app AND by e-mail on request, on refusal/withdrawal, and before the final purge; `send-account-email` gained the `family_deletion_requested/refused/withdrawn/reminder/completed` e-mail types.
- **Implementation decisions (confirmed at build, July 2026):** the 30-day window **always runs in full** — an explicit "Concordar" is recorded for the status panel but never accelerates the purge (the window doubles as the regret grace; that's also why responding needs no sudo, while requesting/withdrawing do). **Superseded in part by the QA pass (v1.5.29):** with the EXPLICIT agreement of every other active member, any active **admin may execute the deletion immediately** (`execute_family_deletion`, sudo — brings `scheduled_for` to now; the client invokes `purge-deleted` right after, reusing the cron machinery); an agreement can be **undone** back to "aguardando" (`respond_family_deletion(NULL)`) while execution has not happened; the Concordar flow warns about the immediate-execution consequence (still sudo-free — the destructive final act carries the sudo); banner/panel show "confirmada para até DD/MM" under unanimity; the request/consent UI lives on the **family page** (moved from the profile); after the purge, open sessions detect the missing profile and sign out cleanly ("family_deleted" message on login). A member in individual-exit grace **may still cancel and return** while a family deletion is pending — returning restores active membership *including the right to refuse* (protects against an admin requesting deletion right after someone leaves). The **pre-purge reminder fires at D-3**, once (`reminder_sent_at`), in-app via `family_deletion_reminders_due()` + e-mail via the cron. The final farewell e-mail goes to addresses collected **before** the teardown (`purge_expired_family_deletions()` returns uid + real e-mail + family name; tombstoned members are naturally excluded). Tables `family_deletion_requests` (one pending per family via partial unique index) and `family_deletion_responses` are SELECT-only under RLS — every write goes through `request/respond/withdraw_family_deletion`.

**Description**
Raised during the F-18 review (July 2026). The app implements the right of access (F-17 export) and rectification (F-16 profile edit) but has **no deletion flow at all** — there is no way for a user to delete their account or the family's data, which the LGPD (art. 18, V/VI — anonymization/deletion and revocation of consent) requires. Nothing in the schema is soft-deletable today (no `deleted_at` anywhere).

**Design — two stages (recommended):**

*1. Logical (soft) deletion first*
- Add `deleted_at` / `deletion_scheduled_for` to `families` (and cascade the "hidden" state to the family's data via RLS: soft-deleted families disappear from every read). The account can no longer sign in (or signs in only to a "restore / confirm deletion" screen).
- A **grace period** (e.g. 30 days) lets the user cancel — protects against impulsive or coerced deletion in a custody dispute, and against one party trying to erase shared history.

*2. Physical (hard) deletion after the grace period*
- A scheduled job (Edge Function cron, like F-24) hard-deletes families past their grace period: purge `notifications → swap_requests → activity_logs → care_schedules → family_invitations → profiles → families`, then the `auth.users` rows via the Admin API (same ordered teardown already proven in `purge_e2e_family`).

**Key decisions to settle at implementation:**
- **Family is SHARED (two members).** Can one member unilaterally delete the whole family, erasing the other parent's custody records? Likely **no** — deletion of shared data should require both members' consent (mirrors the swap workflow's two-party principle) OR delete only the requester's *personal* data while preserving the shared calendar until both leave. Individual-account deletion vs whole-family deletion must be distinguished.
- **Audit log has potential legal weight** (custody history). Decide whether erasure truly removes it or whether a legal-retention exception applies (LGPD art. 16 allows retention for legal obligation / defense).
- **Children's data**: the calendar is about a child; erasure semantics must consider the child's record specifically.
- Ties to **S-10** (deletion is a sensitive operation → re-auth) and **S-13** (retention policy).

**Files affected**
- `supabase/migrations/<ts>_family_deletion.sql` — soft-delete columns, RLS filters, `request_family_deletion` / `cancel_family_deletion` RPCs, hard-delete purge function
- `supabase/functions/purge-deleted/index.ts` — scheduled hard delete (cron)
- `SharedParentalCustody/Pages/ProfilePage.razor` (or a settings section) — request/cancel deletion UI with strong confirmation
- `SharedParentalCustody/Services/` — deletion service methods
- Tests: integration (soft-delete hides data, grace-period cancel, two-party rule, hard purge) + E2E (request + confirm flow)

---

### S-12 — Encryption posture: document reality + evaluate column-level encryption (Phase 5 item 5.12)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.21) |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Origin (July 2026)** — F-18 review, correcting a common misconception: the privacy policy claimed only password encryption, while the real posture was both better (platform AES-256 at rest, TLS, bcrypt, GPG-encrypted backups) and unstated (no application/column-level encryption anywhere).

**What shipped**
1. **Documented posture** — new README section "Data Security & Encryption Posture" (at rest / in transit / passwords / backups / access control / column-level, verified reality per layer) and the RLS table caught up with the S-10/S-11 tables (`auth_elevations`, `account_logs`, `family_deletion_requests/responses`). Privacy policy §7 rewritten honestly (PT-BR): TLS in transit, AES-256 at rest by the provider, bcrypt-only passwords, RLS + zero anon access, explicit statement that free-text fields carry **no per-field encryption layer** plus guidance to keep notes minimal; §2 now says "hash criptográfico", not "criptografada".
2. **Column-level encryption decision (product owner, July 2026): NOT adopted.** Client-held keys are unworkable in a Blazor WASM app shared by up to 4 caregivers (public code, shared-key escrow, rotation on member exit); a server-held key (pgcrypto/Vault) mainly re-covers what disk-level AES-256 already covers while breaking server-side filtering and the audit-log snapshot/restore (F-26). Proportionate posture = platform encryption + access-control hardening. **Revisit before public availability, alongside S-13.**
3. **Access-control hardening review** — `service_role` confirmed absent from client code, committed config and workflows (only Edge Function env, CI secrets, git-ignored `e2e.local.env`); every table confirmed RLS-enabled with grants only to `authenticated`/`service_role`; and the "anon reads nothing" claim became a **permanent CI guarantee**: `RlsHardeningTests.AnonKey_WithoutSession_ReadsNothingFromAnyTable` sweeps all 12 application tables with an anon-key client and asserts zero rows leak (rejection or empty both pass; a returned row fails). Supabase Dashboard security advisors remain a manual periodic check (runbook).

**Files**: `README.md`; `SharedParentalCustody/Pages/Privacy.razor`; `SharedParentalCustody.IntegrationTests/RlsHardeningTests.cs`.

---

### S-13 — LGPD compliance hardening (Phase 5 item 5.13)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.22) |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Origin (July 2026)** — F-18 review: the accountability scaffolding beyond access/rectification/erasure (arts. 6, 8, 14, 37–39, 41, 48) for an app processing a child's custody data.

**What shipped (per backlog point)**
1. **Consent records (art. 8 §1)** — `profiles.consent_accepted_at` + `consent_policy_version`, stamped by `handle_new_user` from sign-up metadata; both sign-up paths send `policy_version` (`AuthService.SignUpAsync` metadata / `register-invitee` payload → user_metadata). Single version source: `Helpers/PolicyVersions.Current` (= the policies' "Última atualização" date; bump on material change). **Legacy profiles stay NULL deliberately** — consent happened (F-18 checkbox) but was not recorded; backfilling would fabricate evidence. *Future improvement:* re-consent flow when the policy version changes (also covers legacy NULLs).
2. **Retention + purge (art. 6, III; periods = product owner, July 2026)** — read notifications > **6 months** deleted by `purge_old_notifications()` in the hourly `purge-deleted` cron; calendar/swap/audit kept for the account-family lifetime (art. 16); accounts purged 30 days after exit (S-11); backups ~3 months (T-19). Privacy §5 placeholder replaced by the real table.
3. **Controller designated** — Irineu Junior Pinheiro dos Santos, contact `privacidade@guardacompartilhada.com` (address creation = **T-34**, before public availability); Terms: contact + **foro Comarca de Porto Alegre/RS**. Policy/Terms dates → 2026-07-21.
4. **Operators (art. 39)** — README table: Supabase (all app data), Resend (transactional e-mail), Cloudflare (hosting + encrypted backups), GitHub (code only), each with DPA link.
5. **Children's data (art. 14)** — Privacy §8: no data collected FROM the child, no child-registration field; processing by parents/guardians under parental authority, best-interest + minimization guidance. **Legal-review flag before public availability stands.**
6. **PII in logs** — audited: `ErrorLoggingService` is in-memory + browser console only, no external sink; recorded as an invariant for T-12 (scrub before any future sink).
7. **Breach response (art. 48)** — runbook §8: contain (rotate keys, preserve logs), assess (cross-family exposure = high risk), notify (ANPD 3 business days per Resolução CD/ANPD 15/2024 + affected users via the privacy address), recover + post-mortem.

**Tests** — integration +3 (`ConsentAndRetentionTests`): consent stamped with version; NULL without the metadata (no fabrication); retention purge removes only read+old notifications.

**Files**: `supabase/migrations/20260721190000_s13_consent_records_and_retention.sql`; `supabase/functions/{register-invitee,purge-deleted}/index.ts`; `Helpers/PolicyVersions.cs`; `Services/AuthService.cs`; `Models/Profile.cs`; `Pages/{Privacy,Terms}.razor`; `README.md`; `supabase/README.md`; `IntegrationTests/ConsentAndRetentionTests.cs`.

---

### F-29 — True real-time calendar push via supabase-js interop bridge (Phase 5 item 5.14)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.23) |
| **Priority** | `low` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Origin** — F-23 shipped near-live sync by **polling** because the .NET SDK's Realtime WebSocket throws `Arg_PlatformNotSupported` in Blazor WASM (verified live, July 2026). This item added true instant push through the JS client, which uses the browser's native WebSocket.

**What shipped**
- **Vendored bundle**: `wwwroot/js/vendor/supabase.js` (@supabase/supabase-js **2.110.7** UMD, ~203 KB) — self-hosted per the CSP (`script-src 'self'`; `connect-src` already allowed `wss://*.supabase.co`), lazily injected only after authentication and fingerprinted into the service-worker manifest automatically.
- **Bridge**: `wwwroot/js/realtime.js` (ES module) + `RealtimeBridgeService` (scoped). One channel, RLS-scoped `postgres_changes` bindings — **scope decision (product owner): everything the poll covers**, so nothing regresses when the poll relaxes: `care_schedules`, `swap_requests`, `profiles` (roster), `family_deletion_requests` (banner) filtered by `family_id`, plus `notifications` INSERTs filtered by `recipient_profile_id`. Events are **payload-free pokes** into the existing machinery: `FamilyDataChanged` → Home's `RefreshCalendarQuietlyAsync` (coalesced 400ms — a bulk save fires one event per row; interaction guard intact), `NotificationReceived` → instant badge (MainLayout), `ConnectionChanged` → poll retune. DELETE events arrive without the family filter (old record = PK only) — harmless extra refreshes by design.
- **Adaptive fallback (product owner decision)**: the F-23 poll stays as the safety net — **25s while the socket is down, relaxed to 120s while healthy**; refresh-on-focus unchanged. Token expiry handling: joins fail → status callback → .NET re-inits with a fresh token (single-flight, 15s backoff).
- **Dead code removed**: `NotificationService.InitRealtimeAsync` (the silently-failing .NET-SDK subscription) deleted; badge now rides the bridge.
- **Migration** `20260721210000_f29_realtime_publication.sql`: `family_deletion_requests` added to the `supabase_realtime` publication (the baseline already carried the other four tables); idempotent.
- `window.__realtimeStatus` exposed for diagnostics/E2E.
- **QA refinement (v1.5.26, phase-5 test pass, scenario 5.5):** Realtime never replays events published while the device was offline — the gap change only landed on the safety poll (up to 2 min). Catch-up added: the browser's `online` event AND the channel's (re)join to `SUBSCRIBED` each poke one coalesced quiet refresh (REST), so the missed change shows immediately; the 120s relaxed poll stays untouched. **Refinement 2 (v1.5.27):** real airplane mode showed the OS fires 'online' optimistically (radio re-attach takes seconds) — the single poke raced the dead network and failed silently. Now: staggered catch-up pokes (0s/3s/10s) + an immediate `realtime.connect()` nudge that cuts the reconnect backoff, so the SUBSCRIBED rejoin catch-up lands in seconds. (DevTools' offline toggle never reproduced this — it is a browser-level simulation; the real radio is the test that matters.)

**Tests** — no new automated suite: the WebSocket path is not reachable from the integration harness, and a two-browser live-update E2E would be flaky by nature. Safety comes from (a) the adaptive poll fallback preserving F-23 behavior exactly when the socket is absent, and (b) the existing E2E pack running the app WITH the bridge active against the real dev project — an init crash or JS error would fail those smokes. Manual QA: two devices, change a day on one, watch it land on the other within ~1s (and the badge tick instantly).

**Files**: `wwwroot/js/{realtime.js,vendor/supabase.js}`; `Services/{RealtimeBridgeService,NotificationService}.cs`; `Layout/MainLayout.razor`; `Pages/Home.razor`; `Program.cs`; `supabase/migrations/20260721210000_f29_realtime_publication.sql`; `README.md`; `CLAUDE.md`.

---

### T-33 — Systematic concurrency-conflict handling (Phase 5 item 5.15)

| Field | Value |
|---|---|
| **Status** | `completed` (v1.5.24) |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Origin** — a QA race during S-11 (v1.5.17 shipped the immediate layer: PT-BR translation of 23505 + day-sheet reload/rehydrate). This item is the SYSTEMATIC pass, ordered right after F-29 on purpose (push shrinks the stale window to ~1s).

**Mutation inventory (the record the item asked for)**

| Mutation | Concurrency failure mode | Handling |
|---|---|---|
| Day INSERT (editor/bulk/wizard) | UNIQUE(family, date) → 23505 | ✅ PT-BR + reload/rehydrate (v1.5.17) |
| Day UPDATE (editor, bulk cases 1/3) | **Was: silent last-writer-wins** | ✅ **revision guard (this item)** — loud PT-BR conflict + same recovery |
| Bulk batch (one conflicted day) | **Was: aborted the whole batch** (catch outside the loop) | ✅ per-day catch — conflicted day counted, batch proceeds, summary line "N dias não salvos: outro responsável salvou primeiro" |
| Wizard batch INSERT (`BulkUpsertAsync`) | **Was: one collision (created between existence check and INSERT) failed the whole batch** | ✅ on 23505: re-fetch existing once, drop collided, retry remainder; absorbed by the wizard's "já preenchidos foram mantidos" count |
| Day DELETE (clear planned) | Deleting a row the other member just edited (destructive, rare) | ⚠️ accepted + documented — idempotent otherwise; F-29 push shrinks the window |
| Swap create | one_pending_per_date UNIQUE | ✅ PT-BR (v1.5.17); bulk now counts it as a conflict day |
| Swap approve/reject/cancel | BEFORE UPDATE status-transition trigger | ✅ already the "good model" (fresh fetch before write) |
| Profile name/role/e-mail, family rename (RPCs, single field) | Last-writer-wins | ⚠️ accepted + documented (product decision, July 2026: guard scoped to care_schedules — the shared high-stakes surface) |

**Mechanism** — `care_schedules.revision int NOT NULL DEFAULT 0` + `trigger_c_enforce_schedule_revision` (BEFORE UPDATE, after family-stamp `a` and day-protection `b` so frozen/past errors take precedence): a client full-row UPDATE carries the revision it READ — mismatch raises the PT-BR "Outro responsável salvou este dia primeiro…" (stable substring = detection contract, `CalendarHelpers.IsStaleDayConflict`/`IsDayConflict`); match → `revision + 1` and `updated_at` stamped server-side. **Server-side column-list UPDATEs (S-11 erasure cleanup, F-24 auto-approval, swap RPCs) never mention revision → they pass and increment with no special bypass.** Client flows that fetch fresh before writing (swap approval) are naturally safe; `ShallowCopy` carries `Revision`.

**Shared conflict UX** — one recovery everywhere: the day editor reuses the v1.5.17 reload + rehydrate + explain path for BOTH races (`IsDayConflict`); bulk skips the conflicted day, reports the count and `FinishBulkSave`'s reload shows the winners; wizard collisions land in the existing "kept" count.

**Bulk decision (product owner)**: skip-and-report, never abort-all.

**Tests** — unit +1 (100 total): `IsDayConflict` covers both races, stale message passes through `TranslateSaveError`. Integration +2 (`OptimisticConcurrencyTests`): the stale UPDATE is rejected with the message and the winner's data survives (then rehydrate-and-save works); a column-list `Set()` UPDATE passes regardless of revision and increments (the RPC pattern).

**Files**: `supabase/migrations/20260721230000_t33_optimistic_revision.sql`; `Models/CareSchedule.cs`; `Helpers/CalendarHelpers.cs`; `Services/CustodyService.cs`; `Pages/Home.razor`; `Tests/CalendarHelpersTests.cs`; `IntegrationTests/OptimisticConcurrencyTests.cs`.

---

### T-32 — Negative / boundary / adversarial test exploration (Phase 5 item 5.16)

| Field | Value |
|---|---|
| **Status** | `completed` (test-only; no version bump) |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Origin** — requested at the T-30 review; ordered LAST of Phase 5 (product decision) so it probes the phase's final shape. The phase-closing pass that hunts how the app FAILS.

**What shipped** — full coverage/findings report in `backlog/t32-findings.md` (map of every Phase-5 delivery and its suite) + two batches of new scenarios, all proving the app fails safely:
- **Suite E `AdversarialTests`** (integration): forged INSERT into `family_deletion_requests`/`responses` blocked; `execute`/`respond_family_deletion` without a pending request rejected; cross-family notification INSERT blocked; replaying a resolved swap (status change) rejected; `care_schedules.revision` cannot be stamped to an unread value; leave→cancel loops keep the color slot/seat and never duplicate the profile; a frozen (pending-swap) day cannot be deleted by a regular member; 100-char notes round-trip intact.
- **`RegisterInviteeTests`**: malformed invite tokens (non-UUID, SQL-ish, path/script strings) map to the friendly "Convite inválido" (400), never a raw DB error.
- **`SwapRequestServiceLogicTests`** (unit): `ComputePriorityTag` across far-past/far-future and type-edge dates — no overflow.

**Findings** (all documented, none blocking): **T32-A1** the T-33 revision guard uses a guessable monotonic counter — optimistic, not adversarial → **T-35** (low). **T32-A2** the growing integration suite flaked under GoTrue's auth rate limit → fixed with sign-in backoff in the fixture. **T32-A3** the 100-char notes limit is UI-only (accepted). The only real defect this class of testing surfaces (the clear-day S-09 bypass) was caught manually during QA and fixed in v1.5.25.

**Files**: `backlog/t32-findings.md`; `IntegrationTests/{AdversarialTests,RegisterInviteeTests,E2EFamilyFixture}.cs`; `Tests/SwapRequestServiceLogicTests.cs`.

**Phase 5 closes here** — all roadmap items 5.1–5.16 delivered.
