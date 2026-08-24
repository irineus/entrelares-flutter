# Archive — Phase 3: Workflow Completeness & Planning (completed)

Implementation records of the items delivered in Phase 3 (v1.4.0). Immutable history — new work never goes here.

---

### F-05 — Recurring pattern / week rotation wizard

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `high` |
| **Impact** | `high` |

**Description**
Implemented a flexible **pattern builder wizard** accessible from the calendar header (🗓️ button). The user defines a repeating cycle by adding blocks of `parent × days`. Presets pre-fill common patterns (7/7, 14/14, 1/1, 5/2/2/5, 2/2/3) but are fully editable — blocks can be added, removed, or modified.

**Features delivered:**
- **Pattern builder:** dynamic list of cycle blocks (parent × days), minimum blocks = number of roles
- **Presets:** 5 common patterns as starting templates, fully editable after selection
- **Validation:** all roles must appear in the cycle; start date must be today or future; no empty blocks
- **Handoff time:** optional field applied only on transition days (when responsible parent changes)
- **Protection rules:** past days never modified; already-assigned days preserved; skipped count reported
- **Field locking:** the day-sheet editor disables the "Responsável Agendado" field when a day already has an assigned parent, with a hint directing to the wizard or swap workflow
- **Bulk insert:** `CustodyService.BulkUpsertAsync` fetches existing schedules in one query, inserts in batches of 10, supports optional progress callback
- **Progress feedback:** indeterminate progress bar + "Salvando..." message during generation

**Justification**
This directly addresses the app's primary use case. Setting up a predictable rotation manually is tedious and error-prone. Automating it transforms the app from a logging tool into a planning tool.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — wizard trigger button in calendar header, locked scheduled-parent field
- `SharedParentalCustody/Pages/Components/ScheduleWizard.razor` — pattern builder wizard component
- `SharedParentalCustody/Services/CustodyService.cs` — `BulkUpsertAsync` with past-day filtering and batch insert
- `SharedParentalCustody/wwwroot/css/shared.css` — wizard block styles

---

### F-11 — Integrate bulk edit with the swap approval workflow

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `high` |
| **Impact** | `high` |

**Description**
`SaveBulkChanges` previously *blocked* the entire bulk operation whenever any selected future day would require a swap request, and — for brand-new days without an existing schedule — it silently wrote `actual_parent_id` directly, bypassing the approval workflow. Both behaviours were replaced with per-day routing that mirrors the single-day editor (`SaveChanges`).

Each eligible day is now classified and handled independently:
- **Swap request** — a future day whose actual-parent change would need approval (`ShouldTriggerWorkflow`) writes only the base schedule (scheduled parent + notes) and defers the actual-parent change to a `pending` swap request via `CreateSwapRequestAsync`. This now also covers brand-new days, closing the previous bypass.
- **Revert request** — clearing or resetting the actual parent on a day that has an already-approved swap (`ShouldRequestRevert`) creates a `revert_pending` request via `RequestRevertAsync` instead of directly clearing it.
- **Direct update** — any non-workflow change (scheduled parent, notes, handoff time, or an actual value that matches the current one) is applied directly with `UpsertScheduleAsync`.
- **Skipped** — past days (F-13), frozen `pending`/`revert_pending` days, and clearing the scheduled parent on an approved-swap day (F-12) are excluded and counted.

While the batch runs, the global progress bar shows a determinate counter (`ToastService.UpdateProgress`), e.g. *"Salvando 2/3..."* (or *"Apagando 2/3..."* on the delete path), reusing the same `MainLayout` progress UI as the rotation wizard. On completion a summary toast reports the outcome, e.g. *"3 dias atualizados · 2 solicitações de troca · 1 dia ignorado"*, using `BuildBulkSummary`/`Pluralize` helpers that omit zero-count parts. Because each day is routed to exactly one path, bulk edit can no longer leave the calendar in a state where some days bypass workflow protections.

**Justification**
Bulk edit is a power feature, but it previously clashed with one of the app's most important control mechanisms: two-party approval of future swaps. Both features now work together without creating loopholes or ambiguous outcomes.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — `SaveBulkChanges` rewritten with per-day swap/revert/direct/skip routing; `FinishBulkSave` now takes a summary string; new `BuildBulkSummary`/`Pluralize` helpers. Reuses the existing `SwapRequestService.ShouldTriggerWorkflow`, `ShouldRequestRevert`, `CreateSwapRequestAsync`, and `RequestRevertAsync` (no new service methods needed — the single-day workflow already provided them) and `CustodyService.UpsertScheduleAsync`/`GetScheduleForDateAsync`.

---

### F-14 — Add admin authorization and privileged override rules

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `high` |
| **Impact** | `high` |

**Description**
Introduce an `admin` authorization level with the ability to perform a limited set of privileged override operations that normal users cannot do. This role is intended for exceptional maintenance or support actions, not for the normal parental workflow.

The app should model admin as a **privileged user flag within a family context**, not merely as an incidental UI mode. Each family must have at least one admin so there is always an explicit override path when needed.

Admin-only capabilities should include:
- clearing or changing past days;
- changing the scheduled parent directly;
- overriding workflow-protected constraints when a support/manual correction scenario requires it.
- clearing a day that has an approved swap (currently blocked for all users by F-12).

**Deferred from F-12 (Phase 1.4):** The "Limpar dia" (clear day) button is currently hidden for days with an approved swap. When admin authorization is implemented, admins should be able to override this restriction and clear approved-swap days with an auditable action.

Requirements:
- Admin actions must be explicit in the UI and clearly separated from the normal parent flow.
- Admin overrides should remain auditable so that reports and history still explain what happened.
- The audit/history log must remain immutable even for admins; admin powers may change calendar state, but must never erase or rewrite historical evidence of those changes.
- Family-level rules must enforce that at least one admin exists for each family.
- Authorization checks must live in both UI and service layers; the UI alone is not sufficient protection.

