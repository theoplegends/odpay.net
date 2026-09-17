# Zenith deployment

## What this is

odpay.net is a static site with no build step and no backend: `index.html`,
`pgp.txt`, the webring badges, `files/img/**`, and the Matrix federation
files under `.well-known/matrix/`. There is no database, queue, or worker.

## Container

- **Build context**: repository root, `Dockerfile`.
- **Base image**: `nginx:1.27-alpine`, pinned by digest in the `Dockerfile`.
- **Runtime config**: `nginx.conf`, mounted over `/etc/nginx/conf.d/default.conf`.
  It reproduces the response headers that were previously declared in the
  Cloudflare Pages `_headers` file (nginx does not read that file natively),
  and serves `/.well-known/matrix/*` as `application/json`.
- **Internal port**: `80` (plain HTTP; Zenith terminates TLS in front of it).
- **Platform**: `linux/amd64` only, built and verified in CI. Local ARM
  clusters are a separate development concern.
- **Persistent storage**: none. Content is baked into the image at build time.
- **Environment variables**: none. The app has no configurable settings and
  no outbound mail, so `zenith-compose.yml` declares no `x-zenith.env` and no
  SMTP wiring.

## CI: build, verify, publish

Workflow: `.github/workflows/publish-container.yml`.

- Every PR builds the `linux/amd64` image and runs `scripts/zenith-smoke.sh`
  against it (boots the container, checks the homepage body, checks the
  `X-Frame-Options` header from `nginx.conf`, checks
  `/.well-known/matrix/server`).
- On push to `master` or a `v*` tag, the image is built and pushed to
  `ghcr.io/theoplegends/odpay.net`, then `scripts/zenith-prepare-image-update.sh`:
  1. resolves the published digest with `scripts/zenith-check-image.py`
     (anonymous registry check, retried for propagation delay),
  2. pulls that exact digest with a clean, empty `DOCKER_CONFIG` and reruns
     the smoke test against it, proving anonymous pull + real boot rather
     than just a manifest check,
  3. writes `zenith-image-update/image.json` (verified image reference,
     source commit, workflow run URL) as a workflow artifact.

That artifact is the handoff for the next step: turning it into a reviewed
PR that updates the pinned digest in `zenith-compose.yml` (once that file
exists) or, on first bootstrap, into the initial `zenith-compose.yml` PR
itself.

## Zenith submission

1. Containerization PR merges → CI publishes the image to GHCR → anonymous
   pull/boot verified.
2. Compose PR adds `zenith-compose.yml` (repository root), pinned to the
   verified digest from step 1, and merges.
3. The repository owner returns to Zenith's **Publish an app** page and
   submits the repository for review. Merging these PRs does not itself
   deploy or update anything on Zenith.

Local Docker is optional for development; it is not required to validate
this pipeline since CI performs the real build/boot checks.
