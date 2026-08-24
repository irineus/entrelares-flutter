# Archive — Phase 1: Security & Critical Fixes (completed)

Implementation records of the items delivered in Phase 1. Immutable history — new work never goes here.

---

### F-12 — Prevent workflow bypass through clear/edit actions

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `critical` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Description**
Hardened the editing rules so users cannot use clear/edit operations to override workflow-controlled state:
- A day with a `pending` or `revert_pending` request cannot be cleared or directly edited — the "Limpar dia" button is hidden and `SaveChanges` returns an error message.
- A day with an already approved swap (`actual_parent_id != scheduled_parent_id`) cannot be cleared — the "Limpar dia" button is hidden. Admin override deferred to F-14.
- Bulk operations automatically skip frozen days and approved-swap days, showing clear feedback about which days were ineligible.
- Direct reassignment of the scheduled parent is deferred to F-05/F-14 (see notes in those entries).

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — helper properties (`IsClearDayBlocked`, `IsSaveDayBlocked`, etc.), guards in `SaveChanges`, `DeleteSelectedDay`, and `SaveBulkChanges`, conditional visibility on "Limpar dia" button

---

### F-13 — Block destructive and workflow actions on past days

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Description**
Past days are now immutable through normal user actions:
- The "Limpar dia" button is hidden for past days.
- `SaveChanges` blocks modifications to past days with a clear error message ("Dias passados não podem ser alterados.").
- Bulk operations automatically filter out past days from the selection set.
- **Exception:** Pending workflow requests on past days (approve/reject/cancel in the frozen panel) remain actionable so overdue workflows can be completed. The frozen panel is a separate UI path that is not affected by the past-day restriction.

**Files affected**
- `SharedParentalCustody/Pages/Home.razor` — `IsSelectedDayInPast` helper, guards in `SaveChanges`, `DeleteSelectedDay`, `SaveBulkChanges`

---

### U-01 — Fix hardcoded role labels and colours in Reports Summary

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `critical` |
| **Complexity** | `low` |
| **Impact** | `high` |

