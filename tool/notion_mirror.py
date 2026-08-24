#!/usr/bin/env python3
"""Generate the Notion mirror payload for the Backlog board, from the repos.

The Notion board (database "Backlog" under "Entrelares — Backlog & Roadmap")
owns status, roadmap order and effort. Each row's PAGE BODY is a MIRROR of the record
that lives in the repo — this script produces it, so the markdown stays the single
source of truth and the two cannot disagree by neglect.

    python tool/notion_mirror.py -o mirror.json

Output: {"F-33": {"repo", "page_content", "src", "prs", "effort_h", "inicio", "fim"}, ...}
Feed `page_content` to the Notion MCP `update-page` with command="replace_content",
and the effort/date fields to command="update_properties". Nothing here talks to Notion
directly — there is no Notion API token in the repo, and the MCP connector is per-session.

WHY THIS EXISTS (read before "simplifying" it)
---------------------------------------------
Linking a commit to a backlog item used to mean guessing from prose, and both possible
heuristics are wrong:
  * "the ID must be in the subject" hides ~70 genuine deliveries from Phases 1-2, whose
    subjects described the effect and listed the items in the body;
  * "any mention counts" credits an item for commits that merely cite it as background
    (the Supabase SDK bump became an F-29 delivery because it explained that realtime
    does not depend on the C# SDK).
Since July 2026 the answer is the `Backlog: <ID>` commit trailer — the only mark that
means "this commit delivers this item". HAND_REVIEWED below preserves the one-by-one
review of the commits no rule can reach; without it, regenerating loses that work.

THREE REPOS, NOT ONE (24/08/2026 — the archiving of `entrelares-app`)
---------------------------------------------------------------------
Until the T-53 cutover the client lived in `entrelares-app`, so "the item's repo" and
"where its commits are" were the same place. They are not any more: `entrelares-flutter`
is the product app, while the backlog RECORDS still live in `entrelares-app` (they move
here in a later PR of this work — see `docs/arquivamento-app.md`). An item is therefore
recorded in one repo and DELIVERED in another, and this script had no way to say that:

  * deliveries were collected per repo, so the 30+ Flutter PRs of T-53 could never reach
    the record that lives in the app repo — its "Entregas" section listed 2 commits;
  * the session model for effort ran per repo, so once both were read a working session
    that merged in each of them would pay the session start-up cost TWICE.

Both are fixed here: commits are collected GLOBALLY (each carrying its own repo's GitHub
URL, so links stay right) and the session walk runs over the union, ordered by time — a
session belongs to the person, not to the repository that happened to receive the merge.
"""
from __future__ import annotations

import argparse
import collections
import datetime
import json
import posixpath
import re
import subprocess
import sys
from pathlib import Path

SEP = "\x1e"

# Backlog IDs. The negative lookahead is load-bearing: the T-32 findings used to be
# named F-32-1..5 and every reader matched them as the FEATURE F-32, mis-attributing
# that item's effort and commits. They are T32-A1..A5 now, and finding IDs must never
# start with a backlog prefix again.
ID_RE = re.compile(r"\b([FUTS]-\d{2})\b(?!-\d)")
L_RE = re.compile(r"\b(L-\d{2})\b")
# Conventional-commit scope naming an item: feat(s15): / test(t32):
SCOPE_RE = re.compile(r"^\w+\(([futs])-?(\d{2})\)", re.I)
TRAILER_RE = re.compile(r"^Backlog:\s*(.+)$", re.M)

