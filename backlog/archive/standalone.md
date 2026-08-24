# Archive — Standalone items (completed outside the phase plan)

Items delivered before the phase roadmap existed (v1.0.0–1.3.0 era) or opportunistically alongside other work.

---

### F-01 — Delete / Clear a day (single-day sheet)

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `high` |

**Description**
Added a "Limpar dia" button to the single-day bottom-sheet editor in `Home.razor`. The button is only visible when `selectedSchedule != null` (i.e. the day already has an existing record). It calls `CustodyService.DeleteScheduleAsync`, clears `selectedDate`, and refreshes the calendar.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — "Limpar dia" button, `DeleteSelectedDay` handler, `.btn-delete-day` and `.panel-actions-secondary` CSS

---

### F-02 — Show field-level diff in audit timeline

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Description**
The `activity_logs` table already stores `old_data` and `new_data` as JSONB but `ReportsAudit.razor` only showed *"atualizou as informações"*. `AuditService.ComputeDiff` now parses those JSON blobs, diffs `scheduled_parent_id`, `actual_parent_id`, `handoff_time`, and `notes`, resolves parent IDs to names, and returns a list of `AuditFieldChange` records. `ReportsAudit.razor` renders each change as a labelled before/after row inside the timeline card. The badge also now handles DELETE actions.

**Justification**
The audit log is one of the core features of the app

**Files affected**
- `SharedParentalCustody/Services/AuditService.cs` — deserialise `OldData`/`NewData`, compute diff
- `SharedParentalCustody/Models/ActivityLog.cs` — change `OldData`/`NewData` from `object?` to `JsonElement?` or a typed DTO
- `SharedParentalCustody/Pages/ReportsAudit.razor` — render diff lines in timeline card

---

### F-04 — Bulk range assignment

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `high` |
| **Impact** | `high` |

**Description**
Adds long-press-to-select multi-day bulk editing to the calendar. Long-pressing any day cell for 500 ms enters selection mode (with haptic feedback on mobile and context-menu suppression for iOS Safari). While in selection mode, single-tapping a day toggles its selection on/off; selected days display a corner check mark and a dark outline ring. A persistent action bar slides over the bottom navigation showing the count of selected days, an "Editar selecionados" button, and a "Cancelar" button.

Opening the bulk sheet pre-fills each field with the common value across all selected days, or leaves it blank if the days differ. Save semantics per field: a value present always overwrites all selected days; a blank field with its **Limpar** checkbox checked clears that field on all days; a blank field with its checkbox unchecked leaves the existing value on each day unchanged. The **Limpar** checkbox is automatically disabled (and visually greyed) whenever the field has a value. The Scheduled Parent field is mandatory — all other fields are disabled until it is set. Selecting "Apagar dias" on the Scheduled Parent triggers a confirmation alert before deleting all schedule records for the selected days. Month navigation and tab/menu navigation while days are selected trigger a confirmation dialog before discarding the selection.

**Justification**
First-time setup of a month requires 28–31 individual taps. This friction makes the app impractical to set up, especially on mobile. The long-press paradigm is a natural mobile gesture (familiar from iOS/Android photo selection) that adds bulk capability without cluttering the normal single-day editing flow.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — selection state, `LongPressDay` JSInvokable, `HandleDayClick`, `ToggleDaySelection`, `CancelSelection`, `OpenBulkSheet`, `SaveBulkChanges`, `DeleteScheduleAsync` calls, navigation guard (`RegisterLocationChangingHandler`), bulk bottom sheet markup, selection action bar markup, nav-guard dialog markup, all new CSS
- `SharedParentalCustody/Services/CustodyService.cs` — add `DeleteScheduleAsync(long id)`
- `SharedParentalCustody/wwwroot/js/swipe.js` — add `registerLongPress` / `unregisterLongPress` (pointer events, hold timer, haptic feedback, context-menu suppression, capture-phase click suppressor)

---

