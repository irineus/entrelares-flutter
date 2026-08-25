# Backlog — Security (pending)

Active security items. Completed records live in [`archive/`](archive/). Conventions and the forward plan: [`README.md`](README.md). Live status: the [Notion board](https://app.notion.com/p/3ae2f3f4b9b28169acd9e642ad4760aa).

---

_S-11 (Phase 5 item 5.11) was completed in July 2026 (v1.5.11–v1.5.29, QA approved; shipped to production in v1.6.0) — its full decision record lives in [`archive/phase-5.md`](archive/phase-5.md). Both operations delivered: individual exit (grace, tombstone, succession, freeze, colors, cross-family migration) and whole-family deletion by consent (unanimity fast-path, undo, D-3 reminder, purge + farewell). Deferred follow-up: **F-30** (multi-family membership)._

_**S-14** (drop the legacy always-true RLS policies — the sweep found the cross-family leak on `care_schedules`, `activity_logs` and `profiles`) was completed in Phase 6 (v1.6.14) — record in [`archive/phase-6.md`](archive/phase-6.md)._

---

_**S-15** (legal review of the policies + re-consent flow on policy change) was completed in
Phase 6 (v1.6.34–v1.6.39) — full record, including the three rounds of legal opinion, the 19
findings and every design decision, in [`archive/phase-6.md`](archive/phase-6.md). All 19 are
implemented across five deliveries: the re-consent gate (B-4), the `joined_via_invite` marker,
the MATERIAL pair A-1 + A-5 with the policy bump, the eight non-material texts + C-7, and the
code half (A-4 invite purge, B-3 grace warning, C-6 opt-in log). **Open for the promotion:**
`PolicyVersions.EnforceFrom` is provisionally `2026-09-30` — a one-line corrective migration
must set `policy.enforce_from` AND the client constant to *promotion date + 15* in the same
delivery, or `ReconsentGateTests.EnforceFromConstant_MatchesServerSetting` turns red._

---

_**S-16** (coordinated migration off the legacy static keys) was completed in Phase 7 (`1.7.1`)
— full record, including why the API-key and the JWT-signing migrations are two independent
steps and why five functions had to trade `verify_jwt` for in-code authorization, in
[`archive/phase-7.md`](archive/phase-7.md). The repo side is delivered; the key rotation itself
is owner ops, sequenced in [section 10 of the deploy runbook](../supabase/README.md#10-s-16--migração-das-chaves-de-api-e-da-assinatura-jwt)._

---

### S-17 — Disable the legacy API keys and revoke the HS256 JWT secret

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Context — what S-16 left deliberately unfinished.**
S-16 (`1.7.1`, 03/08/2026) moved everything onto the new publishable/secret keys and
promoted **ES256** on both projects: the app, the CI secrets, the Edge Functions and
the two crons no longer touch a legacy key. But the legacy `anon`/`service_role`
keys are **still enabled** on both projects, and the HS256 shared secret still sits
in *Previously used* on the JWT Keys page. Until they are turned off, a leaked
legacy key still opens the project — which is most of the security benefit of the
migration, unrealised.

**Why it is a separate item, not a loose end.**
Two reasons, both about *time* rather than effort:
1. **The platform enforces an order.** The HS256 secret cannot be revoked while the
   legacy keys are enabled — `anon`/`service_role` **are** JWTs signed by it, so
   revoking first would be an inconsistent state the Dashboard refuses.
2. **A grace window is required.** Access tokens issued before the ES256 rotation are
   signed with HS256 and stay valid until they expire (1 h). Revoking earlier
   force-signs-out whoever is active. So the revocation is a *later* action by
   construction, not something to bundle into the cutover.

**What to do** — the procedure is [section 10.7 of the runbook](../supabase/README.md#107-desativar-as-chaves-legadas),
per project (DEV first, then prod):
1. Settings → **API Keys** → tab *Legacy API keys* → read the **last used**
   indicators. They are the only evidence that nothing forgotten still calls with
   them (a mobile build, a local script, an old `e2e.local.env`).
2. **Disable** `anon` and `service_role`. Reversible — re-enable if a caller shows up.
3. Only then, JWT Keys → **revoke** the HS256 key sitting in *Previously used*.

**Verification**
- A probe with a legacy key must come back **401** after step 2 (same PowerShell
  shape as the S-16 probes, `-UserAgent` included).
- A `workflow_dispatch` full-pack on `dev` must stay green — it exercises the whole
  stack on the new keys, so a green run after disabling is the proof that nothing
  depended on the legacy pair.
- Prod: the invite sign-up flow, which is the path that broke in July.

**Risk & rollback**
Low and reversible: re-enabling a legacy key is one click, and the revocation of the
HS256 secret is the only irreversible step (do it last, and only after the two
projects have run for a while with the legacy keys disabled). **Note the standing
emergency procedure disappears with this item**: while a legacy key exists, an auth
incident can be fixed by rolling the signing key back to HS256; once revoked, that
escape hatch is gone — which is the point, but worth doing knowingly.

---

### S-18 — The privacy policy and Play's Data safety must catch up with the store billing rail

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `high` — the policy describes a payment arrangement that stopped being the whole truth on 23/08/2026, and Play reads the Data safety form and the policy against each other |
| **Complexity** | `medium` — the console form is one sitting; deciding whether the policy change is MATERIAL is the expensive half, because material means blocking the entire user base for 15 days |
| **Impact** | `high` — LGPD disclosure on one side, the store's own compliance review on the other |
| **Roadmap** | Group 5 (polish), alongside T-57 — like it, this should precede the next PRODUCTION rollout; a closed test survives it. The board owns the order |
| **Repo** | `flutter` (the Data safety answers, the `PolicyVersions` constants, the `app_settings` migration) **and** `entrelares-site` (the legal text itself) |

**The finding (25/08/2026).** Surfaced while preparing the first Play upload since the cutover
(`0.2.50+52` to *Closed testing – Alpha*), reading the console's declarations against the code
rather than against our own notes — which is the [S-15](../CLAUDE.md) lesson applied to
ourselves for the second time.

1. **The published privacy policy never mentions Google Play.** A search of the whole rendered
   text of `entrelares.app/privacidade.html` returns **zero** occurrences of "Play", "loja" or
   "in-app". What it says is *"Os dados de pagamento são tratados diretamente pelo Asaas
   (ver §7)"*, and §7's operator list names Asaas, Cloudflare, Umami and **Google — as Google
   Fonts**, the glyph fallback of the WEB channel added on 23/08. Since that same day the
   Android channel sells through **Play Billing** (T-48, `billing.store_enabled = true`, proven
   by a real purchase), so the one rail the policy names is now the rail only half the users
   are on.
2. **The Data safety form was answered when Android sold nothing.** *Financial info → Purchase
   history* now applies: `billing-store-verify` writes a subscription row and `billing_events`
   ledger entries carrying the Play purchase token, tied to the family. **Marked on 25/08**
   during this pass; the rest of this item is what that one checkbox revealed around it.
3. **Two more declarations do not match the code, and one is undecided.**
   - *App activity → App interactions* is **missing**. [`store/README.md`](../store/README.md)
     §4 declares it, and the app POSTs to the third-party `cloud.umami.is` on every prod build
     of both channels ([`analytics_service.dart`](../apps/entrelares_app/lib/services/analytics_service.dart)).
     The console's overview showed *2 data types* total against a Personal info of *2/9* — the
     whole total is Personal info, so App activity is at zero.
   - *Messages → Other in-app messages* — **undecided, and the decision belongs in this item.**
     F-44 gives a swap request `requestMessage`, `approvalNote` and `rejectionReason`: free text
     one caregiver writes, our server stores, and **another caregiver reads**. It is not chat,
     which is why it was never declared; it is also not nothing.
   - *Personal info → User IDs* — judgment call on the profile UUID. The account is already
     identified by the e-mail address, which is declared.

**What is NOT the problem — recorded so it is not re-proposed.** *App content → Financial
features* is correctly answered **"my app doesn't provide any financial features"**: that page
asks whether the app IS a financial service (lending, crypto, insurance, trading), not whether
it sells a subscription. There is **nothing anywhere on App content** that declares in-app
purchases — verified on the real console on 22/08/2026 and recorded in
[`supabase/README.md`](../supabase/README.md) §9-bis.0; Play derives "contains in-app purchases"
from the products that exist in *Monetize → Subscriptions*.

**Why it is an item and not a fix in passing.** If adding an operator to §7 is a **material**
change, it is four things in ONE delivery (CLAUDE.md → *Legal pages*): `PolicyVersions.current`,
an `enforceFrom` of *the date the text becomes VISIBLE* + 15 days, the matching
`policy.current_version` **and** `policy.enforce_from` rows via migration, and an entry in the
change summary the screen renders. Miss the settings rows and the RPC refuses every accept in
production — users are told to update an app that is already current and nobody gets through.
That is a whole-base blocking screen; it cannot ride along inside another PR. **Whether it is
material is the owner's call**, and it is the first decision of this item, not the last.

**What to do**
1. **Decide materiality** (owner; counsel if the answer is not obvious). A new operator
   receiving personal data is the kind of change that usually is.
2. `entrelares-site`: §7 gains Google/Google Play as the payment operator of the STORE channel,
   and the subscription paragraph stops implying Asaas is the only rail. Mirror the
   *substance*, not line for line.
3. `flutter`, only if material: the four-part delivery above, with the integration tests that
   compare each constant against its server setting staying green — they are the red gate that
   replaces a live lockout, and they are never to be weakened.
4. Play Console → *Data safety*: add **App interactions**; decide **Messages** and **User IDs**;
   *Purchase history* is already marked.
5. [`store/README.md`](../store/README.md) §4: bring the table to whatever ends up declared, and
   retire the caveat still written in the future tense (*"the day that switch is flipped"* — it
   was flipped on 23/08/2026).

**Verification**
- Data safety *Preview* (step 5 of the wizard) matches `store/README.md` §4 line for line, in
  both directions: nothing declared that the code does not do, nothing the code does left out.
- A pass over §7 against the code with the same test: every operator that receives data is
  named, and no operator is named that does not.
- If the policy bumped: the constant-vs-setting integration tests green, and a real accept in
  production after the migration.

---

_S-12 (Phase 5 item 5.12) was completed in July 2026 (v1.5.21) — its record lives in [`archive/phase-5.md`](archive/phase-5.md). Key decision: column-level encryption **not adopted** (proportionate posture = platform AES-256 + TLS + bcrypt + RLS + zero anon access); revisit before public availability, alongside S-13._

---

_S-13 (Phase 5 item 5.13) was completed in July 2026 (v1.5.22) — its record lives in [`archive/phase-5.md`](archive/phase-5.md). Consent now recorded per profile (timestamp + policy version); retention implemented (read notifications purged after 6 months); controller + foro designated (the dedicated privacy address is **T-34**); operators/DPAs, art. 14 and the art. 48 breach runbook documented. Pending flags: legal review of the children's-data section and a re-consent flow on policy change — both before public availability._
