# romafederico.com docs

| Article | What it covers |
|---|---|
| [Deploy runbook](runbook-deploy.md) | Step by step: deploy to staging, release to the live site, roll back, restore a backup, change a secret; who does what. |
| [Deployment, configuration and secrets](deployment-and-configuration.md) | How it fits together: the package and `deploy/site-files`, `/version.json`, CI and the no-JavaScript rule, `deploy/environments/`, Parameter Store and the OIDC roles, the two gates and their allow-lists, the staging nginx server, release, rollback and backups. |
| [Plan page: deploys](https://claude.ai/artifact/WVTuuHUUDqA2t3bCrKDxqW) | The plan and diagram for the pipeline: main → staging automatically, published release → live. Shared with diegokravetz.com (its epic #72); this site's epic is #1. |

Previewing the site on your computer: [README](../README.md).