### F-06 — PWA install nudge

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
Adds a robust, persistent install nudge that works across Chrome/Edge (Android + desktop) and iOS Safari. The `beforeinstallprompt` event is captured in an inline `<head>` script before Blazor loads, so the event is never missed regardless of how long the framework takes to initialise. A dismissable banner slides up above the bottom navigation when the app is not yet installed: on Chrome/Edge it shows an "Instalar" button that triggers the native dialog; on iOS Safari it shows manual instructions ("Toque em Compartilhar → Adicionar à Tela de Início"). Dismissal is stored in `localStorage` with a 14-day snooze that resets automatically on expiry. The snooze is cleared immediately when the `appinstalled` event fires. The manifest was also fixed: `scope` added, icon `purpose: "any"` added, and icons reordered 192 first (required by Chrome's installability checklist).

**Justification**
The app is designed for mobile use. A large portion of users who benefit most from installation will not discover the browser's native install mechanism on their own. The previous implementation had no `beforeinstallprompt` capture at all, which is why the install prompt disappeared after the first session.

**Files affected**
- `SharedParentalCustody/wwwroot/index.html` — early `beforeinstallprompt` + `appinstalled` capture, iOS meta tags (`apple-mobile-web-app-capable/title/status-bar-style`), `theme-color` meta
- `SharedParentalCustody/wwwroot/manifest.webmanifest` — add `scope`, add `purpose: "any"` to both icons, reorder icons
- `SharedParentalCustody/wwwroot/js/pwa.js` — new module: `getInstallState`, `promptInstall`, `dismissInstall`, 14-day snooze logic
- `SharedParentalCustody/Layout/MainLayout.razor` — `IAsyncDisposable`, `OnAfterRenderAsync` reads install state, banner markup for both Chrome and iOS variants, `HandleInstall`, `HandleDismiss`, banner CSS

---

### F-10 — Day-swap approval workflow with revert confirmation and urgency alerts

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `high` |
| **Impact** | `high` |

**Description**
Full two-party approval workflow for custody day swaps, revert requests, and urgent-alert handling.

**Swap workflow**
When one parent changes the actual responsible for a future day to the other parent, a `pending` swap request is created instead of a direct calendar write. The day is frozen — no further edits while pending. Both parties are notified in-app (Supabase Realtime badge + Notifications page) and by email (Resend Edge Function). The calendar is updated only upon approval. Rejection leaves the calendar unchanged and optionally includes a reason. The requester can cancel a pending request.

The approver is always the party who is **not** the requester:
- If the requester is the designated parent → the other parent must approve.
- If the requester is not the designated parent (they are requesting a day for themselves) → the designated parent must approve.

**Revert workflow**
When a swap has been approved and either parent wants to revert to the original designated parent, a `revert_pending` request is created. The approver is again the non-requester:
- If the designated parent requests the revert → the previously-approved parent must confirm.
- If the previously-approved parent requests the revert → the designated parent must confirm.

The calendar is only restored to its original state upon confirmation. Rejection or cancellation leaves the swap active.

**Urgency alerts**
If a swap or revert request is created with less than 24 hours until the scheduled handoff time (using the actual handoff time stored on the schedule, not midnight), the request is flagged `is_urgent = true`. Urgent requests receive:
- A `⚠️ URGENTE:` prefix on all in-app notification titles.
- An amber ⚠️ banner at the top of the frozen-day panel and Notifications cards.
- A `[URGENTE]` prefix in email subjects and an amber HTML banner inside the email body.

> **Superseded by F-20 (July 2026):** the stored `is_urgent` boolean was dropped (V010); urgency is now a dynamic priority tag (`urgent`/`overdue`) computed from the handoff time at display/send time. The visual treatment above still applies, plus the red ⏰ ATRASADO state.

> **Post-release fix (July 2026):** the request/approval message texts assumed scenario A ("solicitou que você fique responsável") and inverted the meaning when the requester proposed **themselves** on the target's day (scenario B). Fixed with a `targetIsProposed` branch in `SwapRequestService` and in the `templateRequested`/`templateApprovedForRequester` e-mail templates. The N-caregiver generalization (explicit names in every text) is scoped in **F-28**.

**Calendar UX**
Frozen days display two distinct visual states directly on the calendar cell:
- 🔔 amber pulsing border + animated bell icon → **action required by this user** (they are the target/approver).
- ⏳ dimmed hourglass → **waiting for the other parent** (no action needed from this user).

**Notifications page (3 tabs)**
- *Para você* — pending swap and revert requests awaiting the current user's decision, with approve/reject/cancel buttons and an optional rejection-reason field.
- *Enviadas* — requests sent by the current user, with a cancel option for `pending` and `revert_pending` requests.
- *Histórico* — full chronological notification history.

**Email templates (PT-BR, Resend via Edge Function)**
- `swap_requested` — new swap request (shown to approver)
- `approved` — swap approved (shown to requester)
- `rejected` — swap rejected with optional reason (shown to requester)
- `cancelled` — request cancelled (shown to approver)
- `revert_requested` — new revert request (shown to approver)
- `revert_approved` — revert confirmed (shown to requester)
- `revert_rejected` — revert refused (shown to requester)
- `revert_cancelled` — revert request cancelled (shown to approver)

All templates include the handoff time when set, and show an urgent banner when `isUrgent` is `true`.

**Database migrations**
- `V002__swap_requests.pgsql` — `swap_requests` and `notifications` tables, RLS, grants, partial unique index (one `pending` per day).
- `V003__revert_workflow.pgsql` — adds `is_urgent` column, widens status constraint to include the four revert statuses, and extends the partial unique index to block concurrent `revert_pending` + `pending` on the same day.

**Files affected**
- `database/migrations/V002__swap_requests.pgsql` — swap_requests and notifications schema
- `database/migrations/V003__revert_workflow.pgsql` — is_urgent, revert statuses, index update
- `SharedParentalCustody/Models/SwapRequest.cs` — Postgrest model (`IsUrgent`, all fields)
- `SharedParentalCustody/Models/AppNotification.cs` — Postgrest model for notifications
- `SharedParentalCustody/Services/SwapRequestService.cs` — all workflow logic: `CreateSwapRequestAsync`, `ApproveAsync`, `RejectAsync`, `CancelAsync`, `RequestRevertAsync`, `ApproveRevertAsync`, `RejectRevertAsync`, `CancelRevertAsync`, `ShouldTriggerWorkflow`, `ShouldRequestRevert`, `IsUrgentRequest`, email and notification dispatch
- `SharedParentalCustody/Services/NotificationService.cs` — badge count, Realtime subscription, mark-read
- `SharedParentalCustody/Pages/Home.razor` — dual frozen-day badge (🔔 vs ⏳), frozen-day panel with revert/swap distinction, workflow detection in `SaveChanges`, bulk-save block
- `SharedParentalCustody/Pages/Notifications.razor` — new page (three tabs), all action methods
- `SharedParentalCustody/Layout/MainLayout.razor` — Realtime init, unread-count `CascadingValue`, PWA install banner
- `supabase/functions/send-swap-email/index.ts` — Resend Edge Function (8 PT-BR templates, urgency support, handoff-time display)
- `SharedParentalCustody/Program.cs` — `SwapRequestService` and `NotificationService` registered

---

### U-08 — Add notifications entry and unread badge to navigation

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
`Notifications.razor` and `NotificationService` are implemented, and `MainLayout.razor` now coordinates the badge refresh cycle. `NavMenu.razor` exposes a navigation entry to `/notifications` in both the desktop top bar and the mobile bottom navigation, and displays the badge using the existing `UnreadCount` cascading parameter and `.bell-badge` styles. The badge value is aligned with the *Para você* tab by counting pending requests awaiting the current user's action rather than generic unread history items.

**Justification**
The workflow is implemented and now discoverable from the primary app navigation. This removes the previous UX gap between the existing notifications workflow and the visible navigation affordances, while keeping the badge meaningful by showing actionable pending items and refreshing on load/navigation.

**Files affected**
- `SharedParentalCustody/Layout/NavMenu.razor` — add Notifications nav item and unread badge markup
- `SharedParentalCustody/Layout/MainLayout.razor` — refresh badge on load, route changes, and realtime updates
- `SharedParentalCustody/Services/NotificationService.cs` — badge refresh event used by layout/pages
- `SharedParentalCustody/Pages/Home.razor` — request badge refresh when opening Calendar
- `SharedParentalCustody/Pages/Notifications.razor` — request badge refresh when opening Notifications

---

### U-09 — Move Login.razor inline styles to `.razor.css` sibling file

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `low` |
| **Complexity** | `low` |
| **Impact** | `low` |

**Description**
T-05 extracted inline styles from Home, ReportsSummary, and ReportsAudit into `.razor.css` files, but `Login.razor` was missed at the time — it still carried a large embedded `<style>` block. The extraction ended up delivered along the later Login-page work: **verified July 2026** (Phase 3 backlog audit), `Login.razor` contains no `<style>` block and `Login.razor.css` holds all the page styles (F-15/F-19 changes were made directly there).

**Justification**
Pure consistency cleanup. Zero runtime behaviour change. Was previously marked `skipped`; corrected to `completed` since the described end state is factually in place — which also unblocks U-12 (dark mode) without prerequisites.

**Files affected**
- `SharedParentalCustody/Pages/Login.razor` — no `<style>` block
- `SharedParentalCustody/Pages/Login.razor.css` — page styles (single source)

---

### T-05 — Move component styles to `.razor.css` sibling files

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
`Home.razor`, `ReportsSummary.razor`, and `ReportsAudit.razor` now use sibling CSS isolation files instead of embedded `<style>` blocks. The extracted styles were moved to `Home.razor.css`, `ReportsSummary.razor.css`, and `ReportsAudit.razor.css`, aligning those pages with the existing layout convention already used elsewhere in the app.

Implementation note: the refactor was a straight extraction with no required `::deep` selectors, which means the current page styles are self-contained and isolation-friendly. Future component extraction from these pages should preserve that approach and introduce `::deep` only when styling nested child-component markup becomes necessary.

**Justification**
Embedded styles make the `.razor` files hard to navigate and edit. The split is purely structural with zero runtime behaviour change, and it aligns the three main pages with the existing convention already used in the Layout folder.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — remove `<style>` block
- `SharedParentalCustody/Pages/Home.razor.css` — new file with extracted styles
- `SharedParentalCustody/Pages/ReportsSummary.razor` — remove `<style>` block
- `SharedParentalCustody/Pages/ReportsSummary.razor.css` — new file
- `SharedParentalCustody/Pages/ReportsAudit.razor` — remove `<style>` block
- `SharedParentalCustody/Pages/ReportsAudit.razor.css` — new file

---

### T-10 — Audit log recent-first pagination

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
The audit history page defaulted to loading an entire year at once, causing slow initial load times and unnecessary database calls. A dedicated `GetRecentAuditLogsAsync(int offset = 0)` method was added to `AuditService` that queries Supabase with server-side `ORDER BY created_at DESC LIMIT 20 OFFSET n`. `ReportsAudit.razor` now defaults to a new `Recentes` filter mode that loads only the 20 most recent entries on first render, with a `Carregar mais` button for incremental loading. The existing month/year range modes are preserved unchanged.

**Justification**
In practice, users check the audit log to review what was changed recently, not to browse the full history. Loading a whole year by default penalised the common case. The recent-first approach eliminates unnecessary round trips and keeps the initial render fast on low-bandwidth connections.

**Files affected**
- `SharedParentalCustody/Services/AuditService.cs` — add `PageSize = 20` constant and `GetRecentAuditLogsAsync(int offset)`
- `SharedParentalCustody/Pages/ReportsAudit.razor` — add `recent` filter mode, incremental load-more, CSS for load-more button and inline spinner
