# Archive — Phase 2: Core UX & Reliability (completed)

Implementation records of the items delivered in Phase 2. Immutable history — new work never goes here.

---

### F-03 — Forgot password / password reset

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `high` |

**Description**
Added a "Esqueci minha senha" link below the login form that navigates to `/reset-password`. That page accepts an email, calls `AuthService.SendPasswordResetAsync` (which wraps `supabase.Auth.ResetPasswordForEmail`), and shows a success confirmation regardless of whether the email exists (to avoid user enumeration).

**Files affected**
- `SharedParentalCustody/Services/AuthService.cs` — added `SendPasswordResetAsync(string email)`
- `SharedParentalCustody/Pages/Login.razor` — added "Esqueci minha senha" link
- `SharedParentalCustody/Pages/ResetPassword.razor` — new page

---

### F-19 — Session expiry warning banner

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
When `AutoRefreshToken` fails (e.g. user offline for hours, refresh token expired), the T-04 listener redirects to `/login` silently. The user loses context without understanding why. Add a dismissable warning banner ("Sua sessão expirou. Faça login novamente.") on the login page when the redirect was caused by a session expiry rather than an intentional sign-out. Store a flag in `sessionStorage` before redirecting so the login page can detect the reason.

**Justification**
Silent redirects to login create confusion — the user doesn't know if the app crashed or their session expired. A clear message sets the right expectation and prompts re-authentication without alarm.

**Files affected**
- `SharedParentalCustody/Services/AuthService.cs` — set sessionStorage flag before redirect on `SignedOut`
- `SharedParentalCustody/Pages/Login.razor` — detect flag and show expiry banner

---

### F-21 — Add [Dev] environment tag to notifications in non-production environments

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `low` |
| **Complexity** | `low` |
| **Impact** | `low` |

**Description**
When the application is running in a development/test environment (`AppEnvironment != "Production"` or `AppEnvironment == "Development"`), all notification titles — both in-app and email — should be prefixed with `[Dev]`. This allows developers who share an email inbox between environments to immediately distinguish test notifications from real ones.

**Rules:**
- In-app notification titles: prefix with `[Dev]` when environment is not production.
- Email subjects: prefix with `[Dev]` (passed to the Edge Function as a parameter).
- Production: no environment tag is ever added.

**Files affected**
- `SharedParentalCustody/Services/SwapRequestService.cs` — prefix notification titles with `[Dev]` based on config
- `supabase/functions/send-swap-email/index.ts` — accept and apply environment prefix in email subjects
- `SharedParentalCustody/Program.cs` or `IConfiguration` injection — expose environment name to the service

---

### U-03 — Fix mobile overflow issues in editor and calendar

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `high` |

**Description**
Fixed two overflow issues on mobile:
1. Added `overflow-y: auto; max-height: 85dvh` to `.bottom-sheet` so the schedule editor scrolls internally on short viewports instead of clipping content.
2. Added `overflow-x: hidden` to `.calendar-app` and changed `grid-template-columns` from `repeat(7, 1fr)` to `repeat(7, minmax(0, 1fr))` on both `.weekdays-grid` and `.days-grid`, preventing cell content from expanding columns beyond viewport width on narrow screens (iPhone).

**Files affected**
- `SharedParentalCustody/Pages/Home.razor.css` — `.bottom-sheet` overflow/max-height, `.calendar-app` overflow-x, grid column constraint

---

### U-04 — No first-use guidance / empty state on calendar

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
Added an empty-state overlay below the calendar grid when `monthlySchedules` is empty for the current month. Shows a 📅 icon, "Nenhum dia agendado neste mês" title, and a hint "Toque em um dia para atribuir o responsável pela guarda." This provides first-use guidance for new users.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — empty-state block inside the days-grid section
- `SharedParentalCustody/Pages/Home.razor.css` — `.calendar-empty-state` styles

---

### U-05 — Audit timeline badge too small for touch

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
The rendered timeline badge circle is `20 × 20 px` with an 11 px icon — well below the 44 px minimum recommended touch target. The skeleton loader already uses `36 × 36 px` for the same element. Align the rendered badge with the skeleton: `width: 36px; height: 36px; font-size: 16px`.

**Justification**
Small touch targets cause mis-taps and a perception of poor quality. The inconsistency between the skeleton size (36 px) and the rendered size (20 px) also causes a visible layout shift when the skeleton is replaced by content.

