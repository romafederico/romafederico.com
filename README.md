# romafederico.com

Personal consulting site for Federico Roma. Pure HTML + CSS, no build step.

## Deployment

Merging to `main` changes **staging only** (`https://staging.romafederico.com`,
behind a password). The live site changes only when Federico publishes a
`vX.Y.Z` release; until `v1.0.0` it stays as it is. The old rsync deploy
(`deploy.yml`) was removed in #11: **Release live** and **Rollback live** are
the only ways to change the live site.

How it works and how to run it: [`docs/`](docs/index.md), with the
[deploy runbook](docs/runbook-deploy.md) and
[deployment, configuration and secrets](docs/deployment-and-configuration.md).
Adding a page or image means adding it to `deploy/site-files`.

## Local preview

```
python3 -m http.server 8000
```

Then visit <http://localhost:8000>.