# Deliveries that no rule can derive, credited by reading the commits one by one. Keyed
# by REPO first: a 7-char sha is only unique within a repository, and the per-repo shape
# is what lets the run validate its own table (an entry whose sha is not in that repo's
# history is reported instead of silently doing nothing).
#
# A hand-reviewed credit is AUTHORITATIVE, exactly like a trailer. It used to be
# intersected with "IDs present in the message", which was a safe guard while every
# entry came from a body that named its item — and a silent veto the moment one did not.
# The Flutter stage-4 commits name no item anywhere, and that veto was dropping all of
# them.
HAND_REVIEWED: dict[str, dict[str, set[str]]] = {
    "app": {
        # Phases 1-3: the subject described the effect, the body listed the items.
        "c616e62": {"F-01"},                    "899b5bc": {"S-03", "S-05"},
        "a373b10": {"S-08", "T-01", "T-12"},    "b742592": {"S-02", "T-04"},
        "03c3993": {"S-07", "T-16"},            "81afbd8": {"F-12", "F-13"},
        "f217ca1": {"U-01", "U-02"},            "41deb8b": {"F-03", "S-01", "U-03", "U-10"},
        "22f91be": {"F-03", "S-01"},            "4633b0c": {"U-04", "U-14", "U-15"},
        "65244c4": {"U-03", "U-10"},            "da26bae": {"T-02", "T-03"},
        "18589cc": {"U-05", "U-06", "U-16"},    "8aa2aa0": {"F-21", "T-15", "T-17", "T-21"},
        "8ba9b22": {"F-19", "S-04"},            "f89fcc1": {"T-23", "T-24", "T-25"},
        "a5aed28": {"F-12", "F-13", "S-05"},
        # PR era: the subject names the main item, but these were delivered alongside it.
        "764ef76": {"F-13"},   "baa2361": {"T-27"},   "e900629": {"F-16", "F-17"},
        "7c74c37": {"F-23"},   "178fbf7": {"T-32"},   "2a3fb52": {"T-32"},
        "4a29cad": {"F-18"},   "a4ca5ce": {"T-32"},   "e565a1d": {"F-37", "F-39"},
        "a01991e": {"S-15"},   "f483a31": {"S-15"},
        # August 2026 — the trailer was IN the PR body but never reached the commit:
        # the "GitHub pre-fills the squash message from the PR body" behaviour is the
        # WEB merge button only. These two were merged through the REST API without an
        # explicit commit_message, so GitHub built the message from the branch commits
        # instead and the trailer was dropped. They are credited here rather than left
        # to the subject fallback, which happened to work only because both subjects
        # spell "F-42" — the very heuristic this table exists to replace.
        "abfbe3d": {"F-42"},   "29b422f": {"F-42"},
    },
    "landing": {
        "7bf4380": {"L-08"},   "61e94e0": {"L-02"},
    },
    "flutter": {
        # The stage-3 BATCH commits need no entry — they spell "(T-53)" in the subject.
        # What needs one is the work at both ends of the item, whose subjects describe
        # the effect and whose messages name no item at all. Credited from the stage's
        # own delivery registry, written by the owner as it happened:
        # `entrelares-app/docs/flutter-cutover.md` § "Registro das entregas do estágio".
        "3b18093": {"T-53"},   # stage 1 spike — monorepo + mirrored pure core (#1)
        "a6c1572": {"T-53"},   # stage 1 spike — the vertical slice (#2)
        "e312a69": {"T-54"},   # the repo's own gate (verify.yml) — T-54, not T-53 (#3)
        "e49f8c8": {"T-53"},   # stage 3 opening — dev/prod flavors (#4)
        "00c26e6": {"T-53"},   # stage 4 — the web channel pipeline (#48)
        "0aa0839": {"T-53"},   # stage 4 — publish self-disarms without Cloudflare (#49)
        "a534c3f": {"T-53"},   # stage 4 — CSP lets CanvasKit fetch the glyph (#51)
        "f05ac3d": {"T-53"},   # stage 4 — the four defects the web QA found (#52)
        "28ccfcd": {"T-53"},   # stage 4 — the app is a column again (#53)
        "b18a8d0": {"T-53"},   # stage 4 — F5 gives back the screen you were on (#54)
        "eb40e46": {"T-53"},   # stage 4 — the web channel acceptance (#55)
        "f0508f0": {"T-53"},   # stage 4 — legal pages survive the host move (#56)
        # T-56 (archiving `entrelares-app`) was opened on the board only after
        # its first three PRs had already merged — the item was proposed BY the
        # first of them. From the fourth on the commits carry `Backlog: T-56`
        # and credit themselves; these three are the catch-up.
        "6eb7e05": {"T-56"},   # the mirror learns the Flutter repo + the skill (#57)
        "d8499b5": {"T-56"},   # the DB gate moves house, 221 tests intact (#58)
        "3220a6a": {"T-56"},   # migrations, functions and the production backup (#59)
    },
}

