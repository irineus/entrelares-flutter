# Backlog — UI / UX (pending)

Active UI/UX items. Completed records live in [`archive/`](archive/). Conventions and the forward plan: [`README.md`](README.md). Live status: the [Notion board](https://app.notion.com/p/3ae2f3f4b9b28169acd9e642ad4760aa).

---

_**U-18** (hide the "Trocado" legend badge on swap-less months) and **U-19** (show/hide eye toggle on password fields) were completed in Phase 6 (v1.6.9–v1.6.10) — records in [`archive/phase-6.md`](archive/phase-6.md)._

---

_**U-20** (projected balance with accepted future swaps) and **U-07** (per-caregiver swap
split "cedeu · recebeu") were completed together in Phase 7 (v1.7.9) — records in
[`archive/phase-7.md`](archive/phase-7.md)._

---

_U-11 (Phase 5 item 5.5) was completed in July 2026 (v1.5.5) — its record lives in [`archive/phase-5.md`](archive/phase-5.md)._

---

### U-12 — Add dark mode support

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Description**
The entire app is hardcoded to a light theme. Modern PWAs are expected to respect `prefers-color-scheme: dark`. Add CSS custom properties (design tokens) for background, surface, text, and accent colours, then provide a dark variant using `@media (prefers-color-scheme: dark)` or a manual toggle stored in `localStorage`.

> **Mostly delivered elsewhere (20/08/2026).** `U-27` shipped both themes in the Flutter app,
> hand-written from the token file, and the app already follows the system setting
> (`themeMode: ThemeMode.system`). What is left of this item is the **user-facing switch** —
> the "always dark / always light / follow the system" preference and where it is persisted.
> The Blazor description above is history: the frozen web client will not receive this.

**Justification**
Most mobile users enable system-wide dark mode. A family app used daily — often checked at night before sleep — benefits significantly from reduced eye strain. This also improves OLED battery life on mobile.

**Files affected**
- `Entrelares/wwwroot/css/app.css` or root styles — define CSS custom properties and dark overrides
- All `.razor.css` files — replace hardcoded colour values with `var(--token)` references
- `Entrelares/wwwroot/index.html` — update `theme-color` meta for dark variant

---

_**U-13** (internationalization, PT-BR / EN across every surface) was completed in Phase 7 (v1.7.16 → v1.7.28) — record in [`archive/phase-7.md`](archive/phase-7.md). Date and number formatting per language was split out as **U-24**, also completed in Phase 7
(v1.7.31 → v1.7.32) — record in [`archive/phase-7.md`](archive/phase-7.md)._

---

### U-21 — Profile page refinement: read-only groups + pencil-to-edit sheets

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `medium` |

**Description**
Every editable field on the profile page renders as an always-open input (name, role, e-mail,
password), which reads as over-exposure — the page looks like a giant form even when the user
only came to look. Restructure into **read-only summary cards with a pencil icon per group**:
"Dados do usuário" (name, role, e-mail), "Segurança" (password; future: login method), and a
future "Endereço" group. The pencil opens a **bottom-sheet editor** (decision Aug 2026: the
bottom-sheet pattern, already consolidated in the app — day editor, sudo — chosen over
sub-pages and inline field toggles; chrome in the PAGE, content component inside, per the CSS
isolation invariant).

**Kept as-is**
Sudo gating (`RequireSudoAsync` flows), the admin section for other members, the LGPD export, the
danger zone, and the Família→Perfil navigation. The E2E selectors pinned in `ProfileUiTests`
(`#profileName`, `.profile-header`, …) move with the markup — update the tests in the same
delivery.

**Files affected**
- `Entrelares/Pages/ProfilePage.razor` + `.razor.css` — read-only cards, pencil buttons, sheets
- New sheet content components under `Pages/Components/` (e.g. `ProfileDataSheet.razor`, `ProfileSecuritySheet.razor`)
- `Entrelares.E2ETests/ProfileUiTests.cs` — selectors follow the new structure


---

_**U-23** (first-run onboarding — activation checklist, the "Como funciona a troca" screen and
the guided tour) was completed in Phase 7 (v1.7.29 → v1.7.30) — record in
[`archive/phase-7.md`](archive/phase-7.md)._

---

### U-25 — Day sheet decluttered: the child's day first, swap chrome minimized

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `low-medium` (layout + selectors; no new data) |
| **Impact** | `high` — the day sheet is the most-touched surface after the calendar grid |
| **Roadmap** | Group 5 (polish), after F-52 — standalone, but deliberately the **layout groundwork for F-55** (child day agenda) |

> **Created 12/08/2026 from closed-alpha feedback (audio):** *"quando sobe essa lista aqui,
> essa lista suspensa está muito poluído. Tinha que simplificar essa tela. […] falta um botão
> voltar aqui nessa tela […] quando você clica no dia deveria aparecer um igual no Outlook,
> ali o resumo do dia […] E não essa opção de responsável agendado, essas coisas aqui — isso
> a gente já tem ali na frente, já está visual, não precisa repetir de novo. Ou deixar menor."*

**Description**
Three moves on the day bottom-sheet, all shippable without F-55:
1. **Stop repeating what the calendar already says.** Scheduled/actual responsible and handoff
   time are the cell's colours and the today card; in the sheet they collapse to one compact
   chip row instead of a field list.
2. **Actions behind a discreet edit icon.** Assign/swap/handoff/observação move under a pencil
   (or "⋯") in the sheet chrome — the tester's exact ask: swap data *"minimizada… possível de
   ser alterada a partir de algum ícone discreto"*. No workflow changes — the same sheets open,
   one tap deeper.
3. **Explicit back/close affordance.** Backdrop-tap and drag exist but were not discovered
   ("falta um botão voltar") — add a visible ✕ in the sheet header.
The freed body is where the F-55 day timeline will render; until F-55 exists, it shows the
observação do dia and the compact chips (no dead space — the sheet just gets shorter).

**Design notes**
- Bottom-sheet pattern invariant: chrome in the PAGE, content component inside (CSS isolation).
- Preserve the day-colour semantics (single vs split colours) in whatever chips remain.
- 344 px minimum width; verify the chip row + icons fit.
- **E2E impact is the real cost**: SmokeTests/BulkUiTests/day-editor flows drive this sheet —
  selectors move with the markup in the SAME delivery, with dedicated marker classes (the
  Playwright first-match gotcha).

**Justification**
Direct field feedback on the app's highest-frequency interaction, and it is the cheap half of
the F-55 direction: simplifying now improves every day-tap immediately, and the agenda later
lands in a sheet that already has room for it.

---

### U-26 — E-mail dark-mode visibility (explicit colors on every element)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `low` (one pass over the shared template layer) + a manual test matrix |
| **Impact** | `medium-high` — the invite CTA is the app's growth loop; an invisible button is a lost family |
| **Roadmap** | Group 5, end of queue — it was a candidate to ride F-54's PR 1, which rewrote every e-mail template; **that window closed** when F-54 shipped (12–13/08/2026), so this is now a standalone pass. The templates are right in brand and still unreadable in the dark |

> **Created 12/08/2026 from closed-alpha feedback (owner, with screenshot).** The invite
> e-mail renders a pure-black header band and a pure-black CTA button ("Criar minha conta").
> In light mode it looks fine; on a dark-theme mail client the partial color transformation
> makes the black elements nearly invisible.

**Description**
One pass over the e-mail templates (`supabase/functions/_shared/` + the `send-*` functions —
since U-13 every e-mail, including GoTrue's via the `send-auth-email` hook, is built there,
so ONE layer covers all senders) applying the rules that survive dark mode:
- **Every element gets an explicit `color` AND an explicit `background-color`** — "black text
  on inherited background" is precisely what disappears when the client repaints backgrounds.
- **No pure-black (`#000`) surfaces.** Gmail's dark transformation darkens light backgrounds
  but leaves near-black ones alone, so a black button on a now-dark card vanishes. Use the
  brand color for the header band and CTA with white text — contrast then holds in BOTH
  modes (and the rebranded Entrelares e-mails want the brand color anyway).
- **Do not rely on `@media (prefers-color-scheme: dark)`** — Apple Mail honours it, Gmail
  ignores it and applies its own inversion; the fix must work with no media query at all.
- Links/footnote greys: check contrast against both white and dark-gray backgrounds.

**Test matrix (manual, one round)**: Gmail Android dark, Gmail web dark, Apple Mail dark
(iPhone), plus light mode re-check. Send real e-mails via the dev project to a test inbox.

**Justification**
Direct field report with evidence, on the most consequential e-mail the product sends (the
invite is the growth loop; auth e-mails are account recovery). Cost is one styling pass on a
single shared layer; riding the F-54 template rewording avoids touching the same files twice.

---

_**U-27** (visual foundation: design tokens, the shared component set and skeletons) was
completed in Phase 7 on 20/08/2026 — record in [`archive/phase-7.md`](archive/phase-7.md).
It is the item that made **U-12** nearly free: both themes exist and the app already follows
the system, so what is left there is only the user-facing switch._

---

_**U-28** (screen-by-screen visual harmonization — the U-27 adoption pass) was completed in
Phase 7 on 20/08/2026 — record in [`archive/phase-7.md`](archive/phase-7.md). It is the item
that spent what U-27 built: `AppCard` was used ONCE in the whole app before it._
