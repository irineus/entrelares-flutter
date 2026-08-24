# 📘 Pocket Guide: Git Flow (Dev → QA → Prod)

This guide documents a linear development flow using **Rebase** (to keep history clean and avoid unnecessary merge commits) and **Fast-Forward Merge** (to ensure environments remain exact mirrors of each other).

> **Single remote: GitHub (`origin`).** The GitLab mirror was retired in July 2026 —
> the local branches `gitlab_dev`/`github_dev`/`github_master` no longer exist; work
> happens on plain `dev` and `master`. Environment mapping: pushing **`dev`** deploys
> **QA** (Cloudflare Pages branch preview) and pushing **`master`** deploys
> **production** — both via the GitHub Actions workflow.

---

## 🧭 Golden Rules
1. ❌ **Never** commit directly to `dev` or `master` — they are the QA and production environments.
   > ⚠️ **The `master` ruleset IS enforced** (re-verified 22/08/2026, the hard way).
   > It requires the status check **"deploy"** to be green on the commit being
   > promoted, and it refuses the push otherwise — `GH013: Repository rule
   > violations found for refs/heads/master`. This paragraph used to say the
   > opposite ("pure discipline… nothing blocks a direct push"), written when the
   > repo went private in July 2026; whatever made that true then does not hold
   > now, so trust the error message over any claim in this file.
   >
   > The pipeline protects production on a second front: the prod steps only run
   > after the full test gate passes inside the same run. The ruleset is the
   > pre-push barrier, the pipeline is the deploy barrier, and a promotion has to
   > satisfy both.
2. 🔄 Keep your feature branch updated with `git rebase dev` (never use `git merge dev` in the feature branch).
3. 🚀 Promote code between the main branches using only `--ff-only`.
4. 🧹 Before rebasing or switching branches, make sure your working tree is clean (`git status`).
5. 🔒 After a rebase, if the feature branch had already been pushed before, update the remote branch with `git push --force-with-lease`.

---

## 🛠️ Terminal Command Sequence

### 1. Creating a New Feature
Always start from an up-to-date `dev` branch.

```bash
git checkout dev
git pull origin dev
git checkout -b feature/your-task-name
```

If this is the first time you push the branch, set the upstream:

```bash
git push -u origin feature/your-task-name
```

### 2. Working on the Feature
Commit normally in your feature branch while the work is in progress.

```bash
git add .
git commit -m "Describe your change"
```

You can push intermediate commits whenever needed:

```bash
git push
```

### 3. Syncing the Feature Before Opening the PR
Before sending your code for review, make sure your feature branch is rebased on top of the latest `dev`.

```bash
# Update local dev
git checkout dev
git pull origin dev

# Rebase the feature branch onto the latest dev
git checkout feature/your-task-name
git rebase dev
```

If the branch was never pushed before:

```bash
git push -u origin feature/your-task-name
```

If the branch was already pushed earlier, use:

```bash
git push --force-with-lease
```

> 💡 If rebase conflicts happen: fix the files, save them, run `git add <file>`, and then `git rebase --continue`.
>
> If you want to cancel the rebase and return to the previous state, run `git rebase --abort`.

### 4. Integrating into the `dev` Branch
Open a Pull Request from your feature branch into `dev` in **GitHub**.

Preferred merge options:
- **Rebase and merge**, or
- **Squash and merge**

Avoid creating a regular merge commit if the goal is to preserve a linear history.

After the PR is merged, update your local `dev` branch:

```bash
git checkout dev
git pull origin dev
```

Optional cleanup after merge:

```bash
git branch -d feature/your-task-name
git push origin --delete feature/your-task-name
```

### 5. Promoting to QA
QA **is** the `dev` branch: merging the PR (step 4) — or pushing `dev` — triggers the
QA pipeline (GitHub Actions → Cloudflare Pages branch preview). No extra promotion
step exists anymore; just make sure your local `dev` mirrors the remote:

```bash
git checkout dev
git pull origin dev
```

> If `dev` carries commits made locally (e.g. a hotfix committed straight on `dev`),
> pushing it is what deploys QA:
>
> ```bash
> git push origin dev
> ```

### 6. Promoting to PROD
After QA validation is complete, replicate the exact same history to production.

```bash
git checkout dev
git pull origin dev
git checkout master
git pull origin master
git merge dev --ff-only
git push origin master
```

This push triggers the production pipeline.

---

## ✅ Expected Flow Summary
- Development happens only in `feature/*` branches.
- Features are reviewed and merged into `dev` via GitHub PR — that merge **deploys QA**.
- `dev` is promoted to `master` with `--ff-only` — that push **deploys production**.
- `master` should always be an exact mirror of code already validated on QA (`dev`).

---

## ⚠️ Quick Troubleshooting

* **`git merge --ff-only` failed?**  
  This means the target branch history has diverged or your local branches are outdated. Run `git pull origin <branch>` on both branches involved and verify whether any direct commit was made where it should not have been.

* **The rebase has conflicts?**  
  Resolve the conflicts, run `git add <file>`, then `git rebase --continue`. Repeat until the rebase finishes.

* **Need to cancel a rebase?**  
  Run `git rebase --abort`.

* **Made a bad commit and want to undo it before pushing?**  
  Use `git reset --soft HEAD~1` to remove the last commit while keeping the changes in your working tree.

* **Tried to push after a rebase and Git rejected it?**  
  That is expected because the commit history changed. Use `git push --force-with-lease` instead of a normal push.

* **Push to `master` refused with `GH013 … Required status check "deploy" is cancelled`?**
  The ruleset wants the check green on the commit you are promoting, and that commit
  carries a **cancelled** one. The usual cause is self-inflicted: `deploy.yml` uses
  `concurrency: pages-${{ github.ref_name }}` with `cancel-in-progress: true`, so
  firing a `workflow_dispatch` on `dev` while the merge's own push run is still going
  kills that push run — leaving a cancelled `deploy` on the commit even though the
  dispatch itself went green. Two check runs, one success and one cancelled, and the
  rule counts the cancelled one.
  Fix: `gh run rerun <id>` on the cancelled run and wait for it to finish. Avoid it by
  letting the push run finish before dispatching, or by dispatching FIRST and letting
  it be the run that carries the commit.

* **`gh pr create` fails with "No commits between dev and <branch>"?**
  Check that `dev` still exists on the remote (`git ls-remote --heads origin`). A
  `dev` → `master` promotion opened as a PR gets marked merged when the ff push lands,
  and GitHub then offers **Delete branch** — whose head branch is `dev` itself.
  Clicking it deletes the QA branch. Restore it at the sha the closed PR records:
  `git push origin <sha>:refs/heads/dev`. Never use that button on a promotion PR.

* **Can I commit directly to `dev` or `master` in an emergency?**  
  No. Even emergency fixes should start from a feature or hotfix branch and then follow the same promotion path so the environments stay aligned.