REPOS = {
    # `app` is the FROZEN Blazor client and, for now, still the home of the backlog
    # records. Its ref stays `origin/dev`: that branch runs ahead of `master` and the
    # board is written from it (staleness rule of the working agreement).
    "app": {
        "ref": "origin/dev", "branch": "dev", "landing": False,
        "gh": "https://github.com/irineus/entrelares-app",
        "name": "entrelares-app",
        "files": ["backlog/features.md", "backlog/ui-ux.md",
                  "backlog/technical.md", "backlog/security.md"],
        "archive_glob": "backlog/archive/*.md",
    },
    # The product app since the T-53 cutover (23/08/2026). It carries no records YET —
    # they arrive with the archiving of the app repo; until then this entry exists to
    # contribute DELIVERIES to records that live elsewhere.
    "flutter": {
        "ref": "origin/main", "branch": "main", "landing": False,
        "gh": "https://github.com/irineus/entrelares-flutter",
        "name": "entrelares-flutter",
        "files": [], "archive_glob": None,
    },
    "landing": {
        "ref": "origin/preview", "branch": "preview", "landing": True,
        "gh": "https://github.com/irineus/entrelares-site",
        "name": "entrelares-site",
        "files": ["ROADMAP.md"], "archive_glob": None,
    },
}

# Session model for effort. Squash-merge collapses a whole PR into one timestamp, so this
# measures ELAPSED TIME between merges inside a working session, never time at the keyboard.
# Treat the numbers as relative magnitude, not measurement.
#
# It used to be described as understating "systematically", and that was only true while
# most commits went uncredited: an item picked up the cost of the few commits that named
# it and none of the rest. Now that a densely-delivered item collects every commit of its
# stage, the same walk can OVERSHOOT — it charges the item for the wall-clock gaps between
# merges, including the ones spent away from the work. Measured on 24/08/2026: T-53 went
# from 10,4 h (3 commits credited) to 28,0 h (41), against ~14 h of actual hands-on time
# reported by the owner. The error changed sign, and the three constants below are what
# would have to be retuned to fix it — a change that moves EVERY item on the board, so it
# is deliberately not made here (see `docs/arquivamento-app.md`).
SESSION_GAP, SESSION_START, MIN_COST = 120 * 60, 30 * 60, 15 * 60


def ids_in(text: str, landing: bool) -> set[str]:
    return set((L_RE if landing else ID_RE).findall(text))


def delivered_by(sha: str, subject: str, message: str, landing: bool,
                 hand: dict[str, set[str]]) -> set[str]:
    """Items this commit DELIVERS: the trailer, else the subject, else the hand review."""
    present = ids_in(message, landing)
    trailer = set()
    for m in TRAILER_RE.finditer(message):
        trailer |= ids_in(m.group(1), landing)
    if trailer:
        return trailer & present or trailer
    named = ids_in(subject, landing)
    if not landing:
        m = SCOPE_RE.match(subject)
        if m:
            named.add(f"{m.group(1).upper()}-{m.group(2)}")
    # The subject is part of the message, so `named` is present by construction; the
    # hand review stands on its own (see HAND_REVIEWED).
    return named | hand.get(sha, set())