**Files affected**
- `SharedParentalCustody/Pages/ReportsAudit.razor` — update `.timeline-badge` CSS rule

---

### U-06 — Today card improvements

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
The today card has improved a lot, but it still has room for small UX refinements that make the current day feel more polished and easier to scan. Group the remaining ideas under one shared item instead of spreading them across multiple micro-tasks.

Suggested improvements:
- show the abbreviated weekday in the next handoff widget, e.g. `Sex, 04/07 · em 2 dias`
- review whether the next handoff block should visually react more clearly to urgency (today / tomorrow / soon)
- consider a clearer distinction between "your role" and "today's responsible parent" when both differ
- revisit mobile spacing and wrapping for longer parent names or translated labels
- evaluate whether the today card should expose a small secondary hint for frozen / swapped days when relevant

**Justification**
These are minor enhancements rather than structural problems, but together they can make the most visited area of the app feel calmer, clearer, and more intentional. Keeping them in one backlog item makes it easier to refine the card incrementally without cluttering the roadmap.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — adjust today card markup, helper formatting, and contextual hints as needed
- `SharedParentalCustody/Pages/Home.razor.css` — refine visual hierarchy, spacing, urgency cues, and responsive behavior

---

### U-10 — Add loading/splash screen during initial WASM download

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `high` |

**Description**
Replaced the default Blazor SVG loading circle with a branded splash screen inside `<div id="app">`: app icon (📅), app name ("Guarda Compartilhada"), and a CSS spinner. Inline styles in `<head>` ensure the splash renders instantly before any external CSS loads. Blazor natively replaces the `#app` content once it boots.

**Files affected**
- `SharedParentalCustody/wwwroot/index.html` — loading markup inside `#app` + inline CSS in `<head>`

---

### U-14 — Add confirmation/success toast on save and workflow actions

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
Added a `ToastService` (scoped) and global UI in `MainLayout`: a slim animated progress bar at the top of the screen during in-flight operations (`StartProgress`), and an auto-dismissing toast notification (3 seconds) after completion (`ShowSuccess`/`ShowError`/`ShowInfo`). Triggers added to all mutation paths in `Home.razor` (save, delete, bulk save, all 6 swap actions) and `Notifications.razor` (all 6 action methods). The toast uses `aria-live="polite"` for accessibility.

For bulk operations, the toast shows "Edição em lote concluída". A future enhancement (noted in the description) should include counts of skipped days.

**Files affected**
- `SharedParentalCustody/Services/ToastService.cs` — new service
- `SharedParentalCustody/Program.cs` — register `ToastService`
- `SharedParentalCustody/Layout/MainLayout.razor` — toast + progress bar markup, subscription
- `SharedParentalCustody/Pages/Home.razor` — trigger toast/progress in all mutation methods
- `SharedParentalCustody/Pages/Notifications.razor` — trigger toast/progress in all action methods

---

### U-15 — Show read-only indicator when day editor is protection-locked

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
Added a conditional amber banner inside the bottom-sheet day editor that appears when the selected day is past ("🔒 Dia passado — apenas visualização") or frozen by a pending request ("🔒 Solicitação pendente — edição bloqueada"). The banner communicates the restriction proactively.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — conditional banner markup
- `SharedParentalCustody/Pages/Home.razor.css` — `.readonly-banner` styles

---

### U-16 — Display timestamps in user's local timezone

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
Swap request creation times, notification timestamps, and audit log entries are stored as UTC in the database but displayed as-is without conversion to the user's local timezone. In Brazil (UTC-3), this causes all times to appear 3 hours earlier than expected. Convert all displayed timestamps to local time using `DateTime.ToLocalTime()` or by detecting the user's timezone offset via JS interop.

**Justification**
Showing UTC times in a family app causes confusion — a swap request created "now" appears to have been created 3 hours ago. This erodes trust in the timeline and can cause misunderstandings between parents.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — frozen panel timestamp display
- `SharedParentalCustody/Pages/Notifications.razor` — notification timestamp display
- `SharedParentalCustody/Pages/ReportsAudit.razor` — audit log timestamp display

---

