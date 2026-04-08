# romafederico.com

Personal consulting site for Federico Roma. Pure HTML + CSS, no build step.

## Deployment

On push to `main`, GitHub Actions rsyncs the repo to DreamHost at
`/home/romafederico/romafederico.com/`. Mirrors the marielgaribaldi.com
deployment setup.

### Required GitHub secret

- `DREAMHOST_SSH_KEY` — private SSH key for the `romafederico` user on
  `pdx1-shared-a1-22.dreamhost.com`.

## Local preview

```
python3 -m http.server 8000
```

Then visit <http://localhost:8000>.