def read_commits(repo: Path, cfg: dict, label: str) -> list[dict]:
    # encoding is explicit, not `text=True`: on Windows the latter decodes with the ANSI
    # locale (cp1252), the first accented commit message raises inside subprocess's reader
    # thread, and `.stdout` comes back None — surfacing as an AttributeError far from here.
    out = subprocess.run(
        ["git", "-C", str(repo), "log", "--no-merges",
         f"--format=%H|%at|%ad{SEP}%s%n%b{SEP}", "--date=short", cfg["ref"]],
        capture_output=True, encoding="utf-8", errors="replace", check=True).stdout
    landing, hand = cfg["landing"], HAND_REVIEWED.get(label, {})
    rows = []
    for rec in out.split(SEP + "\n"):
        if "|" not in rec:
            continue
        head, _, msg = rec.partition(SEP)
        sha, ts, date = head.strip().split("|")
        subject = msg.strip().split("\n")[0]
        sha = sha[:7]
        ent = delivered_by(sha, subject, msg, landing, hand)
        pr = re.search(r"\(#(\d+)\)\s*$", subject)
        rows.append({
            "sha": sha, "ts": int(ts), "date": date,
            # Each row carries its own origin: a record's page now lists commits from
            # more than one repository, and a link built from the RECORD's repo would
            # point at a sha that does not exist there.
            "repo": cfg["name"], "gh": cfg["gh"],
            "subj": re.sub(r"\s*\(#\d+\)\s*$", "", subject),
            "docs": bool(re.match(r"^docs[(:]", subject)),
            "ent": sorted(ent), "ctx": sorted(ids_in(msg, landing) - ent),
            "pr": int(pr.group(1)) if pr else None,
        })
    rows.sort(key=lambda r: r["ts"])
    return rows


def read_records(repo: Path, cfg: dict) -> dict[str, dict]:
    """One `### ID — Title` block per item. A heading may cover several IDs (they were
    delivered together); each of them gets the shared record."""
    pat = L_RE if cfg["landing"] else ID_RE
    files = list(cfg["files"])
    if cfg["archive_glob"]:
        files += sorted(str(p.relative_to(repo)).replace("\\", "/")
                        for p in repo.glob(cfg["archive_glob"]))
    out = {}
    for rel in files:
        parts = re.split(r"^(### .+)$", (repo / rel).read_text(encoding="utf-8"), flags=re.M)
        for i in range(1, len(parts), 2):
            ids = pat.findall(parts[i].split("—")[0])
            for _id in ids:
                out[_id] = {"body": parts[i + 1].rstrip(), "src": rel,
                            "shared": [x for x in ids if x != _id]}
    return out


def absolutize(md: str, gh: str, branch: str, srcdir: str) -> str:
    """Relative markdown links do not resolve inside Notion — point them at GitHub."""
    def fix(m):
        text, href = m.group(1), m.group(2)
        if re.match(r"^(https?:|#|mailto:)", href):
            return m.group(0)
        anchor = ""
        if "#" in href:
            href, rest = href.split("#", 1)
            anchor = "#" + rest
        target = posixpath.normpath(posixpath.join(srcdir, href))
        return f"[{text}]({gh}/blob/{branch}/{target}{anchor})"
    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", fix, md)


def strip_file_notes(body: str, _id: str) -> str:
    """Drop FILE-level trailing blocks the `###` split swept into the record — they belong to
    the file, not to the last item above them. Two kinds:
      * italic notes between entries ("F-16 + F-17 were completed in Phase 5 …");
      * a bare section heading introducing the NEXT group of entries — the roadmap's
        "## Off-site items — detail" sits after L-08 and used to land inside its record."""
    parts = [p.strip().rstrip("-").strip() for p in re.split(r"\n-{3,}\n", body)]
    while len(parts) > 1:
        last = parts[-1]
        only_note = last.startswith("_") and last.endswith("_") and "\n\n" not in last
        only_heading = bool(last) and all(re.match(r"^#{1,6} ", ln)
                                          for ln in last.splitlines() if ln.strip())
        if (not last or only_heading
                or (only_note and not re.search(rf"\b{re.escape(_id)}\b", last))):
            parts.pop()
        else:
            break
    return "\n\n---\n\n".join(p for p in parts if p)


