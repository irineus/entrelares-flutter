# store/ — Google Play presence: listing, brand assets and the release checklist

Everything the **Play package `com.entrelares.app`** shows to a human being, versioned instead
of drafted in the Console: the listing copy in both languages, the brand masters and the script
that derives every icon from them, the feature graphic and its generator, and the answers the
Console's policy forms expect.

Since the T-53 cutover (23/08/2026) that package carries **this repository's Flutter bundle**.
Build and upload mechanics therefore live where the build does — [§6](#6--publishing-a-new-android-build)
points at them; this directory is about the *presence*, not the pipeline.

> **Where this came from (T-56, 24/08/2026).** These files spent their whole life in
> `entrelares-app/store/`, next to the runbook of the **TWA** shell that used to be the Android
> app: Bubblewrap, `twa-manifest.json`, the keystore ceremony, the version-code rule of a shell
> that wrapped a website. That half is the **dead package** — it did not travel, and retiring
> the legacy `com.guardacompartilhada.app` is its own item (**T-52**). What travelled is what is
> still true of a live store listing. Nothing here needs the old repository to be read.

---

## 1 · Store listing (PT-BR + en-US)

**Grow users → Store presence → Main store listing.**

- The copy is versioned here: [`listing-pt-BR.txt`](listing-pt-BR.txt) and
  [`listing-en-US.txt`](listing-en-US.txt) — app name, short description and full description,
  with the Play character limits noted inline. **Edit the files, review in a PR, then paste into
  the Console** — never draft in the Console directly, where nothing is versioned.
- **English translation** (the app is bilingual since U-13): at the top of the Main store
  listing page → **Manage translations** → **Add your own translation** → **English (United
  States) – en-US** → paste from `listing-en-US.txt`. The default language stays pt-BR.
- **Categories**: app category **Parenting** (fallback: Lifestyle). Tags: family, calendar.
- **Contact details**: e-mail `suporte@entrelares.app`; website `https://entrelares.app`.
- **Screenshots (phone)** — ⚠️ **the one thing on this page that is out of date.** The Console
  and the landing share one set (`entrelares-site/public/img/screenshots/*.png`, 1080×1920),
  captured on **23/07/2026** from the QA environment of the **Blazor** client, with the `[Dev]`
  badge masked in place. Two things have happened to them since: the cutover replaced the client
  they photograph, and U-27/U-28 replaced its visual system. So the listing shows a product that
  no longer exists — cosmetically, not in what it claims. **Recapturing is scheduled as
  [T-57](../backlog/technical.md)** (24/08/2026), which absorbed `entrelares-site`'s **L-21**:
  that item wanted the EN set for the same frames, on the assumption the PT-BR ones were
  current — an assumption the cutover ended. It needs the Flutter app in production
  configuration (the dev flavour prefixes `[Dev] ` into stored notification titles), both
  languages, and a pass over both the Play listing and the landing. It should precede the next
  production rollout; a closed test survives a listing update.

## 2 · Brand assets

Two masters, both AI-generated and **approved by the owner** (F-54's "Emblema" identity: two
interlocked house-rings, sage fabric and terracotta wood, over a cream squircle plaque). There is
**no vector source** — changing the art means asking for a new generation and re-running the
script, never editing a PNG by hand.

| File | What it is |
|---|---|
| [`brand-emblema.png`](brand-emblema.png) | 1024², **text-free**, the 3D render. Source of every icon. |
| [`brand-emblema-flat.png`](brand-emblema-flat.png) | 1380×752, the flat rendition. Source of the 96 px favicon only — at that size the 3D render turns to mush and the flat linework stays crisp. |
| [`brand-icons.py`](brand-icons.py) | Derives all seven icon files from the two masters (needs Pillow: `python3 store/brand-icons.py`). |
| [`store_icon.png`](store_icon.png) | 512², the Play listing icon. **Hand-supplied, not a script output** — see below. |

`brand-icons.py` writes, and these are the ONLY places the emblem is vendored:

```
apps/entrelares_app/web/favicon.png                    (96, from the flat master)
apps/entrelares_app/web/icons/Icon-{192,512}.png       (full frame)
apps/entrelares_app/web/icons/Icon-maskable-{192,512}.png
apps/entrelares_app/assets/brand/emblema.png           (= Icon-512)
apps/entrelares_app/assets/brand/emblema-maskable.png  (= maskable 512)
```

The last two are what `flutter_launcher_icons` reads (config block in
`apps/entrelares_app/pubspec.yaml`), so the **Android launcher icon regenerates from the same
masters** — until T-56 this repo vendored those two files with a comment saying it had no way to
regenerate them and pointing at the other repository. Maskable variants re-compose the emblem at
**78 %** over the artwork's own background tone, with a feathered paste so no seam shows, because
Android's adaptive mask clips the plaque's corners otherwise. After running the script:
`fvm dart run flutter_launcher_icons` refreshes the mipmaps.

**Why `store_icon.png` is not written by the script.** It used to be (`maskable(512)`, byte for
byte). On 13/08/2026 it was replaced by a **different generation of the same emblem** — a fuller
framing that survives Play's own crop better — supplied by hand and versioned as it is. The
script's write was removed with it, so that a routine re-run cannot silently regress the store
icon to the worse framing.

## 3 · Feature graphic (1024×500, required)

[`feature-graphic.png`](feature-graphic.png), rendered from
[`feature-graphic.html`](feature-graphic.html) with headless Chrome — the exact command, and the
crop workaround for builds that subtract window chrome from `--window-size`, are in the file's
own header comment. Re-render whenever the tagline or the artwork changes, and **re-upload**:
Play serves its own copy and nothing updates it automatically.

[`feature-graphic-english.png`](feature-graphic-english.png) is an English render kept as-is from
13/08/2026 and **not usable as an upload yet**: it is 2950×1440 — exactly Play's 2.048∶1 ratio,
but the form takes 1024×500 — and there is no `feature-graphic-english.html` that reproduces it.
An EN listing that needs its own graphic either downscales this file or gains a generator.

## 4 · Policy forms (Data Safety, content rating, app access)

**Monitor and improve → Policy → App content.** The answers below map the shipped privacy policy
(https://entrelares.app/privacidade.html) — **if the policy changes, re-answer.** Every
declaration on that page must be ✅ before a release rolls out, and the Console does not always
say which one is blocking: sweep the whole list.

- **Privacy policy URL**: `https://entrelares.app/privacidade.html`
- **App access** — the declaration that rejects apps whose reviewers cannot get in. The whole app
  sits behind login, so answer **"All or some functionality in my app is restricted"** and add an
  instruction set with a REAL test account (a dedicated reviewer account created through the
  normal sign-up, kept in the password manager as "Entrelares — Play reviewer account").
  Instructions: *"Log in with the credentials provided; the custody calendar is the home screen.
  All features are reachable from the bottom navigation."* Keep the account alive — Google
  re-reviews on later releases too.
- **Data Safety** — declare:
  | Data type | Collected? | Shared? | Notes |
  |---|---|---|---|
  | Personal info → Name | Yes — required, account | No | Profile name |
  | Personal info → Email address | Yes — required, account | No | Login + notifications |
  | App activity → App interactions | Yes — not linked to identity | No | Umami, cookieless product analytics; no device id, paths sanitized |
  | Financial info | **No** | — | See the caveat below |
  | Location, contacts, photos, device ids | No | — | Not requested |
  - Data is **encrypted in transit** (HTTPS only): Yes.
  - **Deletion**: users can request account/data deletion in-app and via
    `privacidade@entrelares.app` (LGPD) — answer "Yes, deletion path available".
  - The consent log stores the accepting IP (disclosed in the policy) — server-side
    security/audit data tied to the account; declare it under Personal info only if the form's
    current wording requires IP disclosure (re-read the help text at fill time).
  - ⚠️ **The "Financial info → No" line has an expiry date.** It was written when the Android
    app had no purchase flow at all and every payment happened on the website. The Play Billing
    rail (T-48) now ships **dormant** behind `billing.store_enabled = false`; the day that switch
    is flipped, the app does sell in-app — re-read the Financial info questions before, not
    after. The flip is the last step of [`supabase/README.md`](../supabase/README.md) §9-bis,
    which also records what Play does and does not ask about IAP (nothing on the App content
    page: Play derives it from the products that exist).
- **Content rating questionnaire**: category *Utility/Productivity*; no violence, no user-to-user
  public content (messages are private within a family), no gambling → expected rating L/3+.
- **Target audience**: 18+ (parents/guardians). The app is **not** child-directed — the child is
  the *subject* of the calendar; no child accounts exist and no child data is collected (the only
  child-related datum is the day assignment itself).
- **Ads**: No ads.

## 5 · Closed test → production

A personal Play account must run a closed test before production: currently ~12 opted-in testers
for **14 uninterrupted days** (re-verify the rule at
https://support.google.com/googleplay/android-developer/answer/14151465 — it changes). That is
calendar time, so recruit testers early rather than when a build is ready.

1. **Testing → Closed testing → track**: watch the tester count; the Console shows progress
   toward production access.
2. When eligible, **Apply for production access** (the Console prompts), then **Test and release
   → Production → Create release**, upload the AAB and roll out.
3. Release notes in PT-BR. The Blazor client's release notes are frozen history in
   [`docs/changelog-blazor.md`](../docs/changelog-blazor.md); a Flutter release describes what
   this repo shipped since the previous upload.

## 6 · Publishing a new Android build

```
cd apps/entrelares_app && fvm flutter build appbundle --flavor prod --release
```

- `--flavor prod` is not optional: it is what selects the production Supabase project **and** the
  `com.entrelares.app` application id. A flavour-less build resolves to dev by construction
  (`CLAUDE.md` → *Locked decisions*).
- **Release signing** comes from the git-ignored `apps/entrelares_app/android/key.properties`
  (T-55): `prod.*` must be the PRODUCT's upload keystore. Without the file a release build fails
  fast, on purpose.
- **Version**: `version:` in `pubspec.yaml` feeds both halves — the name (`0.2.48`) and the build
  number after `+`, which becomes Android's `versionCode`. **Every upload needs a higher
  `versionCode` than the last**, and a code is burned by the UPLOAD, not by the rollout.
- The Play Billing side of the account (products, RTDN, the service account the server uses to
  verify a purchase) is configured once, in [`supabase/README.md`](../supabase/README.md) §9-bis.

## 7 · Store-context rule (app behaviour)

Play's payments policy forbids steering a Play-distributed app's users to an external purchase
flow. The app therefore never shows the website checkout on the store build: the Android target
sells through **Play Billing** behind `billing.store_enabled`, and while that switch is `false` —
or the device has no store, or no product comes back — the store branch shows the **T-38 neutral
note** ("manage your subscription on the website": no price, no checkout link), which is also the
fail-closed default. The web target keeps the Asaas rail. Never add a store-visible link straight
into the web checkout.

## 8 · App Links (`assetlinks.json`)

The pairing that keeps the installed app full-screen and lets it own its own URLs lives on the
**web side**: `apps/entrelares_app/web/.well-known/assetlinks.json`, published with the web
channel at `web.entrelares.app`. It carries three statements — `com.entrelares.flutter` (the dev
flavour), `com.entrelares.app` (upload + app-signing fingerprints) and the legacy
`com.guardacompartilhada.app`, which stays until **T-52** retires that package. If the browser
bar ever comes back on an installed app, that file in PRODUCTION is the first thing to check.
