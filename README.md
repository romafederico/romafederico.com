# romafederico.com

Personal consulting site for Federico Roma. Pure HTML + CSS, no build step.

## Deployment

Merging to `main` changes **staging only**; the live site changes only when
Federico publishes a `v*` release (being built, epic #1 — until v1.0.0 the live
site does not change).

```mermaid
flowchart LR
  PR[Pull request] -->|CI| Merge[Merge to main]
  Merge -->|CI + package| Artifact["package artifact, kept 90 days"]
  Artifact -->|Deploy staging| Staging["staging.romafederico.com"]
  Staging -->|"staging/deploy status = sha256"| Proof[Passed staging]
```

- **CI** (`.github/workflows/ci.yml`) runs on every pull request and push to
  `main`: `html` (W3C Nu checker, HTML and CSS), `links` (internal links and
  image paths), `page-load` (headless Chromium, no errors), `no-js` (the site
  stays HTML + CSS only), `scripts` (shellcheck, actionlint, deploy tests) and
  `package`.
- **Package** (`deploy/build-package.sh`): one `.tar.gz` per commit with a
  sha256, holding exactly the files listed in `deploy/site-files`. Adding a page
  or image means adding it there. On `main` CI uploads it as the artifact
  `package-<sha>`.
- **Staging** (`.github/workflows/deploy-staging.yml`): after CI passes on
  `main`, `deploy/deploy.sh --env staging` installs that commit's package
  (never rebuilt) on the dev server through `deploy-gate-rf`, then
  `deploy/smoke-test.sh` checks the site. The result is the commit status
  `staging/deploy`; `https://staging.romafederico.com/version.json` shows the
  installed commit. Staging is behind basic auth and `noindex`.
- **Rollback live** (`.github/workflows/rollback-live.yml`, #12): on Federico's
  order only, Actions → Rollback live → Run workflow with "Use workflow from" =
  the earlier tag `vA.B.C`. It reinstalls that release's own package through
  `deploy/deploy.sh --env live --rollback vA.B.C` (same guards as a release,
  backup `rollback-vA-B-C` first, then the smoke test) and adds a line under
  `## Live rollbacks` in that release's notes. `dry_run` is on by default.
- Settings are committed in `deploy/environments/`; secrets live in AWS
  Parameter Store under `/romafederico/staging/*`, read through a GitHub OIDC
  role. The staging deploy uses no GitHub secrets.
- The old `.github/workflows/deploy.yml` (rsync to DreamHost on every push) is
  disabled and will be removed by #11.

## Local preview

```
python3 -m http.server 8000
```

Then visit <http://localhost:8000>.