def escape_plus(md: str) -> str:
    """`+` opens a markdown LIST, and the records use it as a plain conjunction. At the START of
    a line that silently rewrites the text: a hard-wrapped sentence ("…comparison table\\n+ price
    + CTA…") became a bullet in L-08 and the `+` itself vanished. Escaping restores the literal
    character — verified against Notion. Neither repo ever uses `+` as a genuine bullet (checked
    across every backlog file and the roadmap), so this is safe; `-`/`*` bullets are left alone.

    KNOWN, NOT FIXABLE HERE: inside a table cell, a `+` that directly follows INLINE CODE
    (`` `col` + trigger ``) is rendered by Notion as a bullet — "`col` • trigger" — and `\\+` does
    NOT stop it (the backslash is swallowed at the inline-code boundary; the same `\\+` one word
    later does render as `+`). Two cells in S-15 hit it. The only real cure is wording the source
    with "e"/"and" instead of `+` right after inline code."""
    def fix(line: str) -> str:
        return re.sub(r"^(\s*)\+(?=\s)", r"\1\\+", line)
    return "\n".join(fix(line) for line in md.split("\n"))


def commit_links(commits: list[dict]) -> str:
    return " · ".join(f"[`{c['sha']}`]({c['gh']}/commit/{c['sha']})" for c in commits)


def build_page(_id: str, rec: dict, cfg: dict, ent, ctx, doc) -> str:
    srcdir = posixpath.dirname(rec["src"])
    md = [escape_plus(
        strip_file_notes(absolutize(rec["body"], cfg["gh"], cfg["branch"], srcdir).strip(), _id))]
    if rec["shared"]:
        md.insert(0, "> Registro **compartilhado** com "
                     + ", ".join(f"**{s}**" for s in rec["shared"])
                     + " — foram entregues juntos, num único item de trabalho.\n")
    deliveries = sorted(ent.get(_id, []), key=lambda c: c["ts"])
    if deliveries:
        md.append("\n---\n\n## Entregas\n")
        # PR numbers are per repository — app #51 and flutter #51 are different PRs — so
        # they are grouped and labelled whenever an item was delivered in more than one.
        by_repo: dict[str, dict] = {}
        for c in deliveries:
            if c["pr"]:
                by_repo.setdefault(c["repo"], {"gh": c["gh"], "prs": set()})["prs"].add(c["pr"])
        if by_repo:
            groups = []
            for name, d in by_repo.items():
                links = " · ".join(f"[#{p}]({d['gh']}/pull/{p})" for p in sorted(d["prs"]))
                groups.append(links if len(by_repo) == 1 else f"`{name}` {links}")
            md.append("**PRs:** " + "  —  ".join(groups) + "\n")
        multi = len({c["repo"] for c in deliveries}) > 1
        for c in deliveries:
            where = f" _({c['repo']})_" if multi else ""
            md.append(f"- {c['date']} — [`{c['sha']}`]({c['gh']}/commit/{c['sha']}) "
                      f"{c['subj']}{where}")
    touched = sorted(ctx.get(_id, []), key=lambda c: c["ts"])
    if touched:
        md.append("\n**Tocado ou citado como contexto** (não é entrega deste item): "
                  + commit_links(touched))
    docs = sorted(doc.get(_id, []), key=lambda c: c["ts"])
    if docs:
        md.append("\n_Registro/ajuste de documentação: " + commit_links(docs) + "_")
    md.append(f"\n---\n\n_Fonte versionada: [`{rec['src']}`]({cfg['gh']}/blob/{cfg['branch']}/{rec['src']}) "
              f"no repositório `{cfg['name']}`. Este texto é um espelho gerado por "
              f"`tool/notion_mirror.py` — não edite aqui._")
    return "\n".join(md)


