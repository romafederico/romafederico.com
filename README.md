# romafederico.com

Personal consulting site for Federico Roma. Pure HTML + CSS, no build step.

## Deployment

On push to `main`, GitHub Actions rsyncs the repo to the racelab server at
`/home/romafederico/romafederico.com/`. Nginx on the racelab stack serves it at
the `/romafederico/` route. See `racelab/nginx/racelab.conf` in the racelab repo
for the location block and volume mount.

### Required GitHub secrets

Reuse the racelab repo's deploy key:

- `DEPLOY_HOST` — `66.179.251.96`
- `DEPLOY_USER` — `romafederico`
- `DEPLOY_SSH_KEY` — private SSH key

## Local preview

```
python3 -m http.server 8000
```

Then visit <http://localhost:8000>.