### T-02 — Disable Supabase Realtime or subscribe meaningfully

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Description**
Applied **Option A (quick fix)**: set `AutoConnectRealtime = false` in `Program.cs` to stop the unnecessary WebSocket connection that consumed Supabase Realtime quota without any subscriptions. Option B (meaningful subscription for live calendar sync) has been extracted into a separate feature item (F-23) for a future phase.

**Files affected**
- `SharedParentalCustody/Program.cs` — set `AutoConnectRealtime = false`

---

### T-03 — Fix unbounded query in `GetNextHandoffDateAsync`

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
Added an upper bound (`searchFrom.AddDays(90)`) and server-side `ORDER BY schedule_date ASC` to `GetNextHandoffDateAsync`. The query no longer fetches the entire future schedule — it retrieves at most 90 days of data, ordered by date, and iterates to find the first handoff to a different parent.

**Files affected**
- `SharedParentalCustody/Services/CustodyService.cs` — upper-bound filter + server-side ordering

---

### T-15 — Remove `dump.sql` from source control

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `low` |
| **Complexity** | `low` |
| **Impact** | `low` |

**Description**
The file `SharedParentalCustody/dump.sql` (12 KB) is committed to the repository. It contains a full database schema and potentially seed data. If it ever contained production data (parent names, schedule history), it would be a data leak. Remove it from the tracked files and add `*.sql` at the project root (or specifically `dump.sql`) to `.gitignore`. The proper schema reference lives in `database/migrations/`.

**Justification**
A committed SQL dump is a common source of accidental PII exposure. Even if the current contents are safe, the pattern invites future mistakes. The migrations folder already serves as the schema source of truth.

**Files affected**
- `SharedParentalCustody/dump.sql` — delete from git tracking
- `.gitignore` — add exclusion rule for root-level dumps

---

### T-17 — Add test step to CI/CD pipeline

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
The `deploy.yml` GitHub Actions workflow compiles and publishes directly without running any tests. When T-08 (unit test project) is implemented, the pipeline will still not run them unless a `dotnet test` step is added. Add a test step between build and publish that runs `dotnet test` and fails the pipeline on test failure. Even before T-08 is complete, adding the step with `--no-build` is harmless (zero test projects = zero failures).

**Justification**
A CI pipeline that does not run tests provides no quality gate. Changes that break existing logic will deploy to production without any automated check. This is the prerequisite for any test-driven confidence in the deployment process.

**Files affected**
- `.github/workflows/deploy.yml` — add `dotnet test` step after build

---

### T-20 — Improve session restoration reliability for deep links

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Description**
Addressed in Phase 1.3 with the following implementation:
- `LocalStorageSessionHandler` persists sessions to localStorage via synchronous `IJSInProcessRuntime`.
- `Program.cs` calls `AuthService.RestoreSessionAsync()` before `host.RunAsync()`, ensuring the Supabase client has the auth token attached before any component renders.
- `AuthService.IsAuthenticated` checks both `CurrentUser` and `LoadSession()` as fallback.
- `MainLayout.OnInitialized` (sync) auth guard runs after session restoration.

**Known remaining limitation:** The Supabase .NET SDK v1.1.1's `SetSession` does not always populate `CurrentUser` synchronously on the first page load. This manifests as a brief moment where `CurrentUser` is null despite a valid session in localStorage. A future SDK upgrade (T-22) may resolve this by providing a more reliable session restore API.

**Files affected**
- `SharedParentalCustody/Services/LocalStorageSessionHandler.cs`
- `SharedParentalCustody/Services/AuthService.cs` — `RestoreSessionAsync`, `IsAuthenticated` fallback
- `SharedParentalCustody/Program.cs` — startup session restoration

---

### T-21 — Add `.gitattributes` rule for consistent line endings

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `low` |
| **Complexity** | `low` |
| **Impact** | `low` |

**Description**
Every git commit produces CRLF-to-LF warnings because the repository has no explicit `.gitattributes` line-ending configuration. Add `* text=auto` to normalize line endings and eliminate the warnings across Windows/WSL/macOS development environments.

**Justification**
Pure housekeeping. The warnings are harmless but noisy and can mask real issues in commit output.

**Files affected**
- `.gitattributes` — add `* text=auto` rule

---