**Justification**
Some restrictions should exist for normal users but still need an emergency/support override path. A dedicated admin authorization level is safer and clearer than leaving backdoors in the standard editing workflow.

**Implemented (delivered with S-06 in migration V008 — see that entry for the DB details)**
- `profiles.is_admin` (flag within a family), backfilled to the project owner; DB triggers keep the invariant "every family has ≥ 1 admin" and block self-promotion.
- **Enforcement lives in the database**, not just the UI: the `enforce_day_protection` trigger moves the F-12/F-13 day rules server-side with an **admin bypass** — admins may edit/clear past days, delete an approved-swap day, and unlock the scheduled parent. It also closes the S-05 leftover: changing the actual parent outside the approval workflow is now blocked **for everyone, admins included** (only the pending request's target applying an approval, or `service_role`/F-24, may). The one admin exception is correcting the actual parent of **past** days (historical fixes, where a workflow cannot exist).
- **Explicit, separated UI (decision):** an `AdminModeService` toggle (`🛡️ Admin` in the nav, shown only to admins) with a **persistent amber banner**; only while active does `Home` relax the single-day-editor guards. Admin mode auto-resets on logout (and the whole DI scope is recreated via a forceLoad on login/logout, so admin state never leaks across accounts).
- Audit log stays immutable and now also records `family_id`.

**Deferred:** in-app admin management (promote/demote) — **delivered with F-15** (Família page + `set_member_admin` RPC); direct future-swap correction was intentionally **not** granted (Q3 decision — the approval workflow is always used for future days).

**Files affected**
- `database/migrations/V008__families_and_admin.pgsql` — `is_admin`, admin-bypass day-protection trigger, profile-protection trigger (see S-06)
- `SharedParentalCustody/Models/Profile.cs` — `IsAdmin`
- `SharedParentalCustody/Services/AdminModeService.cs` — new; `Program.cs` registration
- `SharedParentalCustody/Layout/NavMenu.razor` — admin toggle (admins only)
- `SharedParentalCustody/Layout/MainLayout.razor` (+ `.razor.css`) — persistent admin banner + calendar-height compensation
- `SharedParentalCustody/Pages/Home.razor` (+ `.razor.css`) — `IsAdminBypass` relaxes the editor guards

---

### F-15 — User registration / self-service sign-up flow

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Description**
There was no sign-up page or self-service registration flow — new parents could only be onboarded by manually creating their account in the Supabase dashboard and inserting a profile row. Implemented the full family-invitation model: the first parent (founder) creates the family and invites the co-parent via an e-mail link.

**Implemented behaviour**
- **Founder flow** (`/register`): full name, **family name** (chosen by the founder; renameable later), e-mail, password (8+ with confirmation) and role picked from large tap buttons. Creates the Supabase Auth account with the data as user metadata; the **`handle_new_user` trigger on `auth.users`** (SECURITY DEFINER, V009) creates family + profile **atomically** in the same transaction — founder becomes the family's **admin** (F-14 alignment). No "account without profile" state can exist; a trigger failure rolls back the auth user too.
- **Invitee flow** (`/register?invite=<token>`): the founder invites the co-parent from the **Família page**; the invite (uuid token, 7-day expiry, single-use) is e-mailed via the new `invitation` type in `send-swap-email`, with a **copyable link fallback** (WhatsApp). The invited register page pre-fills/locks the e-mail and role (resolved pre-auth via the anon-callable `get_invite_info` RPC); the trigger joins the profile to the inviter's family (max 2 members, e-mail must match the invitation).
- **E-mail confirmation is mandatory** (Supabase "Confirm email" ON — e-mail is the workflow notification channel): post-sign-up screen "Confirme seu e-mail"; login blocked until confirmed. PT-BR confirmation template + deliverability guidance documented in `supabase/README.md` §4.
- **Família page** (`/family`, new nav tab for everyone): members with role + admin badge, **in-app admin promote/demote** (`set_member_admin` RPC — closes the F-14 deferred item; V008 trigger still enforces every invariant), invitation management (send/resend/revoke, status, copy link), **family rename** (✏️, admin-only via `rename_family` RPC), and the **admin-mode toggle** (its new mobile home — a 7th nav tab would not fit at 344 px, so the mobile nav admin button was replaced by the Família tab).
- **Hardening**: `profiles_own_insert` policy dropped (profiles are born only from the trigger); all writes to `families` / `family_invitations` / other-profiles go through SECURITY DEFINER RPCs with admin checks; nav chrome hidden for anonymous visitors.

**Issues found & fixed during testing**
- gotrue-csharp's `SignUp` fires a `SignedOut` event before the API call → the F-19 expiry handler force-loaded to /login mid-sign-up (aborting it). Fixed with an `_isSigningUp` suppression flag (same pattern as `_isRestoring`).
- Role seed data is environment-inconsistent (`Pai`/`Mãe` in dev vs `father`/`mother` documented in V001) → tolerant alias matching in the trigger + client-side `RoleCatalog` (see F-27 prep).
- Hand-seeded identity sequences (profiles/families/roles) were stale → first sign-up hit `duplicate key profiles_pkey`; V009 resyncs them with `setval(max(id)+1)` (prod needs this too).
- Invitation e-mail landed in spam → deliverability section (SPF/DKIM/DMARC via Resend, public `APP_URL`, custom SMTP) added to the runbook (§4.6).

**Files affected**
- `database/migrations/V009__signup_and_invitations.pgsql` — `family_invitations`, `handle_new_user` trigger, RPCs (`get_invite_info`, `create_invitation`, `revoke_invitation`, `rename_family`, `set_member_admin`), sequence resync, hardening
- `SharedParentalCustody/Pages/Register.razor` (+`.css`) — founder/invitee sign-up; `Login.razor` — "Criar conta" link
- `SharedParentalCustody/Pages/FamilyPage.razor` (+`.css`) — members, admin toggle, invitations, rename
- `SharedParentalCustody/Services/AuthService.cs` — `SignUpAsync` (+`_isSigningUp`), sign-up error translations
- `SharedParentalCustody/Services/FamilyService.cs` — new; `RoleCatalog.cs` — new (F-27 prep); `ProfileService.cs` — `TranslateRole` via catalog
- `SharedParentalCustody/Layout/NavMenu.razor` — Família tab, chrome hidden when anonymous; `MainLayout.razor` — `/register` public route
- `supabase/functions/send-swap-email/index.ts` — `invitation` e-mail type (**requires redeploy**)
- `supabase/README.md` — runbook §4: Authentication settings, PT-BR template, SMTP/deliverability

---

### F-20 — Dynamic urgency/overdue tag on pending swap requests

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Description**
The static `is_urgent` boolean was a snapshot frozen at creation time — a request created 3 days ahead could never *become* urgent (or overdue) as the handoff approached. Replaced by a fully **computed** priority tag that evolves over time.

**Implemented design — ZERO columns (simpler than originally planned)**
The original plan stored a `resolved_priority_tag` at resolution to freeze history. During analysis it turned out that value is **fully derivable**: the tag at resolution time is `f(resolved_at, handoff)`, and both `resolved_at` and `proposed_handoff_time` already live on `swap_requests`. So V010 only **drops `is_urgent`** and adds nothing — no derived state stored anywhere:

```
reference = resolved_at ?? now          (pending → clock; resolved → historical fact)
handoff   = schedule_date + (proposed_handoff_time ?? 00:00)      ← F-22 formula

reference <  handoff − 24h  →  (no tag)
reference <  handoff        →  urgent   ⚠️ URGENTE
reference >= handoff        →  overdue  ⏰ ATRASADO
```

- `SwapRequestService.ComputePriorityTag(request)` + `PriorityTag` enum (`None`/`Urgent`/`Overdue`, extensible) is the single formula for pending AND history.
- **UI**: Notifications cards get amber (urgent) / red (overdue) border+banner — live for pending, frozen at `resolved_at` as a header badge for resolved (F-24 auto-approved requests correctly show ⏰ ATRASADO); frozen-day panel gets the ⏰ icon and a red banner variant; the **calendar** 🔔 (approver) gains a red glow + faster shake when the handoff has passed — a nudge to act before the F-24 auto-approval.
- **In-app notification titles** keep the prefix computed at creation (point-in-time messages; now `⏰ ATRASADO:` is possible too — decision recorded).
- **E-mails**: the client no longer sends `isUrgent`; `send-swap-email` computes the tag at **send time in `America/Sao_Paulo`** (the runtime is UTC — the F-22 consistency point). Subjects get `[URGENTE]`/`[ATRASADO]`; the request/revert templates get the matching banner; the F-24 reminder (fired 24 h after the handoff) now naturally goes out as `[ATRASADO]`.
- Urgency history from the boolean era was intentionally discarded (decision: app not public yet; calendar data untouched).

**Files affected**
- `database/migrations/V010__drop_is_urgent.pgsql` — drop `is_urgent`; nothing added
- `SharedParentalCustody/Models/SwapRequest.cs` — `IsUrgent` removed
- `SharedParentalCustody/Services/SwapRequestService.cs` — `PriorityTag` enum, `ComputePriorityTag`, `PriorityTagPrefix`; `IsUrgentRequest` removed; e-mail dispatch no longer sends urgency
- `SharedParentalCustody/Pages/Notifications.razor` (+`.css`) — dynamic banners/badges, overdue styles
- `SharedParentalCustody/Pages/Components/FrozenDayPanel.razor` (+`.css`) — ⏰ icon + overdue banner
- `SharedParentalCustody/Pages/Home.razor` (+`.css`) — overdue glow on the approver's 🔔
- `supabase/functions/send-swap-email/index.ts` — send-time computation (**requires redeploy together with V010**)

---

### F-22 — Refine urgency calculation to use handoff time precisely

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
Validation checkpoint delivered together with F-20 — the formula is now defined in exactly one place per runtime and is consistent across every usage point:
- `handoffDateTime = schedule_date + (proposed_handoff_time ?? 00:00)` — when no handoff time is set, 00:00 of the schedule day is the reference point.
- **Client** (`SwapRequestService.ComputePriorityTag`): used by the Notifications cards, the frozen-day panel, the calendar badge and the creation-time notification-title prefix. Resolved requests are measured against `resolved_at` (converted to local time) — the "resolution-time freeze" needs no stored column.
- **Edge Function** (`computePriorityTag` in `send-swap-email`): identical thresholds, evaluated at send time in **`America/Sao_Paulo`** (the Deno runtime is UTC — this was the main consistency risk this item existed to catch).
- Future refinement noted: a user-configurable default handoff time may replace the 00:00 fallback.

**Files affected**
- `SharedParentalCustody/Services/SwapRequestService.cs` — `ComputePriorityTag` (single client-side formula)
- `supabase/functions/send-swap-email/index.ts` — mirrored formula with explicit São Paulo timezone

---

### F-24 — Auto-approve expired swap/revert requests after 48h with 24h reminder

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `high` |
| **Impact** | `high` |

**Description**
Prevent swap and revert requests from remaining open indefinitely. When a pending request (`pending` or `revert_pending`) has been expired for more than 48 hours, the system automatically approves it. A reminder notification and email are sent to the approver 24 hours after expiry (i.e., 24 hours before auto-approval).

**Definitions:**
- **Expiry point** = `schedule_date + (proposed_handoff_time ?? 00:00)` — the moment the handoff should have occurred.
- **Reminder trigger** = expiry + 24h — nudge notification to the approver.
- **Auto-approve trigger** = expiry + 48h — system approves the request automatically.

**Behaviour:**
- Applies to both `pending` (swap) and `revert_pending` (revert) requests.
- Urgent requests (created <24h before handoff) follow the same rules — no special treatment.
- The approver can still manually approve or reject at any point before the auto-approve fires.
- Auto-approved requests must be distinguishable from manual approvals in the audit trail (e.g., `resolved_by = 'system'` or a dedicated status `auto_approved` / `revert_auto_approved`).
- The 24h reminder notification should clearly state the deadline: "Você tem 24h para responder à solicitação de troca do dia DD/MM, ou ela será aprovada automaticamente."
- The reminder email should follow the same urgency formatting as other workflow emails.

**Architecture — Supabase Edge Function Cron:**
- A new Edge Function (`auto-approve-expired`) runs on a schedule (e.g., every hour via `pg_cron` or Supabase's cron trigger).
- On each run, the function:
  1. Queries `swap_requests` where status IN (`pending`, `revert_pending`) AND `schedule_date + proposed_handoff_time + interval '48 hours' < now()` → auto-approve these.
  2. Queries `swap_requests` where status IN (`pending`, `revert_pending`) AND `schedule_date + proposed_handoff_time + interval '24 hours' < now()` AND no reminder has been sent yet → send reminder notification + email.
- Auto-approval applies the same calendar changes as a normal approval (update `care_schedules.actual_parent_id` for swaps, or restore original for reverts).
- A `reminder_sent_at` timestamp column on `swap_requests` prevents duplicate reminders.
- A `resolved_by` column (`'user'` or `'system'`) records who approved the request.

**Notification content:**
- **24h reminder (in-app):** "[Dev] ⏰ Solicitação pendente expira em 24h" / "A solicitação de troca do dia DD/MM será aprovada automaticamente em 24h se não houver resposta."
- **24h reminder (email):** Subject includes `[Auto-aprovação em 24h]`; body explains the deadline and includes approve/reject action context.
- **Auto-approved (in-app to requester):** "[Dev] ✅ Troca aprovada automaticamente" / "A solicitação de troca do dia DD/MM foi aprovada automaticamente após 48h sem resposta."
- **Auto-approved (in-app to approver):** "[Dev] ✅ Troca aprovada automaticamente" / "A solicitação de troca do dia DD/MM foi aprovada automaticamente. Você não respondeu dentro do prazo."

**Database changes:**
- `swap_requests` table: add `reminder_sent_at timestamptz NULL` column and `resolved_by text NOT NULL DEFAULT 'user'` column.
- New status values or a flag to distinguish auto-approval in history views.
- Extend the `BEFORE UPDATE` trigger to allow `service_role` to perform the status transition (the Edge Function runs with `service_role` credentials).

**Design decisions (resolved during implementation)**
- **Execution: Postgres RPC + scheduled Edge Function.** The DB work (find expired, transition, apply the calendar change — including the F-26 revert restore in SQL — and insert notifications) lives in the `auto_approve_expired()` RPC and returns the e-mails to send; the scheduled `auto-approve-expired` Edge Function calls the RPC and dispatches e-mails by reusing `send-swap-email`. Keeps mutations atomic in SQL with no TypeScript duplication of the restore.
- **Marking: `resolved_by` column** (`'user'` | `'system'`) instead of new statuses — reuses `approved` / `revert_approved`, so no C# status-matching logic changed; only a `🤖 Automático` badge reads `resolved_by`.
- **Scope:** both swaps and reverts.
- **Timezone:** handoff times treated as `America/Sao_Paulo` (matches the client urgency calc). Revisit for multi-timezone families.
- **Trigger:** `enforce_swap_status_transition` extended with a system-context branch (`auth.uid()` null → service_role) that allows only `pending→approved` / `revert_pending→revert_approved`.
- **Deferred:** the frozen-panel auto-approve countdown → final-polish item.

**Testing in dev without waiting 48 h** (moved here from the deploy runbook — not a deploy step):
- Create a swap/revert request for **today** with a handoff time already in the past (the app only blocks *past days*; today is allowed).
- Temporarily lower the thresholds: re-run the `auto_approve_expired` function from `V007__auto_approve.pgsql` with `interval '1 hour'` / `'2 hours'` in place of `24`/`48` (a plain `CREATE OR REPLACE`), then **restore the V007 version afterward** so dev matches prod.
- Fastest check of the DB logic: `select * from public.auto_approve_expired('[Dev] ');` (does the status/notification work but **does not send e-mail** — only the Edge Function does). To test the e-mail path, invoke the function itself with the `Authorization: Bearer <service_role_key>` header (as in the runbook's cron command).

**Files affected**
- `database/migrations/V007__auto_approve.pgsql` — `reminder_sent_at` + `resolved_by` columns, trigger system-branch, `restore_pre_edit_state()` (SQL twin of F-26), `auto_approve_expired()` RPC
- `supabase/functions/auto-approve-expired/index.ts` — new scheduled Edge Function
- `supabase/functions/send-swap-email/index.ts` — new `reminder` / `auto_approved` e-mail types + templates
- `supabase/README.md` — Supabase deploy runbook (functions deploy, **cron scheduling incl. the auth-header gotcha**)
- `SharedParentalCustody/Models/SwapRequest.cs` — `ReminderSentAt`, `ResolvedBy`
- `SharedParentalCustody/Pages/Notifications.razor` (+ `.razor.css`) — `🤖 Automático` badge + new notification icons
- Requires (per environment, manual): apply V007, deploy both Edge Functions, schedule the cron. See `supabase/README.md`.

---

### F-25 — Bulk actions on frozen days (approve / reject / cancel / revert requests)

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `high` |
| **Impact** | `high` |

**Description**
Extended the long-press multi-selection flow so the swap/revert workflow can be resolved in bulk, not just one day at a time through the `FrozenDayPanel`. Frozen days (`pending` / `revert_pending`) can be *selected* but are silently skipped by `SaveBulkChanges` (F-11); previously the only way to act on them was tapping a single day to open the frozen panel. This adds a **second, context-aware action surface** for a multi-day selection.

**How it works:** when the current selection contains any actionable request, the selection action bar shows an amber `🔔 Resolver (N)` button (N = total actionable days). Tapping it opens a dedicated **bulk workflow bottom sheet** that mirrors the bulk-edit sheet and lists one section per available action, each scoped to its eligible subset and showing the count. A selection is typically **mixed** (some days awaiting my decision as approver, some I sent as requester, some with an approved swap, some plain editable/past days), so a section appears only when at least one selected day is eligible for it and each action operates only on that subset.

**Actions in scope (all three delivered):**
- **Approve / Reject (I am the approver).** Bulk-resolve `pending` swap and `revert_pending` requests where `TargetProfileId == me`. Reject uses a single shared optional reason applied to all. Iterates `SwapRequestService.ApproveAsync` / `RejectAsync` / `ApproveRevertAsync` / `RejectRevertAsync` per request, branching on `Status`.
- **Cancel the ones I sent.** Bulk-cancel `pending` / `revert_pending` requests created by the current user (`RequestingProfileId == me`). Iterates `CancelAsync` / `CancelRevertAsync`.
- **Request revert in bulk.** For selected future days that already have an **approved** swap (`actual_parent_id != scheduled_parent_id`) and are not themselves frozen, create `revert_pending` requests. Iterates `RequestRevertAsync` (the same path the single-day editor uses via `ShouldRequestRevert`).

**Behaviour & rules:**
- The three eligible subsets are **disjoint** (a frozen request has requester ≠ target, so a day is either "for me" or "sent by me"; revertable days are by definition *not* frozen), so nothing is double-counted.
- A result summary reports the outcome in the F-11 style, e.g. *"3 aprovadas · 1 ignorada"*, and a determinate progress counter (*"Processando 2/5..."*) is shown while the batch runs, reusing the `ToastService` progress UI (rendered by `MainLayout`).
- Swap vs revert requests are handled by their matching service methods, branching on `Status == "revert_pending"`.
- All authorization is still enforced at the DB level by the S-05 `BEFORE UPDATE` state-machine trigger — each item is an individual validated update, so a partial failure (e.g. a request already resolved by the other parent in the meantime) is caught, counted as *ignorada*, and the batch continues rather than aborting.
- After completion the selection is cleared, the sheet closes, and `monthlySchedules` / `frozenRequests`, the today card, and the notification badge (`NotificationService.RequestBadgeRefresh`) are refreshed.

**Design decisions (resolved):**
- **One entry point, one sheet.** Rather than crowding the fixed 62px action bar with up to four workflow buttons, a single `🔔 Resolver (N)` button opens a sectioned sheet. Keeps the bar mobile-friendly and self-documenting.
- **Field-editing and workflow are both offered.** For a mixed selection, `✏️ Editar (N)` (bulk-edit, which skips frozen days per F-11) and `🔔 Resolver (N)` coexist on the bar; the user picks the surface they want.
- **Counts live on the buttons.** The old free-text "N dias selecionados" label was dropped in favour of putting the count on each button — `🔔 Resolver (N)` (actionable frozen days) and `✏️ Editar (N)` (all selected days) — with a compact icon-only `✕` for dismiss. The action bar stays a single 62px row (never covering the last calendar row) and fits down to a 344px viewport.
- **Sheet buttons are solid.** The workflow sheet uses solid, bordered buttons (`.btn-wf-approve` / `.btn-wf-secondary` / `.btn-wf-revert`) so they stay clearly legible — including while disabled during the batch — instead of the transparent text-link look; the spinner appears on the specific action clicked.
- **Reused patterns:** the per-item loop, `Pluralize`, and the progress/summary UX come straight from F-11; the reject-reason input mirrors `FrozenDayPanel`; no new service methods were needed.

**Justification**
The workflow is the app's core integrity mechanism, but resolving requests one day at a time is tedious when a co-parent proposes a whole block of swaps (e.g. a vacation week generated by the wizard). Bulk approve/reject/cancel/revert brings the multi-day ergonomics of F-04/F-11 to the approval workflow, which is where high day-counts actually occur.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — `SelectedPendingForMe` / `SelectedSentByMe` / `SelectedRevertable` classification props + `WorkflowActionableCount`; `🔔 Resolver (N)` action-bar button and counts-on-buttons redesign (`✏️ Editar (N)`, icon-only `✕`); bulk workflow bottom sheet; `OpenBulkWorkflowSheet` / `CloseBulkWorkflowSheet`; `BulkApprovePending` / `BulkRejectPending` / `BulkCancelSent` / `BulkRequestRevert`; generic `RunBulkWorkflowAsync<T>` runner (progress + summary + partial-failure handling, with the spinner tracked per action via `activeWorkflowAction`); `CancelSelection` also closes the sheet. Reuses the existing single-item `SwapRequestService` methods and F-11's `Pluralize`.
- `SharedParentalCustody/Pages/Home.razor.css` — `.btn-bulk-workflow` (amber accent), `.workflow-section` / `.workflow-section-title`, the solid `.btn-wf-approve` / `.btn-wf-secondary` / `.btn-wf-revert` button styles, and the single-row responsive `.selection-action-bar`
- Depends on: F-10 (workflow), F-11 (bulk routing + summary/progress patterns)

---

### F-26 — Revert must restore the full pre-swap state (actual parent, handoff time, notes)

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `high` |
| **Impact** | `high` |

**Description**
Approving a revert previously did **not** faithfully restore the day to how it was before the swap. `SwapRequestService.ApproveRevertAsync` only set `care_schedules.actual_parent_id = null` (back to the scheduled parent); it did **not** restore the `handoff_time` or `notes` that existed before the swap. So if the swap changed/cleared the handoff time and/or edited the notes, reverting left those changed values in place — the calendar was only partially restored. Now the revert restores the **full pre-edit snapshot** from the audit log.

**Root cause**
- `swap_requests` stores `previous_actual_parent_id` but no previous `handoff_time` / `notes`, so those pre-swap values are never captured anywhere.
- `ApproveAsync` (swap approval) overwrites `handoff_time` with `proposed_handoff_time` without snapshotting the old value; `ApproveRevertAsync` only resets `actual_parent_id`.
- Notes are applied **immediately** during the edit (not deferred through the workflow), so by swap-approval time the schedule already holds the *new* note.

**Expected behaviour**
Reverting an approved swap restores the day to exactly how it was **before the edit that started the swap** — actual parent, handoff time, notes, and any other schedule field — and stays auditable.

**Chosen approach — restore from the audit log (no per-field columns)**
Rather than adding a `previous_*` column for every field (which does not scale — every new schedule field would need another column), reuse the **existing immutable audit log**, which already snapshots the whole row:
- The `trigger_audit_care_schedule` trigger writes `activity_logs.old_data` / `new_data` as **full-row JSONB snapshots** (`scheduled_parent_id`, `actual_parent_id`, `handoff_time`, `notes`, and automatically any field added later). `affected_date` allows lookup by day. `AuditService` already parses these snapshots.
- **Snapshot point:** the state to restore is the `old_data` of the **first** `care_schedules` update in the edit that initiated the swap (the request-creation upsert) — *not* the swap-approval update. This matters because notes are applied immediately, so only the request-creation entry's `old_data` still holds the original note. Its `old_data` is the complete pre-edit tuple `{ scheduled, actual, handoff, notes }`.
- **Reference:** capture a **single, generic pointer** to that log entry on the swap request when the workflow begins — e.g. `pre_edit_log_id bigint NULL` on `swap_requests`, read right after the request-creation upsert in `CreateSwapRequestAsync`. This is one column that never grows per-field. (A zero-column variant is possible — pure correlation by `affected_date` + newest `created_at` before `resolved_at` — but it is less reliable when a day has multiple edits, so a single stored reference is recommended.)

**Implementation**
1. **Migration `V006__revert_snapshot.pgsql`** adds `pre_edit_log_id bigint` to `swap_requests` (FK → `activity_logs(id) ON DELETE SET NULL`) — one generic reference, not one column per field.
2. **Capture** (`CreateSwapRequestAsync`): the base schedule is upserted by the caller *before* this runs, so the newest `activity_logs` row for the date holds the pre-edit `old_data`. Its id is stored as `pre_edit_log_id` (`GetLatestLogIdForDateAsync`, ordered by the monotonic `id`).
3. **Carry** (`RequestRevertAsync`): copies `pre_edit_log_id` from the approved swap onto the revert request.
4. **Restore** (`ApproveRevertAsync` → `RestorePreEditStateAsync`): reads the referenced log's `old_data` and writes `scheduled_parent_id`, `actual_parent_id`, `handoff_time`, `notes` back to `care_schedules`. If `old_data` is `null` (the edit INSERTed a brand-new day), the day is **deleted** (restored to non-existence; the `swap_requests` / `activity_logs` history survives via `ON DELETE SET NULL`). If `pre_edit_log_id` is absent (swaps approved before F-26), it falls back to the old behaviour (clear the actual parent). The restore is itself a normal update, so it is re-logged automatically.

**Design decisions (resolved during implementation)**
- **Full snapshot semantics** (chosen): a revert restores the *entire* pre-edit row — including `scheduled_parent_id` — and wipes any change made to the day after the swap was approved; a day created by the edit is removed. "Undo the whole edit", not just the actual-parent field.
- **Single generic column** `pre_edit_log_id` (chosen) over pure `affected_date`/`created_at` correlation, for reliability when a day has multiple edits.
- **Client-side restore** (chosen) in `SwapRequestService`, consistent with the rest of the client-side workflow (same trust model as the open `care_schedules` RLS — see S-06). A server-side RPC would be more robust and is a natural future pairing with S-06 / F-14.

**Known minor edge (display only):** for *chained* swaps, the frozen-panel "revert to" label shows the scheduled parent while the restore correctly returns the state immediately before the edit; the stored data is correct, only the label can differ.

**Justification**
A revert that only half-restores the day undermines trust in the workflow. The log-based approach is also **more scalable** than per-field `previous_*` columns: the JSON snapshot already captures the whole row (and any future field) with a single generic reference. Discovered during F-25 testing: a bulk edit that changed the actual parent, cleared the handoff time, and added a note was approved correctly, but the subsequent approved revert left the handoff cleared and the note in place.

**Files affected**
- `database/migrations/V006__revert_snapshot.pgsql` — adds the `pre_edit_log_id` column (+ self-registers in `schema_migrations`)
- `SharedParentalCustody/Models/SwapRequest.cs` — `PreEditLogId`
- `SharedParentalCustody/Services/SwapRequestService.cs` — capture in `CreateSwapRequestAsync`, carry in `RequestRevertAsync`, `RestorePreEditStateAsync` + `GetLatestLogIdForDateAsync` + local `old_data` JSON parsers in `ApproveRevertAsync`
- Depends on: F-10 (workflow); relates to S-06 (a server-side restore would be more robust)

---

### T-06 — Add `ProfileService` cache expiry

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `low` |

**Description**
`ProfileService` cached roles and profiles for the entire browser session with no automatic expiry. Implemented a `_cachedAt` timestamp with a **5-minute TTL** (decision recorded during 3.9): `GetAllRolesAsync` / `GetAllProfilesAsync` refetch when the cache is stale; `InvalidateCache()` remains for immediate invalidation after local mutations (the Família page's admin toggle already uses it).

**Justification**
F-15 made this real rather than theoretical: profiles now change mid-session (co-parent accepts an invitation, admin promoted by the other user) and the founder would not see the new member without a reload. F-16 (profile editing) would have widened the gap. Cost: one extra query per 5 minutes — negligible.

**Files affected**
- `SharedParentalCustody/Services/ProfileService.cs` — `_cachedAt` + `CacheTtl` (5 min), checked in `GetAllRolesAsync` / `GetAllProfilesAsync`; `InvalidateCache()` resets the stamp

---

### T-14 — Add retry/backoff strategy for Supabase API calls

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Description**
All Supabase API calls in the service layer were fire-and-forget: a transient error (network blip on mobile, timeout, 429, 502/503) surfaced immediately as a user-visible failure. Implemented `RetryHelper` — max **3 attempts**, exponential backoff ×3 with ±20% jitter (~400 ms → ~1.2 s; worst case adds ~1.6 s before giving up) — and wrapped **every PostgREST/RPC call** in the service layer (decision during 3.9: reads too, not writes only — a calendar that loads empty because of a blip is as bad as a lost save). Retries are silent; the existing error messages appear only after the final attempt fails.

**Design decisions (resolved during implementation)**
- **Transient-only classification**: retries on `HttpRequestException`, timeout (`TaskCanceledException`/`TimeoutException`) and PostgREST 408/429/5xx. Business errors — RLS denials, trigger violations ("dia congelado"), unique violations, other 4xx — are **never** retried (they would just repeat the refusal and delay feedback).
- **Per-call wrapping, never composite methods**: workflow methods (e.g. `ApproveAsync` = 4 sequential calls) retry each Supabase call individually; retrying the whole method after a mid-flight failure would repeat steps that already committed. The query is built inside the lambda so each attempt issues a fresh request.
- **Retried Inserts are constraint-protected**: `UNIQUE (family_id, schedule_date)` and the one-pending-per-date index make a duplicate insert fail loudly instead of corrupting; `create_invitation` auto-revokes the previous pending invite, so a retry still ends with a single valid invitation.
- **Deliberately outside the retry**: `Functions.Invoke` (e-mail is best-effort; a retry could double-send), `AuthService` (would interact badly with the S-01 login throttling and GoTrue rate limits), and Realtime (already best-effort).

**Justification**
Mobile users frequently experience transient connectivity issues. A custody save that fails because of a momentary network blip erodes trust in the app; with T-14 the app absorbs blips of up to ~1.6 s invisibly.

**Files affected**
- `SharedParentalCustody/Services/RetryHelper.cs` — new: retry wrapper + transient-error classification
- `SharedParentalCustody/Services/CustodyService.cs`, `SwapRequestService.cs`, `NotificationService.cs`, `ProfileService.cs`, `AuditService.cs`, `FamilyService.cs` — all 35 PostgREST/RPC call sites wrapped individually

---

### T-26 — Decompose Home.razor into TodayCard and FrozenDayPanel child components

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `high` |
| **Impact** | `medium` |

**Description**
`Home.razor` remains at ~1,500 lines after the CalendarHelpers extraction (T-24). Two self-contained UI sections can be extracted into child Razor components to reduce cognitive load and enable independent styling:

- **`Components/TodayCard.razor`** — the today-status card (~60 lines markup). Receives computed state as parameters: `UserName`, `CardAccent`, `IsViewingCurrentMonth`, `WhoName`, `WhoRole`, `AvatarLetter`, `IsSwapped`, `SwapTimeDisplay`, `NextHandoffDate`, `HasSchedule`. Emits `OnGoToToday` EventCallback.
- **`Components/FrozenDayPanel.razor`** — the frozen-day bottom sheet (~110 lines markup + approve/reject/cancel buttons). Receives `SwapRequest`, `IsRevert`, `IsTarget` (whether current user is the approver), `TargetProfileName`. Emits `OnApprove`, `OnReject`, `OnCancel`, `OnApproveRevert`, `OnRejectRevert`, `OnCancelRevert` EventCallbacks.

**Why deferred from Phase 2.8:**
Both sections are deeply coupled to page state — the TodayCard relies on 10+ computed variables that depend on `currentDaySchedule`, `allProfiles`, `userProfile`, and `nextHandoffDate`; the FrozenDayPanel has 6 action handlers that modify shared state (`frozenDayRequest`), call services, trigger toast messages, and refresh the calendar. Extracting them safely requires:
1. Stable interfaces — the parameters/events won't need to change soon.
2. Feature context — Phase 3 features (F-05 wizard, F-11 bulk+workflow) will restructure how these sections interact with state, making it the natural moment to extract.

**Recommended timing:** Before F-05 (rotation wizard), since the wizard adds a new entry point to the calendar header and changes how the today card relates to schedule generation. Extracting first gives F-05 a cleaner component to work with.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — extract markup sections, pass computed state via parameters
- `SharedParentalCustody/Pages/Components/TodayCard.razor` — new component
- `SharedParentalCustody/Pages/Components/TodayCard.razor.css` — extracted today card styles from `Home.razor.css`
- `SharedParentalCustody/Pages/Components/FrozenDayPanel.razor` — new component
- `SharedParentalCustody/Pages/Components/FrozenDayPanel.razor.css` — extracted frozen panel styles from `Home.razor.css`

---

### T-28 — Code hygiene sweep (end of Phase 3)

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `low` |
| **Complexity** | `low` |
| **Impact** | `low` |

**Description**
A collection of low-risk housekeeping items accumulated during Phase 3, executed as a single sweep at the end of the phase once the feature work had stabilized.

**Executed (planned items):**
- **Dead `.frozen-panel*` CSS removed from `Home.razor.css`** (~75 lines) — the byte-identical copy orphaned by the T-26 extraction (CSS isolation scoped it to Home while the elements render inside `FrozenDayPanel`). Before deleting, verified all 9 inner classes exist in `FrozenDayPanel.razor.css` (single source) and that the neighbouring `.panel-actions*` block is **live** in Home (day-editor and bulk sheets use it) — that one stayed.
- **Vendored Bootstrap removed** (−8.5 MB from the repo and the publish output). Audit result: the markup used only `form-control` and `.btn` (both already redefined by `shared.css`) plus a **single** `alert alert-danger` (Home's API-error screen); what Bootstrap really provided was the global **Reboot** reset. Replaced with: a minimal reset at the top of `app.css` (box-sizing, body margin/color, heading/paragraph margins, font inherit on controls), local `.alert`/`.alert-danger` in `shared.css`, `<link>` removed from `index.html`, `wwwroot/lib/` deleted. The `.btn.btn-*` specificity compounds (born to fight Bootstrap's `.btn:disabled`) stay — harmless, comment updated.
- **Re-scan for other extraction leftovers:** none found beyond the frozen-panel block.

**Executed (extra items found during the sweep):**
- **Blazor-template leftovers pruned from `app.css`** (all confirmed unused): `.btn-primary`, the blue focus ring (`.btn:focus { box-shadow … }` — a Bootstrap-look artifact clashing with the app's dark design; intentional visual change), `.content`, the `EditForm` validation classes (app uses plain `@bind` inputs), `.blazor-error-boundary` (custom `ErrorContent` in MainLayout), the default `.loading-progress*` circle (custom splash in `index.html`), `code`, `.form-floating`. Kept: `h1:focus` (used by `FocusOnNavigate`) and `#blazor-error-ui`.
- **Duplicate `database/migrations/V001__initial_schema.sql` deleted** — identical copy of the `.pgsql`; two files for the same version invited divergence.
- Verified clean (no action needed): NuGet packages (only the 3 required), zero `TODO`/`HACK`/`FIXME` markers.

**Justification**
Dead CSS and unused vendored libraries make files harder to navigate, inflate the published bundle, and mislead future contributors into thinking a rule is active. Batching them into one end-of-phase sweep kept the diff isolated and low-risk.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor.css` — orphaned `.frozen-panel*` rules deleted
- `SharedParentalCustody/wwwroot/index.html` — Bootstrap `<link>` removed
- `SharedParentalCustody/wwwroot/lib/` — vendored Bootstrap deleted
- `SharedParentalCustody/wwwroot/css/app.css` — minimal reset added; template leftovers pruned
- `SharedParentalCustody/wwwroot/css/shared.css` — local `.alert`/`.alert-danger`; comment updates
- `database/migrations/V001__initial_schema.sql` — duplicate removed (`.pgsql` is canonical)

---

### S-06 — `care_schedules` RLS allows any authenticated user to modify any day

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Description**
The RLS policies on `care_schedules` are `USING (true)` and `WITH CHECK (true)` for all operations (SELECT, INSERT, UPDATE, DELETE) by any authenticated user. This means any authenticated user — including users from a *different family* if the app ever supports multiple families — can read and modify any schedule row. Currently the app has only two users per database, so this is safe in practice. However, it provides no defense-in-depth and makes multi-family support (or a shared Supabase instance) impossible without a complete RLS rewrite.

At minimum, add a `family_id` column or use the existing profile/role relationships to restrict writes so a user can only modify schedules belonging to their own family unit.

**Justification**
The current RLS is effectively "any authenticated user has full access to everything." This is acceptable only because the Supabase project is dedicated to a single family. For long-term security and multi-tenancy readiness, schedules should be scoped to the family.

**Implemented (migration V008, delivered together with F-14)**
- New `families` table + `family_id` on `profiles` / `care_schedules` / `swap_requests` / `activity_logs`; existing data backfilled into one family. `family_id` is auto-filled by `BEFORE INSERT` triggers derived from the row's parent/requester profile (spoof-proof — the client cannot set it) and is immutable.
- `care_schedules`, `profiles`, `activity_logs` and `families` RLS rewritten to scope by `get_my_family_id()` (a `SECURITY DEFINER` helper that avoids RLS self-recursion on `profiles`). `swap_requests` and `notifications` INSERT policies hardened so the requester is the caller and the target/recipient is in the same family.
- Uniqueness is now per-family: `care_schedules UNIQUE (family_id, schedule_date)` and the one-pending-per-date partial index includes `family_id`.
- **Client unchanged**: queries keep working because there is a single family and the triggers/RLS are transparent. This lays the multi-tenancy groundwork for future families.

**Files affected**
- `database/migrations/V008__families_and_admin.pgsql` — `families`, `family_id` columns + auto-fill triggers, `get_my_family_id()`, family-scoped RLS, per-family uniqueness
- `SharedParentalCustody/Models/Profile.cs` — `FamilyId`
