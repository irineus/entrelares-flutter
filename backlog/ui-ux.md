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

### U-12 — Dark mode: the user-facing theme switch

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Description**
Both themes already exist and ship: **U-27** (20/08/2026) delivered light and dark
hand-written from the token file, and the app follows the system setting
(`themeMode: ThemeMode.system`). What remains of this item is only the **user-facing
preference** — "sempre claro / sempre escuro / seguir o sistema":

- a three-state control on the profile/settings surface (coordinate placement with U-21,
  which reorganizes that page);
- persisted locally per device (`shared_preferences`) — a display preference, not family
  data, so it never touches the database;
- applied at startup before the first frame, feeding `MaterialApp.themeMode`;
- strings through the U-13 catalogs.

> **Rewritten 26/08/2026 (post-cutover board sweep).** The original record asked for CSS
> custom properties across the Blazor pages — that whole scope was delivered by U-27's token
> architecture, so complexity dropped `medium → low`. The frozen web client never received
> it, by design.

**Justification**
Most mobile users enable system-wide dark mode, and `ThemeMode.system` already honours it —
but a per-app override is a common, cheap expectation (reading in bed with the phone on
light system theme, or vice versa), and everything expensive about it is already built.

**Files affected**
- `apps/entrelares_app/lib/` — theme preference service + the three-state switch;
  `MaterialApp.themeMode` reads it
- Widget test: the three states + persistence across restart

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

---

### U-29 — Senior UI/UX design review: full-app audit and consistency fixes

| Field | Value |
|---|---|
| **Status** | `in-progress` |
| **Priority** | `medium` |
| **Complexity** | `medium` |
| **Impact** | `high` — every finding is on a shipping surface; the fixes close drift the U-27/U-28 system was built to prevent |
| **Roadmap** | Group 4, Ordem 0 (owner decision 26/08/2026: first of the current queue) |

> **Created 26/08/2026 (owner request):** a full review of the app's UI/UX — every screen,
> icon and the navigation experience — acting as a senior product designer, with the findings
> registered here and the fixes that fit delivered in the same item. The review was performed
> over the code (all 23 screens/sheets, the `widgets/ui/` component set, `theme/`, the shell
> and router), cross-checked against owner-supplied screenshots.

**Overall verdict**
The U-27 token architecture and the U-28 harmonization hold up very well: one colour source,
hand-written light/dark themes, a real component vocabulary (cards, banners, badges, sheets,
skeletons, timeline, danger zone), loading states with shape, and a navigation model (4-tab
shell + bottom sheets) that is coherent and phone-first. The findings below are **drift and
stragglers**, not architecture: places the conventions did not reach, plus one accessibility
gap on the calendar grid.

**Findings (F# = fixed in this delivery · R# = registered, not fixed here)**

- **F1 — The bulk sheet missed the U-28 QA pass.** It still uses bare underline
  `DropdownButton`s, loose `Text` labels and no card grouping — exactly what the day sheet
  and the wizard were converted away from (their comments document the convention). Aligned:
  `DropdownButtonFormField` with integrated labels, `AppFieldLabel` (+ the "Limpar"
  checkboxes as label trailing), the same `AppCard` question blocks, Spacing tokens.
- **F2 — Destructive confirmations wore the brand colour.** The final "Confirmar" of
  leaving the family / deleting the account (profile), of opening a family-deletion request
  and of "Excluir agora" (família) rendered as default `FilledButton` — indigo, the same as
  "Salvar". The design system already states a destructive primary takes the danger tone
  (`AppActionPair.destructive`, `AppDangerZone`); these three now do.
- **F3 — U-19 parity regression: the password eye toggle survived only on register and
  sudo.** Login, the profile's change-password pair and `/update-password` had obscured
  fields with no show/hide — U-19 delivered that toggle product-wide in Phase 6. Restored on
  all three (one toggle drives a pair, as register already does).
- **F4 — Hand-glued `•` bullets** in the família deletion-pending panel and the
  policy-update change list — the exact defect `AppBulletList` exists to fix (a wrapping
  line restarts under its bullet). Both now use the component.
- **F5 — `day_sheet` carried a private `_banner` duplicating `AppBanner`** — the "one
  implementation cannot drift from itself" argument in reverse. Replaced with `AppBanner`.
- **F6 — Invitation status as plain text.** "Enviado"/"Expirado" on the invitation card were
  bare `bodySmall` runs while every other row state in the app is an `AppBadge`. Now badges
  (info / warning).
- **F7 — The profile password fields were raw `TextField`s**, the only two in the app
  outside `AppTextField` — converted (which is also what F3 needed).
- **F8 — iOS share glyph on the Android-first app.** The PDF tab's share button used
  `Icons.ios_share` while the família screen shares with `Icons.share_outlined`. Unified on
  the Material glyph.
- **F9 — Load-error states were three different things.** Reports tabs: `AppBanner` (danger)
  with title; família: plain text + reload button; calendar and notifications: a bare
  centred sentence with no retry affordance at all (pull-to-refresh exists but is
  undiscoverable as recovery). Unified: screen-level load errors render `AppBanner` (danger)
  + a "Recarregar" button, keeping pull-to-refresh.
- **F10 — The calendar grid was mute to screen readers.** A day cell announced only its
  number (plus the frozen mark); who is responsible, the swap state and the handoff time —
  the entire content of the grid — were visual-only, undermining the "colour is never the
  only vector" principle for blind users. Each cell now carries a composed semantics label
  ("12, Fernanda, trocado, troca 18:00") with the inner paint excluded.
- **F11 — Custom-role delete confirm was a neutral `TextButton`** ("Sim") — now wears the
  danger colour, consistent with every other destructive confirm.
- **F12 — Stale doc comment on the calendar `_Legend`** said "scrolls sideways" while the
  QA version wraps — fixed with the code it describes.

**Registered, not fixed here**
- **R1 — Profile page over-exposure** is already **U-21** (read-only groups + pencil
  sheets); the review confirms it as the right next profile move. No new item.
- **R2 — Day-sheet decluttering** is already **U-25**; confirmed, no new item.
- **R3 — Dark-mode user switch** is **U-12**; confirmed.
- **R4 — PDF tab's initial load uses a spinner** though the shape (filter card) is known —
  a skeleton would follow the U-27 rule. Cosmetic; left for a future polish pass.
- **R5 — Form-level errors as red text** under the submit button (login/register/update
  password) are a consistent app-wide pattern and were deliberately kept — only
  screen-level load errors moved to banners (F9).

**Files affected**
- `apps/entrelares_app/lib/screens/bulk_sheet.dart` (F1) · `profile_screen.dart` (F2, F3,
  F7) · `family_screen.dart` (F2, F4, F6) · `policy_update_screen.dart` (F4) ·
  `day_sheet.dart` (F5) · `reports_pdf_tab.dart` (F8) · `calendar_screen.dart` (F9, F10,
  F12) · `notifications_screen.dart` (F9) · `login_screen.dart` (F3) ·
  `update_password_screen.dart` (F3) · `custom_roles_screen.dart` (F11)
- Widget tests updated/added in the same delivery; the two source gates
  (`no_color_literal_test`, `no_literal_snack_test`) stay green.