def compute_effort(all_rows: dict[str, list[dict]]) -> dict[str, dict]:
    """Hours land on the commits that DELIVER an item. An item with no delivery at all
    falls back to the commits that merely cite it — that is the only signal it has.

    The session walk runs over the UNION of the repos, ordered by time. A session belongs
    to the person, not to the repository: T-53 was delivered by merging into the app repo
    and the Flutter repo within the same hours, and walking each repo separately would
    open a new 30-minute session every time the work crossed from one to the other."""
    has_delivery = {i for rows in all_rows.values() for r in rows for i in r["ent"]}
    hours = collections.defaultdict(float)
    dates = collections.defaultdict(list)
    counts = collections.defaultdict(int)
    merged = sorted((r for rows in all_rows.values() for r in rows), key=lambda r: r["ts"])
    prev = None
    for r in merged:
        cost = SESSION_START if (prev is None or r["ts"] - prev > SESSION_GAP) \
            else max(r["ts"] - prev, MIN_COST)
        prev = r["ts"]
        targets = list(r["ent"]) + [i for i in r["ctx"] if i not in has_delivery]
        if not targets:
            continue
        for i in targets:
            hours[i] += cost / 3600 / len(targets)
            counts[i] += 1
            if i in r["ent"] and not r["docs"]:
                dates[i].append(r["ts"])
    day = lambda ts: datetime.datetime.fromtimestamp(ts, datetime.UTC).strftime("%Y-%m-%d")
    out = {}
    for i, h in hours.items():
        # floor of 0.5h per commit: squash-merge collapses a PR into one timestamp
        out[i] = {"effort_h": round(max(h, 0.5 * counts[i]), 1)}
        if dates[i]:
            out[i]["inicio"] = day(min(dates[i]))
            out[i]["fim"] = day(max(dates[i]))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    # Defaults assume the sibling checkout layout (…/repos/<name>), which is how the
    # three repos are cloned — the same assumption `tool/port_catalogs.py` makes. Pass a
    # path explicitly from a worktree.
    root = Path(__file__).resolve().parent.parent
    ap.add_argument("--flutter", default=str(root), help="path to the entrelares-flutter repo")
    ap.add_argument("--app", default=str(root.parent / "entrelares-app"),
                    help="path to the entrelares-app repo (records live here for now)")
    ap.add_argument("--landing", default=str(root.parent / "entrelares-site"),
                    help="path to the entrelares-site repo")
    ap.add_argument("-o", "--out", default="notion-mirror.json")
    args = ap.parse_args()

    paths = {"app": Path(args.app), "flutter": Path(args.flutter), "landing": Path(args.landing)}
    missing = [f"{label} ({p})" for label, p in paths.items() if not (p / ".git").exists()]
    if missing:
        print("not a git checkout: " + ", ".join(missing), file=sys.stderr)
        return 1

    # Pass 1 — every commit of every repo, classified into GLOBAL buckets. An item is
    # recorded in one repo and may be delivered in another, so these cannot be per repo.
    all_rows = {}
    ent, ctx, doc = (collections.defaultdict(list) for _ in range(3))
    for label, repo in paths.items():
        rows = read_commits(repo, REPOS[label], label)
        all_rows[label] = rows
        for r in rows:
            for i in r["ent"]:
                (doc if r["docs"] else ent)[i].append(r)
            for i in r["ctx"]:
                (doc if r["docs"] else ctx)[i].append(r)
        # The hand review is only as good as its shas: an entry that matches nothing is
        # a typo or a rebased commit, and silence would look exactly like "no deliveries".
        seen = {r["sha"] for r in rows}
        for sha in HAND_REVIEWED.get(label, {}):
            if sha not in seen:
                print(f"WARNING: HAND_REVIEWED[{label}][{sha}] matches no commit in "
                      f"{REPOS[label]['ref']}", file=sys.stderr)

    # Pass 2 — the records, wherever they live, fed by the global buckets.
    pages = {}
    for label, repo in paths.items():
        cfg = REPOS[label]
        for _id, rec in read_records(repo, cfg).items():
            pages[_id] = {
                "repo": label, "src": rec["src"],
                "page_content": build_page(_id, rec, cfg, ent, ctx, doc),
                # Repo-qualified on purpose: a bare number is ambiguous across repos.
                "prs": sorted({f"{c['gh']}/pull/{c['pr']}" for c in ent.get(_id, []) if c["pr"]}),
            }

    for _id, eff in compute_effort(all_rows).items():
        if _id in pages:
            pages[_id].update(eff)

    Path(args.out).write_text(json.dumps(pages, ensure_ascii=False, indent=1), encoding="utf-8")
    size = sum(len(p["page_content"]) for p in pages.values())
    linked = sum(1 for p in pages.values() if p["prs"])
    print(f"{len(pages)} items -> {args.out} ({size/1024:.0f} KB), {linked} with a PR linked",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