**Description**
Replaced the hardcoded "Pai"/"Mãe" card headings and `.father-card`/`.mother-card` CSS classes with a dynamic `@foreach` loop over all profiles. Each card now uses `role-N-card` CSS classes (matching the calendar's `role-N-day` colour slot system) and derives its heading from `ProfileService.TranslateRole`. The report automatically adapts to any number of roles with any names.

**Files affected**
- `SharedParentalCustody/Pages/ReportsSummary.razor` — dynamic loop, per-profile stats model
- `SharedParentalCustody/Pages/ReportsSummary.razor.css` — replaced `.father-card`/`.mother-card` with `.role-1-card` through `.role-4-card`

---

### U-02 — Fix fragile role string-matching in Reports Summary logic

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `critical` |
| **Complexity** | `low` |
| **Impact** | `high` |

**Description**
Replaced the string-matching logic (`"father"`, `"pai"`, `"mother"`, `"mãe"`) in `LoadReportData()` with a per-profile-id iteration. The method now computes `Planned` and `Actual` counts for every profile in `allProfiles` by matching on `profile.Id` directly. The `Actual` count also correctly uses `actual_parent_id` (falling back to `scheduled_parent_id`) instead of only counting scheduled days.

**Files affected**
- `SharedParentalCustody/Pages/ReportsSummary.razor` — `LoadReportData()` rewritten with profile-id iteration and `ProfileStats` model

---

### T-01 — Add `ErrorBoundary` to `MainLayout`

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `critical` |
| **Complexity** | `low` |
| **Impact** | `high` |

**Description**
Wrapped `@Body` in `MainLayout.razor` with `<ErrorBoundary>` providing a `<ChildContent>` / `<ErrorContent>` pair. The error fallback shows a friendly PT-BR message ("Algo deu errado") and a "Recarregar" button that calls `ErrorBoundary.Recover()`. Unhandled exceptions in any page now display this fallback instead of a blank screen.

**Files affected**
- `SharedParentalCustody/Layout/MainLayout.razor` — `<ErrorBoundary>` wrapping `@Body`, error fallback UI + CSS

---

### T-04 — Add auth state change listener to `AuthService`

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Description**
`AuthService` now subscribes to Supabase's `OnAuthStateChange` event. When the auth state transitions to `SignedOut` (e.g. token refresh fails silently mid-session), the service redirects to `/login` automatically via `NavigationManager`. Additionally, a `LocalStorageSessionHandler` persists the session to `localStorage`, enabling `AutoRefreshToken` to function correctly across page reloads.

**Files affected**
- `SharedParentalCustody/Services/AuthService.cs` — subscribes to `OnAuthStateChange`, redirects on session loss, implements `IDisposable`
- `SharedParentalCustody/Services/LocalStorageSessionHandler.cs` — enables session persistence for token refresh

---

### T-12 — Add error reporting / observability (Sentry or equivalent)

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Description**
Added `ErrorLoggingService` — a lightweight in-memory error logging service registered as a singleton. It captures up to 50 recent exceptions with timestamp, context label, exception type, message, and stack trace, and outputs structured messages to the browser console. All previously-empty `catch { }` blocks in `MainLayout.razor` now call `ErrorLogger.LogError(ex, context)`, and `AuthService` logs authentication failures through the same service. This provides immediate observability via browser DevTools and establishes the integration point for a future Sentry SDK.

**Files affected**
- `SharedParentalCustody/Services/ErrorLoggingService.cs` — new service
- `SharedParentalCustody/Program.cs` — register `ErrorLoggingService` as singleton
- `SharedParentalCustody/Layout/MainLayout.razor` — inject and use in all catch blocks
- `SharedParentalCustody/Services/AuthService.cs` — inject and log on auth failures

---

### T-16 — Add Content Security Policy (CSP) headers

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
Added a strict Content Security Policy to the `_headers` file: `default-src 'self'`; scripts restricted to `'self' 'unsafe-eval' 'wasm-unsafe-eval'` (required for .NET WASM); styles allow `'unsafe-inline'` (Blazor CSS isolation); connections whitelisted to `'self'` + `https://*.supabase.co` + `wss://*.supabase.co` (API + Realtime WebSocket); `frame-ancestors 'none'` prevents embedding. Any injected third-party script is blocked.

**Files affected**
- `SharedParentalCustody/wwwroot/_headers` — `Content-Security-Policy` directive

---

### S-02 — Auth guard is implemented per-page rather than centralized

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Description**
Replaced per-page manual `AuthService.IsAuthenticated` checks with a single centralized auth guard in `MainLayout.OnInitialized`. The layout checks `AuthService.IsAuthenticated` and the current URI — if the user is not authenticated and the route is not `/login`, they are immediately redirected. This single check protects all current and future pages without requiring any per-page boilerplate. A `LocalStorageSessionHandler` was also added so sessions persist across page reloads via the Supabase SDK's `IGotrueSessionPersistence` interface.

**Files affected**
- `SharedParentalCustody/Layout/MainLayout.razor` — centralized auth guard in `OnInitialized`
- `SharedParentalCustody/Services/LocalStorageSessionHandler.cs` — new session persistence via localStorage
- `SharedParentalCustody/Services/AuthService.cs` — removed per-page auth boilerplate; T-04 listener built-in
- `SharedParentalCustody/Program.cs` — registers `LocalStorageSessionHandler` and wires it into Supabase options
- `SharedParentalCustody/Pages/Home.razor`, `Notifications.razor`, `ReportsSummary.razor`, `ReportsAudit.razor` — removed redundant manual auth checks

---

### S-03 — Supabase GRANTS give `anon` role full table access

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `critical` |
| **Complexity** | `low` |
| **Impact** | `high` |

**Description**
The V001 and V002 migrations included `GRANT ALL ON public.<table> TO anon, authenticated, service_role` for every table and sequence. The `anon` role is used by unauthenticated requests (anyone with the public anon key). `V004__revoke_anon_and_enforce_swap_workflow.pgsql` revokes ALL privileges from `anon` on all six application tables, all six sequences, and the audit trigger function. Only `authenticated` and `service_role` retain access.

**Justification**
The anon key is publicly visible in the client bundle. Anyone can call the PostgREST API with this key. The only protection is RLS — but defense-in-depth dictates that `anon` should not even have the database-level `GRANT` to attempt queries on `care_schedules`, `activity_logs`, `swap_requests`, or `notifications`. Revoking grants from `anon` means an RLS misconfiguration or oversight cannot expose data to unauthenticated callers.

**Files affected**
- `database/migrations/V004__revoke_anon_and_enforce_swap_workflow.pgsql` — revokes all anon grants on production

---

### S-05 — Swap workflow authorization enforced only in the C# client layer

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |

**Description**
The RLS policy on `swap_requests` previously allowed UPDATE by either the requester or the target with `WITH CHECK (true)`, meaning either party could set any status. `V004__revoke_anon_and_enforce_swap_workflow.pgsql` replaces the permissive policy with two granular UPDATE policies (one for target, one for requester) and adds a `BEFORE UPDATE` trigger (`enforce_swap_status_transition`) that validates the state machine at the database level:
- `pending` → `approved`/`rejected` (target only), `cancelled` (requester only)
- `revert_pending` → `revert_approved`/`revert_rejected` (target only), `revert_cancelled` (requester only)
- Terminal statuses cannot transition.
- The trigger auto-sets `updated_at` and `resolved_at` server-side for consistency.

**Justification**
In a client-side SPA, the "service layer" is just a convenience wrapper. Any authenticated user can call the Supabase PostgREST endpoint directly and bypass the C# logic entirely. Without database-level enforcement, a technically savvy parent can approve their own swap requests, cancel the other parent's requests, or reopen resolved disputes. This undermines the entire trust model of the approval workflow.

**Files affected**
- `database/migrations/V004__revoke_anon_and_enforce_swap_workflow.pgsql` — drops permissive policy, creates granular UPDATE policies, and adds BEFORE UPDATE trigger for state machine enforcement

---

### S-07 — No HTTPS enforcement or HSTS header in deployment

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
Added `Strict-Transport-Security: max-age=31536000; includeSubDomains` to all routes via the `_headers` file. Also added `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, and `Permissions-Policy` restricting camera/microphone/geolocation.

**Files affected**
- `SharedParentalCustody/wwwroot/_headers` — security headers for all routes (`/*`)

---

### S-08 — Sensitive error details exposed to the user

| Field | Value |
|---|---|
| **Status** | `completed` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `low` |

**Description**
`AuthService.SignInAsync` no longer exposes raw exception messages to the user. The generic `catch (Exception)` now returns a static "Falha na conexão com o servidor. Verifique sua internet e tente novamente." and the `TranslateGotrueError` fallback returns "Erro na autenticação. Tente novamente mais tarde." instead of leaking the raw SDK message. Both paths log the full exception via `ErrorLoggingService` for developer observability.

**Files affected**
- `SharedParentalCustody/Services/AuthService.cs` — replaced `ex.Message` in user-facing output with generic strings; logs full exception via `ErrorLoggingService`
