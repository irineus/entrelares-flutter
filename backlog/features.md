# Backlog — Features (pending)

Active feature items. Completed records live in [`archive/`](archive/). Conventions and the forward plan: [`README.md`](README.md). Live status: the [Notion board](https://app.notion.com/p/3ae2f3f4b9b28169acd9e642ad4760aa).

---

_Phase 6 completed features — **F-31** (invite growth loop), **F-32** (freemium foundation + premium waitlist), **F-33** (lawyer/court PDF wedge) and the five freemium gates **F-37** (3rd+ caregiver), **F-38** (email quota), **F-39** (planning horizon), **F-40** (Manager vs Administrator) and **F-41** (custom per-family roles, Aug 2026) — shipped; their full records live in [`archive/phase-6.md`](archive/phase-6.md)._

---

### F-07 — Multi-child support

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` |
| **Complexity** | `high` |
| **Impact** | `medium` |

**Description**
The database has no `children` table. For families with more than one child, the current model cannot distinguish which schedule applies to which child. Add a `children` table, add a `child_id` FK column to `care_schedules`, and add a child selector to the calendar view.

**Justification**
A subset of users have more than one child with different custody arrangements. The schema change is straightforward but requires updates to every data-access path. It is a low priority because the current model is valid for the majority of users.

**Files affected**
- Database schema (new `children` table, `care_schedules.child_id` FK) — see README
- `Entrelares/Models/CareSchedule.cs` — add `ChildId`
- `Entrelares/Services/CustodyService.cs` — filter all queries by `child_id`
- `Entrelares/Pages/Home.razor` — child selector

---

### F-08 — Calendar export / iCal download

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Description**
Add an export action in the reports or calendar header that generates an `.ics` (iCalendar) file for the selected month or year. Each custody day becomes a calendar event with the responsible parent's name as the event title. The file is triggered as a browser download via JS interop.

**Justification**
Sharing the custody plan with schools, doctors, or a family court is a real-world need. An iCal export integrates with every calendar app (Google Calendar, Apple Calendar, Outlook) without requiring any account or API key.

**Files affected**
- `Entrelares/Services/CustodyService.cs` — `GetSchedulesForPeriodAsync` already exists
- `Entrelares/Pages/ReportsSummary.razor` or `Home.razor` — export button
- New helper: `Entrelares/Services/ExportService.cs` — build `.ics` string, trigger download

---

### F-09 — Push notifications for swap requests

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` |
| **Complexity** | `high` |
| **Impact** | `medium` |

**Description**
Notify users when the app is closed or in the background. Since the T-53 cutover the Android
channel is a **native app**, so the natural transport is **FCM** (`firebase_messaging`) — not
the Web Push/VAPID stack the original record was written around.

> **Rewritten 26/08/2026 (post-cutover board sweep).** The record assumed the Blazor PWA:
> VAPID keys, a service-worker `push` handler, `js/pwa.js` install-state detection, the
> iOS-needs-an-installed-PWA branch. The shipped `service-worker.js` is deliberately a
> TOMBSTONE and cannot gain a push handler, and the PWA-install branch died with the PWA.
> Everything below survives from the original design.

- **Native first (Android now, iOS with T-40).** `firebase_messaging` with per-flavor Firebase
  config; token registration into a new `push_subscriptions` table (per profile, per device,
  RLS: own rows only). APNs rides the same plugin when T-40 happens — this item is T-40's
  named push companion. **Flutter Web push is a separate, later decision**: it needs its own
  service worker, and the tombstone constraint means it must be designed, never bolted on.
- **Server side unchanged: hang the dispatcher off the single writer.** Every push-worthy
  moment already writes a `notifications` row (swap requested / approved / refused / reverted /
  auto-approved). Trigger the push from **that** insert (DB webhook → new Edge Function), so
  push, in-app and e-mail can never tell three different stories. Since U-13/U-24 the row
  carries `params` with ISO dates and is rendered in the **reader's** language — assemble the
  payload per recipient with the server-side mirror (`functions/_shared/i18n.ts`), never from
  a PT-BR string.
- **The opt-in flow is still the hard part.** Never ask on load: Android 13+ has a real runtime
  permission with the same "denied is expensive" economics the web prompt had. The request
  rides a user gesture after the person has a reason to want it — the first swap request they
  live through, or an explicit action on the Notificações screen. Wire it into the U-23
  onboarding surface and honour its rule: a step reads REAL state, so it closes when a
  `push_subscriptions` row exists, never when a modal was shown.
- **Secrets/config:** the Firebase project config is per environment (dev/prod flavors) and
  any function secret must exist on dev **and** prod *before* CI redeploys the functions — the
  same ordering trap S-16 documented for the API keys.
- **Quota:** push has no Resend-style shared allowance (T-49 does not apply), which raises the
  product question to settle here: for which events does push **replace** the e-mail (F-38's
  quota exists precisely because e-mail is the scarce channel) and for which does it add to it.

**Files affected**
- New migration — `push_subscriptions` table + RLS (own rows only)
- `apps/entrelares_app/` — `firebase_messaging` wiring per flavor, token lifecycle, the
  permission sheet, the U-23 onboarding step
- `supabase/functions/send-push-notification/` — new Edge Function (**add it to
  `.github/functions.sh`**, or the drift guard fails the run)
- Catalog keys for every new string (U-13), DB rules covered in `packages/entrelares_db_gate`

---

_F-16 + F-17 (item 5.3), F-18 (item 5.4), F-23 (item 5.7) and F-28 (item 5.8, multi-caregiver) were completed in Phase 5 — records live in [`archive/phase-5.md`](archive/phase-5.md). F-23's polling approach spun off **F-29** (true push via a supabase-js bridge, below), since Supabase Realtime's WebSocket is unsupported in Blazor WASM._

---

_F-27 (Phase 4 item 4.7) was completed in July 2026 — its record lives in [`archive/phase-4.md`](archive/phase-4.md)._

---

_F-29 (Phase 5 item 5.14) was completed in July 2026 (v1.5.23) — its record lives in [`archive/phase-5.md`](archive/phase-5.md). True push now rides the supabase-js interop bridge (vendored UMD, CSP-compliant), scoped to everything the poll covered (calendar, swaps, roster, deletion banner, notification badge); F-23's quiet poll stays as the adaptive safety net (25s socket-down / 120s healthy)._

---

### F-30 — One e-mail linked to multiple families

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` |
| **Complexity** | `high` |
| **Impact** | `medium` |

**Description**
Today the system enforces **1 e-mail = 1 family**: an authenticated GoTrue user maps to exactly
one `profiles` row inside one family. This mirrors real life poorly — the same person can be
**"Pai"** in one family and **"Tio"** in another, and there is nothing that should forbid it. When a
caregiver who already has an account is invited to a *different* family, registration collides on the
existing auth user (`auth.admin.createUser` → "already registered"). The interim workaround (shipped
alongside this backlog entry) **warns the caregiver and, on consent, permanently deletes their previous
family registration before enrolling them in the new one** — a lossy migration, not true multi-membership.

This item makes membership genuinely **many-to-many**:
- Decouple `profiles` from a single `family_id` per auth user — either allow multiple `profiles` rows
  per `user_id` (one per family) or introduce a `family_members` join between `auth.users` and `families`.
- Rework every family-scoped RLS policy and `get_my_family_id()` (which assumes a single family) into a
  **current-family / family-picker** model, so the user chooses which family they are acting in.
- Update invitations (`create_invitation` / `register-invitee`) to *add* a membership instead of blocking
  or migrating when the e-mail already exists.
- Per-family identity: `full_name` is global, but `role`, `color_slot`, `is_admin`, `left_at`,
  `deletion_scheduled_for` are **per membership**.
- UI: a family switcher in the shell; every calendar/roster/swap/notification view scopes to the active family.
- Migration path off the interim "1 e-mail = 1 family" workaround, preserving existing single-family users.

**Justification**
A structural change touching the auth-to-profile mapping, the whole RLS surface, and much of the UI —
deferred deliberately. The lossy cross-family migration workaround covers the immediate need (a caregiver
genuinely moving from one family to another) without this complexity; this item is only warranted once
real simultaneous multi-family membership is a validated requirement.

**Files affected**
- DB migrations: `profiles` / new `family_members` join, `get_my_family_id()` + every family-scoped RLS policy
- `create_invitation`, `register-invitee` — add-membership instead of block/migrate
- `Entrelares/Services/*` — family-scoped services gain an active-family dimension
- Shell/navigation — family switcher; `Home.razor`, roster, swaps, notifications scope to the active family

---

### F-34 — Shared expenses module (co-parenting hub expansion)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` |
| **Complexity** | `high` |
| **Impact** | `high` |
| **Roadmap** | Roadmap group 6 (co-parenting hub expansion) — **strategic premium expansion / candidate second paid wedge** (F-32 free/paid line). *(Was labelled "Phase 7 (Enhancement)" while phases doubled as a plan; since Aug 2026 the phase is assigned at CLOSE time and the group is the plan.)* |
| **Depends on** | F-32 (entitlement) for the premium gate; cross-repo: landing benefits/pricing (`L-08`) update on launch |

**Description**
Expand the product from a custody *calendar* into a co-parenting *hub* by adding a
**shared-expenses module**: record child-related expenses (school, medical, clothes,
activities), split them by an agreed proportion, and raise **reimbursement requests**
between caregivers (mirroring the existing two-party swap-approval pattern — one records,
the other confirms/settles). Include a running balance and a period export (reuses the
F-33 PDF pattern for a court-presentable expense statement).

**Justification**
Expense-splitting is the feature that anchors the paid tiers of the global incumbents
(OurFamilyWizard, 2houses, Cozi). It is the **single biggest TAM + monetization expansion**
available to this product, and it reuses two mechanics already built and trusted here: the
two-party approval workflow and the immutable audit trail. Large scope, hence tracked as a
strategic item rather than an immediate one — its priority may rise once F-33 validates the
premium tier.

**Files affected**
- Migrations: `expenses`, `expense_shares` / `reimbursement_requests` tables (family-scoped RLS)
- `Services/ExpenseService.cs` — new; two-party settle workflow reusing the swap-approval pattern
- New pages/components under `Pages/` — expense list, add-expense sheet, balance card
- `ReportPdfService.cs` (F-33) — extend for the expense statement export
- Tests: split math, reimbursement approval workflow, RLS family isolation

---

### F-35 — In-app communication log (court-admissible messaging)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` |
| **Complexity** | `high` |
| **Impact** | `medium` |
| **Roadmap** | Phase 8 (Long-term) — candidate premium feature, sensitive scope |
| **Depends on** | F-32 (entitlement); overlaps the LGPD/legal posture (S-13/S-15) |

**Description**
An in-app, **append-only messaging channel** between caregivers whose history is immutable
and timestamped — positioned (like F-33) as court-admissible communication that keeps
coordination out of WhatsApp and on the record. Another OurFamilyWizard staple ("tone
meter", immutable thread).

**Justification**
High trust value in high-conflict co-parenting, and it reinforces the "immutable record"
positioning. **Deliberately low priority / long-term:** it is scope-heavy and sensitive
(content moderation expectations, LGPD data-subject implications, notification load), so it
should only follow once the paid tier and the simpler wedges (F-33, F-34) are proven.

**Files affected**
- Migration: `messages` table (append-only, family-scoped RLS, immutable by trigger)
- `Services/MessageService.cs` — new; realtime via the existing F-29 bridge
- New messaging page/component; notification integration
- Legal review coupling (S-15); tests: immutability, RLS, realtime delivery

---

### F-36 — Document vault (school / medical / court documents)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` |
| **Complexity** | `medium` |
| **Impact** | `medium` |
| **Roadmap** | Phase 8 (Long-term) — candidate premium feature |
| **Depends on** | F-32 (entitlement); Supabase Storage (new dependency) |

**Description**
A shared, family-scoped **document vault** for the child's important files — school records,
medical documents, the custody agreement / court orders — stored in **Supabase Storage** with
family-scoped access policies, so both caregivers always have the current version. A natural
companion to the calendar and the legal-grade positioning.

**Justification**
Removes another reason co-parents fall back to scattered WhatsApp/e-mail attachments, and
rounds out the "co-parenting hub" premium tier. Medium complexity (introduces Storage +
its RLS/policies, upload UI, size limits). Long-term until the core paid tier is proven.

**Files affected**
- Supabase Storage bucket + access policies (family-scoped); migration for a `documents` index table
- `Services/DocumentService.cs` — new; upload/list/delete via Storage
- New vault page/component (upload sheet, list, preview)
- Tests: RLS family isolation on Storage, upload/list happy path


---

### F-49 — Company identity (CNPJ) on the payment surfaces

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |
| **Roadmap** | Roadmap group 8 (Início da monetização) — **gated on the CNPJ existing** (owner milestone, like T-36/S-17) |
| **Prerequisites** | The company must exist. **Pairs with landing L-15 (same delivery, cross-repo pair)** |

**Description**
The half of **F-48** that could not ship in Aug 2026: the owner has no CNPJ yet and decided
not to expose his personal identity (CPF/name) on the payment surfaces instead. When the
company exists: CNPJ + razão social visible on the paywall/checkout area of the Família page
(next to the F-48 guarantee box) and in the app footer where it fits; the landing mirrors it
in the footer of every page (**L-15**). Check whether the Terms' "Prestador do serviço"
wording gains the CNPJ — that half IS legal-page substance (sync both repos, standing MUST),
but a pure identity disclosure is non-material: no `PolicyVersions` bump, only the "Última
atualização" date.

**Justification**
Paying a site with no legal identity is the trust leap Brazilian users rightly refuse (the
F-48 review's diagnosis). Everything else from that review shipped in F-48/L-14; this record
keeps the missing piece visible instead of implicit, parked with the other
company-milestone items in group 8.

**Files affected**
- `Pages/FamilyPage.razor` (identity line near the premium offer) + footer/layout component
- App `Pages/Terms.razor` §18 + landing `termos.html` (Prestador do serviço — same delivery)
- Landing: footer of every page (L-15, cross-repo)

---

### F-50 — Viewer member (read-only family member, promotable to full)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `high` |
| **Impact** | `medium` |
| **Roadmap** | Roadmap group 6 (co-parenting hub expansion) — a new *membership category*, not a new module; placed here because it is product expansion with a monetization edge, not polish |
| **Depends on** | **F-37/T-41** (caregiver seats + `app_settings` limits), **F-32** (entitlement, if the cap is tiered), **S-11** (leaving/tombstone machinery), **F-28** (two-party invariants), **F-41** (custom roles — orthogonal, but the invite sheet is shared) |
| **Cross-repo** | Privacy policy gains a member category that reads family data → app `Pages/Privacy.razor` + landing `privacidade.html` in the SAME delivery (standing MUST) |

**Description**
Add a second **membership category** to a family, orthogonal to both `is_admin` (F-40 Gestor ×
Administrador) and to `role_id` (the Pai/Avó/Babá vocabulary of `RoleCatalog`/F-41):

- **Full member** (today's only category): appears on the calendar, can be the planned or the
  real parent of a day, opens and approves swaps, receives and generates notifications.
- **Viewer** (new): **sees the plan, generates nothing.** Reads the calendar, the today card,
  the day observation, the history and the reports — and has no write path anywhere in the
  product. The two-party negotiation texts are *not* part of what they see (decision 3 below).

The category lives on `profiles` (`membership_type` = `'full' | 'viewer'`, default `'full'`),
is **enforced in the database** and only mirrored by the UI — the same posture as every other
day/family rule here. Concretely a viewer:

- can never be `scheduled_parent_id` nor `actual_parent_id` — the same block class the departed
  member already has in `enforce_day_protection` (S-11), and written the same way, so the two
  read as one rule;
- can never be the requester nor the target of a `swap_requests` row. This keeps **F-28's
  invariant intact**: the two-party algebra (and every message text built on it) never learns
  about a third kind of participant, because the viewer simply is not a party;
- can never hold `is_admin` — protecting the ≥1-admin invariant by construction — and every
  admin RPC (`set_member_admin`, `rename_family`, `create_invitation`, the custom-role RPCs,
  `set_member_role`, the family-deletion consent flow) refuses a viewer caller;
- holds **no `color_slot`**: the 4-slot palette (`max_caregivers = 4`) exists for the people who
  appear on a day, and a viewer never does.

**Promotion (viewer → full)** is an admin action (`promote_member_to_full`), allowed only when a
full caregiver seat **and** a colour slot are free; it assigns the colour slot and is audited.
**Demotion (full → viewer) is forbidden by design** — a full member may be the planned or real
parent of future days, the target of a pending request, or the approver of an open swap;
demoting them would leave a live workflow with a party that cannot act. This is the same
reasoning that makes F-28's scenario C forbidden: the cheap rule that keeps every downstream
text and gate valid. (If the need ever appears, the honest path is "leave the family, come back
as a viewer" — the S-11 flow already clears the future.)

**Exit is a hard delete, not a tombstone.** S-11's tombstone exists because the past *references*
the member: `care_schedules.scheduled_parent_id/actual_parent_id` (FKs with no `ON DELETE`
action), `activity_logs.performed_by_id` (append-only, likewise), resolved `swap_requests`. A
viewer, by construction, is referenced by none of them; their remaining rows either cascade
(`consent_records`, `premium_interest`, family-deletion consents) or set null (`account_logs`).
So a leaving viewer is erased **completely and immediately** — no 30-day grace, no name kept.
Do it as a *guarded* delete, not an assumed one: the RPC checks the profile is referenced
nowhere and falls back to the S-11 path if it ever is (a future feature could add a reference
without thinking of this item). Worth mirroring in the leaving screen's texts — for a viewer the
LGPD answer is genuinely "everything goes, now", which is better than what a full member gets.

**Invitation flow**: `create_invitation` takes the member type; `get_invite_info`, the invitation
e-mail template (`send-swap-email`) and the Register/invitee screen must all say what the person
is being invited as — someone accepting a "viewer" invitation must not discover the limitation
after signing up. The S-15/A-1 consent declaration follows `joined_via_invite` as it does today;
check with the S-15 wording rules whether the invitee declaration needs a viewer variant (it is a
claim about what the person can do inside the system — verify it against the code, not against
our own prose).

**Justification**
Real, recurring demand from the field: a grandmother, a nanny, a new partner or a
lawyer/mediator needs to **see** the plan and never touch it. Today the only way to give that
access is a full seat, which (a) spends one of the four colour slots, (b) makes the person
assignable to days, and (c) lets them open swap requests — three risks nobody wanted to take,
so the access simply is not given and those people stay outside the app (asking by WhatsApp,
which is exactly the coordination the product exists to remove). It is also the natural shape of
the **L-12 lawyer/mediator partnership**: a read-only seat is precisely what a lawyer wants, and
it pairs with the F-33 PDF report. And it is a clean upsell surface (decision 1 below),
because it adds value without touching the free safety core.

**Design decisions (locked with the product owner, Aug 2026)**
1. **Seats — viewers sit OUTSIDE the F-37 caregiver pool**, with their own `app_settings` keys
   (`free_viewers`, `max_viewers`, T-41), a low free cap and a generous premium one. Rationale:
   the 4-slot palette (`max_caregivers`) exists for the people who appear on a day, and spending
   it on someone who never does would be wrong twice — it would price out a real caregiver and
   it would make "promote when a seat frees up" meaningless, since the viewer would already hold
   the seat. Promotion therefore needs a **full seat AND a colour slot** free. *(Rejected:
   free-and-unlimited — no cost signal at all, and an invite surface with no ceiling; and the
   shared pool, for the reason above.)*
2. **Reception — in-app notifications YES, e-mail NO.** The viewer sees the family's events in
   the app; nothing is pushed to their inbox. This keeps the F-38 e-mail quota for the people who
   actually have to act on a request, and it avoids routing family communication into a third
   party's mailbox — which is a materially different privacy posture from "they can look it up".
3. **Free text — the day observation YES, the swap messages NO.** The observation is operational
   ("levar o uniforme") and is exactly what a grandmother or a nanny needs; the F-44 swap
   messages and the F-47 revert notes are the two parties *negotiating* and stay between them.
   Consequence to honour in the same delivery: the row-level read rules must split those columns
   (not just the UI), and the privacy policy's description of who reads free text (S-15) is
   mirrored in **both** legal documents.
4. **Reports/PDF — open.** May a viewer export the F-33 PDF? Exporting is arguably "generating
   something", but the content is data they already read on screen. Proposal: allowed. Settle it
   at implementation time, together with decision 3 (the PDF now carries the F-45 motivation
   text, which is swap-message territory — so if the viewer keeps the export, that section is
   the part that must be suppressed for them).

**Files affected**
- Migration: `profiles.membership_type`; guards in `enforce_day_protection` (assignment block),
  the swap-request write path, `create_invitation` (member type + viewer cap), `set_member_admin`
  and the other admin RPCs; new `promote_member_to_full` and the guarded viewer-delete RPC;
  `active_member_count` / seat helpers must keep counting **full** members only
- `Models/Profile.cs` — `MembershipType` + an `IsViewer` convenience
- `Services/FamilyService.cs` (invite with type, promote), `Services/ProfileService.cs`,
  `Services/SwapRequestService.cs` + `Services/DeletionService.cs` (viewer path)
- `Pages/FamilyPage.razor` (member list badge, invite sheet, promote action),
  `Pages/Home.razor` + `Pages/Components/TodayCard.razor` (hide every action),
  `Pages/Notifications.razor`, `Pages/Leaving.razor` (viewer texts), `Pages/Register.razor`
- `supabase/functions/send-swap-email` — invitation template says the member type
- Legal: `Pages/Privacy.razor` + landing `public/privacidade.html` (new member category)
- Tests: unit (the membership rule helper — what a viewer may do, mirrored from the DB);
  integration (viewer cannot be assigned to a day, cannot open or receive a swap, cannot be made
  admin, cannot call the admin RPCs; promotion refused with no free seat/colour slot; viewer
  delete leaves no tombstone); E2E (invite a viewer → viewer sees a read-only calendar)

---

### F-51 — Clear planned days in one action (month clear + wizard overwrite)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `high` (removes the worst piece of manual labour left in the calendar) |
| **Roadmap** | Roadmap group 5 (progressive enhancement & polish) — small, self-contained, born of field use |
| **Depends on** | **F-40** (clearing a planned day is an admin/Gestor power), **F-39/T-41** (the planning horizon bounds the wizard range), **F-12/F-13** (frozen and past-day protections), **T-45** (the D+1 handoff cascade — see the boundary note), **T-35** (concurrency token — DELETE is exempt, verified below) |

**Description**
The calendar already has a bulk mode — multi-select days, then **🗑️ Apagar dias**
(`Home.razor` → `RequestClearScheduledParent` / `ConfirmClearScheduledParent` / `SaveBulkChanges`
path A). Two limits make it useless for the case it should serve, **re-planning**:

1. **The selection is manual and month-scoped** (`selectedDays` over `monthlySchedules`), so
   clearing a year means opening 12 months and tapping ~365 cells.
2. **The delete is one round trip per day** — `CustodyService.DeleteScheduleAsync` inside a
   `foreach`. Hundreds of sequential PostgREST calls, no atomicity: a failure halfway leaves a
   half-cleared plan, which is worse than either end state.

**Two entry points, no scope picker** (owner, Aug 2026 — chosen over a generic scope/date-range
selector precisely to keep the sheet clean; each entry point is one tap in the place where the
user already is):

- **A · "Limpar mês"** — one action on the displayed month: erases the planned days from
  **today (inclusive) to the end of that month**. The past is never touched, *even for an admin
  who could edit past days one by one* (F-40) — a deliberate narrowing: a bulk action must not
  be able to rewrite history by accident, and the single-day editor is still there for an
  honest retroactive fix.
- **B · "Substituir os dias já planejados" inside the rotation wizard** — a checkbox that makes
  the wizard clear **exactly the range it is about to generate** (its start → the horizon-clamped
  end) before inserting. This is the case the whole item exists for: the arrangement changed, so
  wipe and re-plan **in one action**, without the user ever thinking about "clearing" as a
  separate chore.

B is also why no "all future days" scope is needed: the wizard's own range already reaches the
planning horizon. Wiping a long stretch *without* generating anything is therefore not offered —
if it is ever asked for, the fallback today is A, month by month. Recorded so a future session
knows it was excluded on purpose, not forgotten.

**Why B is what makes the feature work at all.** The wizard **skips days that already exist**
(`BulkUpsertAsync`: "dias já preenchidos foram mantidos"). So today a user whose plan changed
opens the wizard, generates over the old plan, gets **"0 dias criados"** and concludes the
wizard is broken — the product silently refuses the single most important thing it should do.
The checkbox turns that dead end into the normal path.

**Both go through one server-side operation.** A `SECURITY INVOKER` RPC —
`clear_schedule_range(p_from date, p_to date)` — doing a single
`DELETE … WHERE family_id = get_my_family_id() AND schedule_date BETWEEN …`, returning the
counts. Invoker on purpose (the T-35 lesson: a role check inside a `SECURITY DEFINER` reads the
*owner*, not the caller), so `enforce_day_protection` keeps firing per row **as the caller** and
the bulk path obeys exactly the same rules as the single-day path: admin-only clear, past-day
immutability, frozen days, approved-swap days. One statement, one transaction.

- **Admin gating.** Clearing an assigned day is admin-only (the July 2026 QA rule, in the DB).
  So **A** and the **B checkbox** appear only for an admin/admin mode; for a non-admin the
  wizard keeps today's purely additive behaviour, unchanged.
- **B must be ONE transaction, not clear-then-insert.** If the clear commits and the insert
  fails, the family is left with **no plan at all** — strictly worse than the stale plan they
  had. So the wizard's write becomes `replace_schedule_range(p_from, p_to, p_days jsonb)`:
  delete the range and insert the generated days in the same transaction, all-or-nothing.
  (Fallback if that proves too big for one delivery: keep `BulkUpsertAsync` and ship A first —
  but then say so in the UI, never leave the two halves looking atomic when they are not.)
- **Rows the trigger would refuse.** Raising would abort the whole statement, so a single frozen
  day could block an entire re-plan. The RPC **excludes** them in its own `WHERE` (frozen dates,
  approved-swap days, past days) and returns `deleted / skipped_frozen / skipped_swap`, which is
  what the confirmation and the closing toast render (`Helpers/BulkSummary.cs` already builds
  this kind of sentence). The trigger stays the authority; the `WHERE` only avoids handing it
  rows it would reject. In B the same counts replace the wizard's "X dias já preenchidos foram
  mantidos" line with an honest "Y dias substituídos · Z mantidos (troca aprovada/pendente)".
- **T-45 boundary, and a second reason for the single statement.** The D+1 cascade
  (`trigger_d_sync_next_day_handoff`) fires `AFTER INSERT OR UPDATE OR DELETE`, and on a DELETE
  it treats D+1 as a transition day (no previous day), restoring its `handoff_time` from
  `handoff_time_backup`. Postgres queues AFTER-ROW triggers to the **end of the statement**, so
  in a single-statement range delete every D+1 *inside* the range is already gone
  (`IF NOT FOUND → RETURN NULL`) and only the **day just after the cleared range** is touched —
  once, and correctly. The current per-day loop instead fires the cascade N times, each one
  updating the next day right before deleting it: N−1 pointless `activity_logs` rows and
  revision-token churn. Verify this at implementation with the real trigger, but it is a second,
  independent argument for the single `DELETE`.
- **T-35**: verified — the token triggers are `BEFORE INSERT`/`BEFORE UPDATE` only
  (`20260804140000_t35_nonguessable_revision_token.sql`), so a DELETE needs no `submitted_token`
  echo. Stated here because assuming the opposite would cost a red gate.
- **Audit volume**: `activity_logs` takes one row per deleted day (trigger-written,
  append-only). Clearing a year writes ~365 rows — semantically right, but it floods the history
  screen (ReportsAudit/F-45). Proposal, in the same item: stamp the rows with a **batch key** and
  render the batch as one expandable entry. Without it, the first real use makes the history tab
  unusable.
- **Safety**: both actions confirm with the exact count and the exact range spelled out (not a
  generic "tem certeza?"), and every erased day stays in the audit log — what is erased is the
  *plan*, never the history.

**Justification**
Straight from field use: when the arrangement between the parents changes, they need to wipe the
old plan and generate a new one. Today that is a several-hundred-tap chore across many months,
and skipping it makes the wizard produce nothing at all — a dead end that reads as a bug. The
fix adds no new rule: it gives the rules that already exist a scope, in the two places where the
user actually stands (looking at a month; opening the wizard).

**Files affected**
- New migration: `clear_schedule_range(p_from, p_to)` and `replace_schedule_range(p_from, p_to,
  p_days)` RPCs (SECURITY INVOKER, returning the counts) plus the audit batch key, if adopted
- `Services/CustodyService.cs` — `ClearScheduleRangeAsync` / `ReplaceScheduleRangeAsync`
  (replaces the per-day delete loop and, for B, the client-side `BulkUpsertAsync` write)
- `Pages/Home.razor` + `.razor.css` — the "Limpar mês" action and its confirmation;
  `Helpers/BulkSummary.cs` — the skipped-reason breakdown
- `Pages/Components/ScheduleWizard.razor` — the "substituir os dias já planejados" checkbox
  (admin only), the replace call and the new result sentence
- `Pages/ReportsAudit.razor` — grouped rendering of a batch clear (if adopted)
- Tests: unit (month-clear range math — today..end-of-month, empty for a past month — and the
  summary sentence); integration (non-admin refused; frozen, approved-swap and past days
  survive; the replace is atomic — a failing insert leaves the old plan intact; the day after
  the cleared range keeps a correct handoff time per T-45); E2E (`BulkUiTests` sibling — clear
  the month; wizard with overwrite re-plans an already-planned range in one pass)

---

### F-53 — Closed-alpha tester reward: permanent Premium for tester families

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `medium` |
| **Roadmap** | Roadmap group 4 (Distribuição), first — coupled to the closed-alpha campaign RUNNING now |

**Description**
The closed-alpha recruitment message (WhatsApp, 11/08/2026) makes a public promise: **whoever
joins the test gets Premium free, permanently, for their family — current and future paid
features**. Nothing in the system fulfils that today: a tester signs up like anyone else,
starts the 30-day trial (F-32) and falls to `free` when it ends. This item is the promise's
implementation, recorded the day the promise was made (the S-15 lesson: a published claim
with no implementation is a liability — this one just lives in WhatsApp instead of a policy
page).

What exists to build on: `set_family_plan(family_id, 'premium')` (service_role-only, F-32) —
the same mechanism the pre-F-32 grandfathering used. What the analysis must decide:
- **Marking**: a bare `plan = 'premium'` is indistinguishable from a paying or grandfathered
  family. The grant should be auditable (e.g. a `premium_origin`/note marker), so a future
  session can answer "why is this family premium?".
- **Protection against billing downgrades**: if a tester family ever touches the checkout
  (subscribes, then cancels or goes overdue), the T-39 dunning path sets `plan='free'` —
  silently revoking the granted reward. The grant must survive that path (webhook checks the
  marker before downgrading), or the paywall must not be reachable for these families at all.
- **Matching testers to families**: the tester list is e-mails (Google group); families are
  found via `profiles.email` → `family_id`. Manual per-family grant via runbook SQL is
  acceptable at this scale (~12 testers); the item records the exact statement.
- **Scope of "tester"**: the promise says who JOINS the test — decide the cutoff (opted-in
  during the closed-alpha window) and write it down, so late arrivals are a decision instead
  of an argument.

**Justification**
The reward is what makes recruiting ~12 testers for 14 uninterrupted days (Play's
production-access gate) realistic on a personal network. The cost is near zero at this scale;
the liability of NOT implementing it is a broken public promise to the app's first and most
engaged users — the exact people whose word of mouth the launch depends on.

**Files affected**
- Runbook section or migration with the grant SQL (`set_family_plan` + marker)
- `supabase/functions/billing-webhook/` — downgrade path checks the marker (analysis decides)
- `store/README.md` §8 (closed test) — cross-reference the reward procedure

---

### F-52 — Aviso de imprevisto (one-tap notice, recorded, no approval)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `high` (covers the most frequent real-life event the product currently sends to WhatsApp) |
| **Roadmap** | Roadmap group 5 (progressive enhancement & polish) — same shelf as F-51: small, self-contained, born of field use. **Candidate to pull forward**: it is the cheapest remaining addition to the daily loop |
| **Depends on** | **F-10/F-29** (notifications + realtime — the delivery already exists), **U-13/U-24** (the notice is read in the reader's language, with ISO dates in `params`), **F-38** (e-mail quota, if it also goes by e-mail), **F-09** (push, when it lands), **F-50** (a viewer never sends one) |
| **Boundary** | **F-35** (in-app communication log, group 6) — see "Why this is not messaging" |

> **Created 06/08/2026** from an external product review: *"a rotina de coparentalidade envolve
> imprevistos de última hora que não exigem aprovação de troca, mas sim um aviso oficial
> (trânsito, médico)."*

**Description**
A **one-tap notice** on the current day's card: the responsible caregiver reports something that
affects the handoff *without* changing who has the child — running late, a doctor's appointment,
traffic. The other party is notified immediately and the notice is **stamped and kept**, so the
"eu não fiquei sabendo" argument the product exists to remove also covers the case that happens
weekly, not just the case that happens monthly.

Concretely: pick a reason from a **closed set** (+ optional short free text), confirm, done —
no approval, no counterpart action, nothing to negotiate.

**Why this is not messaging (the F-35 boundary, and what keeps this item small).** F-35 is a
free-form, append-only conversation channel: a surface with moderation expectations, LGPD
data-subject weight and a notification load of its own. This item is deliberately its
**constrained subset** — a closed reason list, one short optional line, one direction, no reply.
That is what lets it ship in group 5 while F-35 stays a group-6 decision. If the reason list ever
grows into a chat, the item has become F-35 and should be re-decided as such.

**Why it must not touch the calendar.** An aviso **never** changes `actual_parent`, never freezes
a day and never enters the two-party workflow — that invariant (F-28) is what keeps every
existing message text valid. If the imprevisto actually changes *who has the child*, the honest
path is the swap request, and the sheet should say so and offer it, rather than letting the aviso
become a shadow swap nobody approved.

**Vocabulary — the third term, named on purpose.** The product already distinguishes
**Observação do dia** (operational note attached to a date) from **Mensagem** (the F-44 text two
parties exchange while negotiating a swap) and from the F-47 revert note. **Aviso** is the third:
*one-way, about right now, tied to a day, requiring nothing from the reader.* The F-44 QA round
showed how expensive it is to leave two of these blurred — settle the word in the analysis step,
in both languages, before any string is written.

**Design questions to settle before coding**
- **Reason set.** Proposal: `atraso` (with an estimate — 15/30/60 min), `imprevisto médico`,
  `trânsito`, `outro`. Closed because it must render in the **reader's** language: the sender's
  choice travels as a key in `params`, never as a Portuguese sentence.
- **Free text**: optional, short, normalized through the F-44 helper (`NormalizeFreeText`) so the
  two free-text fields cannot diverge in trimming/limits.
- **Who receives it**: the day's counterpart (effective responsible = `actual_parent ??
  scheduled_parent`, and the sender's opposite) — or every active full member? A three-caregiver
  family makes this a real choice, not a detail.
- **Channels**: in-app always; e-mail is a **quota** decision (F-38) and an aviso is frequent by
  nature — the case for push (F-09) is stronger here than for anything else in the product,
  because the whole value is *arriving before the person leaves the house*.
- **Rate limit.** One-way and unapprovable is exactly the shape that degrades into a chat. Cap
  per sender per day (server-side, like every other rule here), and say the cap out loud in the
  UI rather than silently dropping.
- **History and PDF**: the notice belongs in the audit history; whether it belongs in the F-33
  PDF export is a product call (it is routine coordination, not a change to the plan — including
  it makes the report longer and arguably more honest).
- **Free forever.** It sits in the safety/coordination core, which the guiding principles keep
  out of every paywall. State it in the item so no future gate reaches for it.

**Implementation shape**
- New table `day_notices` (family-scoped RLS, `schedule_date`, sender, reason key, optional text,
  `created_at`), **immutable by trigger** — append-only like `activity_logs`, for the same reason:
  a record that can be edited is not a record. The client never updates or deletes a row.
- The **audit row is written by trigger**, never by the client — the standing invariant for
  `activity_logs`.
- **The notification insert must carry `params`.** `notification_params_coverage_test.dart`
  reads `supabase/migrations` and fails any live `INSERT INTO public.notifications` without
  them, and the renderer suite asserts the rendered sentence **byte-for-byte** — so a new type
  ships with its renderer branch and its two catalogue entries, or the core lane goes red before
  the code ever reaches a screen.
- Sender guards in the DB: not a departed member (S-11), not a viewer (F-50, when it exists),
  and only for **today** (or today ± the handoff window — decide; a notice about a day in three
  weeks is a message, not an aviso).

**Justification**
This is the most frequent real event in shared custody and the one the product currently does not
serve at all: the day does not change, so the swap workflow is the wrong tool, and the day
observation is a *plan* note, not an alert — so the parent opens WhatsApp, which is precisely the
coordination the app exists to take off WhatsApp. It reuses machinery that is already built and
trusted (notifications, realtime delivery, the immutable log), and it strengthens the product's
central claim on a weekly cadence instead of a monthly one.

**Files affected**
- New migration: `day_notices` + immutability trigger + the audit-log trigger + the notification
  writer (with `params`) + the sender guards
- `Services/` — a `DayNoticeService` (reads/creates through `RetryHelper`, like every other call)
- `Pages/Components/TodayCard.razor` + a notice sheet (bottom-sheet pattern: chrome in the PAGE)
- `Pages/Notifications.razor` renderer branch; `Pages/ReportsAudit.razor` rendering; optionally
  `Services/ReportPdfService.cs`
- `Localization/` — the reason keys and the notice sentence in both languages
- Tests: unit (renderer byte-for-byte per reason, the free-text normalization, the send-window
  rule); integration (immutability — an UPDATE/DELETE is refused; the counterpart sees the row
  across RLS; a departed member cannot send; the daily cap); E2E (send an aviso → the other
  caregiver's notification shows it)

---

### F-55 — Child day agenda (child entity + day timeline in the sheet)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` — strongest field-validated demand in group 6 so far; candidate to jump the group's queue |
| **Complexity** | `high` (new entity + event model + the recurrence question) |
| **Impact** | `high` — turns the app from custody transitions into the child's operational calendar |
| **Roadmap** | Group 6 (hub expansion), proposed at the END (Ordem 5) pending an owner reordering decision — the group's current order (F-34…F-36, F-50) predates this field signal |
| **Depends on** | **Child entity** (the `children`-table half of F-07 — see prerequisite below), **U-25** (the sheet layout it renders into), **U-13/U-24** (reader-language texts + per-language dates), **F-50** (viewers read it, never write it) |
| **Boundary** | **F-52** (aviso = *right now*, one-way; an agenda event = *planned*), **F-35** (no chat here), **F-36** (documents attach later, not in v1) |

> **Created 12/08/2026 from closed-alpha feedback (audio + owner's reading).** The tester,
> unprompted, used the **Outlook mobile day view** as the model: *"quando você clica no dia
> ele deveria aparecer um igual no Outlook, ali o resumo do dia, já com horário que ele vai
> na escola e tal — o resumo do dia específico, com as atividades da criança […] o horário
> ali e agendamento do que a criança tem lá: livre de manhã, pra escola de tarde, e coisas
> igual remédio, alguma coisa assim."* Owner's reading: this is the entry point for child
> information in the product, and possibly what the day observation grows into.

**Description**
Per-child, per-day **events** — school shift, medical appointment, medicine at 14h, free
morning — rendered as a **day timeline** inside the day bottom-sheet (the space U-25 frees).
The custody data stays minimized (U-25's chips); the child's day becomes the sheet's content.

**Prerequisite — the child entity, born multi-child-ready.** The app has no `children` table
(F-07). F-55's first PR delivers the entity: `children` (family-scoped RLS, name + minimal
profile) + registration UI — with `child_id` FKs on everything F-55 creates, even though v1
may render a single child without a selector. Building the agenda single-child-hardcoded is
forbidden — that is exactly the rework F-07 warns about. F-07 itself remains open as the
multi-child COMPLETION (selector + per-child schedules across every existing data path).

**Design questions to settle before coding (the analysis step of the item)**
- **Observação do dia: replace or coexist?** The owner leans replace ("substituiria o campo
  observação por essa miríade de atividades"). Careful — the observation is load-bearing:
  F-47's revert flow reads it (`RevertNotes`, `NotesDifferForRevert`) and the F-44 QA round
  settled the Observação × Mensagem vocabulary at real cost. Likely v1 answer: **coexist**
  (agenda = structured events; observação = the free-text fallback), with replacement decided
  later on usage data. Either way, settle the WORDS first, in both languages — "Agenda" is a
  fourth vocabulary term next to Observação/Mensagem/Aviso.
- **Recurrence is the complexity cliff.** "Escola de tarde" is every weekday; a full
  recurrence engine (exceptions, edits-from-here) is enormous. Candidate v1: per-day rows
  only + a lightweight "routine template" applied forward (the rotation-wizard pattern the
  product already knows), explicitly NOT iCal RRULE.
- **Who writes**: any active caregiver, no two-party approval — the agenda is coordination,
  not custody: it must NEVER freeze a day, touch `actual_parent` or enter the swap workflow.
  Departed members (S-11) and viewers (F-50) never write. Whether only the day's responsible
  can edit that day is a product call, not a technical one.
- **Immutability**: does the agenda enter `activity_logs`? The court-admissible thesis says
  changes should be traceable, but event volume is high. Candidate: log create/delete, not
  every edit — decide explicitly.
- **Notifications**: which events notify whom, on which channel — F-38's e-mail quota exists
  because e-mail is scarce, and "remédio às 14h" is the strongest push case (F-09) in the
  product after the handoff itself. v1 candidate: in-app only, no e-mail.
- **Free vs premium**: the guiding principle keeps the safety/coordination core free; the
  agenda is group 6's monetization thesis. Decide the gate (or its absence) out loud.
- **Past days**: agenda rows on past days are corrections/records, not plans — the V008 day
  protections do NOT apply to them by design, but say so in the item.

**Implementation shape (sketch)**
- Tables: `children`, `child_events` (family + child FKs, `schedule_date`, optional time
  range, closed `type` key + optional free text through `NormalizeFreeText` — the F-44/F-52
  rule: the TYPE travels as a key and renders in the reader's language, free text stays as
  written). RLS family-scoped; realtime publication for the sheet; no interaction with the
  day-protection triggers.
- UI: U-25's sheet body → timeline component; child registration under Família.
- Tests: unit (timeline assembly, type catalogue parity PT/EN), integration (RLS cross-family,
  viewer/departed write refusal), E2E (create event → renders in sheet → other member sees it).

**Justification**
The strongest unprompted field signal yet for the hub direction: a tester demonstrated the
feature with another product's screen. It multiplies daily utility (the calendar answers
"who has the child"; the agenda answers "what does the child's day look like"), deepening the
habit the product's claim depends on — and it is the natural second wedge group 6 was created
to explore, now with demand evidence instead of speculation.

---

### F-56 — Solo mode: pending-member placeholder (invited, not yet joined)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium-high` — it is an ADOPTION blocker: the app is useless today to a parent whose ex refuses to join, and the closed alpha already surfaced exactly that profile |
| **Complexity** | `high` (touches the profile/auth birth invariant + several DB rules) |
| **Impact** | `high` (widens the addressable audience the same way the rebrand does) |
| **Roadmap** | Group 6, proposed Ordem 6 — candidate to move up (owner call): unlike the other group-6 modules it is not a wedge, it is an entry door |
| **Depends on / relates** | **F-15/F-28** (the invite flow it extends), **S-11** (the departure tombstone it mirrors), **F-37** (seat gate), **U-23** (onboarding step "convide o outro responsável" changes meaning), **F-55** (a solo parent building the child agenda alone is the natural pairing) |

> **Created 12/08/2026 from closed-alpha feedback (owner's synthesis).** The other parent may
> refuse the app out of conflict with the founder. Proposal: the founder issues the invitation
> and the invited-but-not-joined parent exists as a **placeholder** — *"tipo um tombstone, mas
> diferente desse tombstone de saída: de um responsável que ainda não entrou"* — so the founder
> plans the whole calendar (their days AND the other parent's), fills the child agenda, uses
> everything EXCEPT the swap workflow, which requires an active counterpart. When the other
> parent finally joins, the ready-made calendar is what greets them — and swaps unlock.

**Description**
A third member state, `pending` (invited, never signed in), alongside active and departed
(S-11). A pending member has name, role and colour, **is assignable as `scheduled_parent`**
(the whole point — S-11's frozen state is exactly the opposite), appears in the calendar and
reports, but: cannot be the counterpart of a swap/revert (nothing to approve with — the
two-party workflow simply stays unavailable on their days and the UI says why), receives no
notifications beyond the invite itself, holds no admin bit. On claim, the existing invite flow
(`register-invitee`) attaches the new auth user to the SAME member identity — every day ever
assigned to the placeholder survives as theirs.

**Design questions to settle before coding**
- **The profile-birth invariant is the technical crux.** Today a `profiles` row is born from
  sign-up (id = auth uid). A placeholder needs a profile with NO auth user yet, claimed later
  — either a nullable auth link stamped by `register-invitee`, or an id migration at claim.
  Decide with RLS in mind (`get_my_family_id()` paths must treat pending rows as family data).
- **The LGPD promise is currently the OPPOSITE of this feature.** The invite e-mail (and the
  privacy policy behind it) says the invitee's name/e-mail are stored under legitimate
  interest and **"expurgado em até 30 dias"** if the invite is not accepted. A long-lived
  placeholder holding a non-user's personal data indefinitely contradicts that sentence — this
  is S-15 territory: the legal text and the code must be changed TOGETHER, and storing a
  non-user's data indefinitely is likely a **material** change (PolicyVersions bump + the
  whole B-4 machinery). Cheapest honest design: the placeholder keeps only what the FOUNDER
  authored (name/role/colour — his description of his own family), and the invitee's E-MAIL
  is kept only while a live invitation exists (re-issuable); the 30-day purge then remains
  true for the e-mail, and the placeholder is founder-content, not invitee data. Settle this
  with the legal pages open.
- **Invite lifetime vs placeholder lifetime**: invites expire in 7 days; the placeholder must
  survive expiry and allow re-sending without losing identity/days.
- **Seats/gates**: a pending member consumes a caregiver seat and a colour (F-37 honest).
- **Auto-approval (T-45/F-47)**: N/A by construction — no swap can exist against a pending
  member; assert that in tests rather than assuming it.
- **U-23 onboarding**: the "invite the other responsible" step completes on invite SENT (the
  solo path), not on joined — copy changes in both languages.

**Justification**
The alpha showed the real adoption sequence: one motivated parent arrives first, the other is
skeptical or hostile. Today that first parent hits a wall; with this, they get full planning
value alone, and the eventual join lands the other parent in a working, populated product —
the strongest invite the app can make. Every workflow invariant (two-party approval, scenario
C prohibition) survives untouched because the pending member simply cannot be a workflow party.

---

### F-57 — Social login (Google now, Apple with the iOS wrapper)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `high` — owner 12/08/2026: *"creio que possa ser implementado o quanto antes"*; it removes the sign-up friction the closed alpha is living right now |
| **Complexity** | `medium` (GoTrue does the heavy lifting; the edges are ours) |
| **Impact** | `high` (first-contact conversion + fewer auth e-mails to lose) |
| **Roadmap** | Group 4 (distribution), proposed Ordem 2 — right after F-54, while the GoTrue URL config is fresh |
| **Depends on / relates** | **S-13/S-15** (consent must be collected on first OAuth login — the sign-up form does it today), **U-21** (the Segurança group must show the login method), **T-47/T-40** (the App Store REQUIRES Sign in with Apple once ANY third-party login exists — the Apple half is a hard prerequisite of the iOS wrapper), **F-15/F-28** (invite claim via OAuth) |

> **Created 12/08/2026 from closed-alpha feedback.** Social login (Google and Apple) to make
> account creation instant and prefill identity details.

**Description — phased on purpose**
**Phase 1: Google** (free — a GCP OAuth client + Supabase provider config on both projects).
Login/sign-up buttons on the auth screens; GoTrue redirect flow; e-mail arrives verified, so
the confirmation e-mail (and its failure modes) disappears for these users; name prefilled
from the Google profile. **Phase 2: Apple**, deliberately coupled to **T-47/T-40**: it
requires the US$ 99/yr Apple Developer account (owner spend, group-8 spirit) AND becomes
*mandatory* the moment the iOS wrapper ships with any social login present — so it lands with
the iOS work, not before.

**Design questions / edges (the analysis step)**
- **Consent gate**: OAuth sign-up bypasses our registration form, where S-13 consent is
  collected today — first OAuth login must route through the acceptance screen BEFORE the app
  (PolicyVersions machinery already exists; wire, don't rebuild).
- **Invite claim via Google**: `register-invitee` creates a password user today — an invitee
  tapping "Criar minha conta" must be able to choose Google and still land attached to the
  invitation (same member identity, F-56 later relies on this too).
- **Account linking**: same e-mail arriving via password AND via Google — decide GoTrue's
  linking posture explicitly, don't inherit a default silently.
- **Password-less profiles**: U-21's Segurança group shows "change password" — must show the
  login method instead; password recovery is N/A for OAuth-only users.
- **AuthService gotchas**: the redirect return runs the session-restore path — the spurious
  `SignedOut` guards (`_isRestoring`/`_isSigningUp`) are exactly the code being touched; the
  `forceLoad` DI-scope invariant on login/logout applies unchanged.
- **Owner ops runbook**: GCP consent screen + OAuth client, Supabase provider config dev AND
  prod (secrets exist before CI redeploys — the S-16 ordering trap), redirect URLs already
  fresh from F-54.

**Justification**
Every closed-alpha tester walked the password + confirmation-e-mail path — the single most
failure-prone flow the product has (the whole 07/08 QA round was auth e-mails). Google login
removes it for most of Brazil's user base at near-zero infra cost, and doing it right after
F-54 reuses the same GoTrue/config territory while it is warm.