### T-23 — Extract inline `<style>` blocks to `.razor.css` sibling files (MainLayout, Login, Notifications)

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
Three files still contain large embedded `<style>` blocks that violate the convention established by T-05: `MainLayout.razor` (~233 lines, partially extracted), `Login.razor` (~180 lines, tracked as U-09), and `Notifications.razor` (~303 lines). Extract all three to their corresponding `.razor.css` sibling files. `MainLayout.razor.css` already exists with 77 lines — merge the remaining inline styles into it.

This item supersedes U-09 (which only covered Login.razor) and expands the scope to all remaining files.

**Justification**
Phase 3 adds complexity to `Home.razor` and the workflow pages. Large inline style blocks make files harder to navigate, prevent IDE CSS tooling from working correctly, and create inconsistency with the rest of the codebase.

**Files affected**
- `SharedParentalCustody/Layout/MainLayout.razor` — remove inline `<style>` block, merge into `MainLayout.razor.css`
- `SharedParentalCustody/Pages/Login.razor` — remove `<style>`, create `Login.razor.css`
- `SharedParentalCustody/Pages/Notifications.razor` — remove `<style>`, create `Notifications.razor.css`

---

### T-24 — Extract components from Home.razor to reduce file size

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Description**
Extracted pure helper methods (`GetDaysUntil`, `FormatHandoffDate`, `GetHandoffUrgencyClass`, `GetDayCssClass`, `GetParentInitial`) into a static `Helpers/CalendarHelpers.cs` class. Home.razor now delegates to these via one-line wrappers. This makes the logic unit-testable without bUnit and establishes the pattern for further extraction.

Component extraction (TodayCard.razor, FrozenDayPanel.razor) was evaluated but deferred to T-26 — the markup is too tightly coupled to page state (10+ shared variables, 6 swap action handlers, selection mode interactions) for safe extraction without comprehensive test coverage or a feature change that restructures those sections.

**Files affected**
- `SharedParentalCustody/Helpers/CalendarHelpers.cs` — new static class with 5 extracted methods
- `SharedParentalCustody/Pages/Home.razor` — added `@using SharedParentalCustody.Helpers`, replaced method bodies with one-line delegations

---

### T-25 — Fix pre-existing CS8604 nullable warning in ReportsAudit.razor

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `low` |
| **Complexity** | `low` |
| **Impact** | `low` |

**Description**
Every build produces `CS8604: Possible null reference argument for parameter 'profiles' in AuditService.ComputeDiff`. The `profiles` variable passed at line 89 of `ReportsAudit.razor` can be null when the page renders before `LoadProfiles()` completes. Fix by passing `profiles ?? []` or guarding the call with a null check.

**Justification**
A zero-warning build baseline makes it immediately obvious when new code introduces problems. This single warning has persisted across every build since the audit diff feature was added.

**Files affected**
- `SharedParentalCustody/Pages/ReportsAudit.razor` — null-coalescing on the `profiles` argument

---

### S-01 — No brute-force protection or login attempt throttling on the client

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `high` |

**Description**
Added client-side throttling to the login form: after 3 failed attempts, a progressive delay activates (3rd fail = 15s, 4th = 20s); after 5 fails, a 60-second lockout with a visible countdown on the button ("Aguarde Ns"). The button is disabled during lockout. Additionally, `AuthService.SignInAsync` now detects 429 responses from Supabase GoTrue and surfaces a clear "Muitas tentativas" message instead of a generic error.

**Files affected**
- `SharedParentalCustody/Pages/Login.razor` — throttling state, lockout timer, countdown display
- `SharedParentalCustody/Services/AuthService.cs` — 429 rate-limit detection in `SignInAsync`

---

### S-04 — No session timeout or inactivity lock

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Description**
Once logged in, the session never expires on the client side unless the Supabase token refresh fails (which is itself not detected — see T-04). There is no inactivity timeout. If a parent leaves their phone unlocked, the other parent (or a child) can access and modify custody data indefinitely. Add an inactivity timer (e.g. 30 minutes without interaction) that prompts a re-authentication screen or auto-redirects to `/login`.

**Justification**
Custody data is sensitive — it may be used as legal evidence. An indefinitely open session on an unattended device is a realistic risk in a shared-household scenario. An inactivity lock is a common security control for applications handling personal/family data.

**Files affected**
- `SharedParentalCustody/Layout/MainLayout.razor` — track last interaction time, show lock screen or redirect
- Optionally `SharedParentalCustody/Pages/LockScreen.razor` — re-auth prompt without full logout
