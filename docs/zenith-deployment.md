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
  IPv4 only: because `nginx.conf` replaces the stock `default.conf`, the
  image entrypoint skips the `listen [::]:80` line it adds to the packaged
  config, and hardcoding one would break startup on hosts without IPv6.
  Anything probing the container must use `127.0.0.1`, not `localhost`.
- **Platform**: `linux/amd64` only, built and verified in CI. Local ARM
  clusters are a separate development concern.
- **Persistent storage**: none. Content is baked into the image at build time.
- **Environment variables**: none. The app has no configurable settings and
  no outbound mail, so `zenith-compose.yml` declares no `x-zenith.env` and no
  SMTP wiring.

## Zenith manifest

`zenith-compose.yml` at the repository root declares one service, `web`,
pinned to an immutable GHCR digest, and exposes its port 80 as the primary
public host. There are no volumes, no environment, and no second service,
because the site needs none of them.

Two checks run against it in CI, and both matter:

- `docker compose -f zenith-compose.yml config --quiet` proves it is valid
  Compose.
- `scripts/zenith-check-compose.py` proves it is a valid *Zenith submission*,
  which Compose has no opinion about: the developer-page header comment,
  service images present, no `build`/`extends`/`env_file`/`include`, no bind
  mounts, no unresolved `${VAR}`, service names that survive as DNS labels,
  and a well-formed `x-zenith` block whose `expose` entries point at real
  services.

## CI: build, verify, publish

Workflow: `.github/workflows/publish-container.yml`.

**Every PR** builds the `linux/amd64` image and runs `scripts/zenith-smoke.sh`
against it (boots the container, checks the homepage body, checks the
`X-Frame-Options` header from `nginx.conf`, checks `/.well-known/matrix/server`),
then validates the manifest as above. This job is deliberately *not* path
filtered, so a change to any script or to the manifest is still checked.

**Publication** is path filtered to the Dockerfile build context only —
`index.html`, `pgp.txt`, the badges, `_headers`, `files/**`, `.well-known/**`,
`Dockerfile`, `nginx.conf`, `.dockerignore`. Everything else in the repository,
including `scripts/`, `docs/`, `.github/` and `zenith-compose.yml`, is in
`.dockerignore` and cannot change the image. Republishing on those would mint
a new digest and immediately stale the manifest that was just merged, which is
the update loop this filter exists to prevent. Use `workflow_dispatch` to force
a rebuild.

On a qualifying push to `master` or a `v*` tag, the image is pushed to
`ghcr.io/theoplegends/odpay.net` and `scripts/zenith-prepare-image-update.sh`:

1. resolves the published top-level digest with `scripts/zenith-check-image.py`
   (anonymous registry check, retried for propagation delay),
2. pulls that exact digest with a clean, empty `DOCKER_CONFIG` and reruns the
   smoke test against it, proving anonymous pull and real boot rather than just
   a readable manifest,
3. rewrites the `web` service's pinned digest in a *copy* of
   `zenith-compose.yml`, and writes that copy, a unified patch, and
   `image.json` (verified reference, previous reference, source commit, run
   URL) to `zenith-image-update/`,
4. re-validates that rewritten manifest with both checks above,
5. uploads the directory as the `zenith-image-<commit>` artifact.

The rewrite only ever touches the service whose image is
`ghcr.io/theoplegends/odpay.net`. If no service matches, or more than one
does, it fails rather than guessing; if the manifest already pins the new
digest it exits cleanly with nothing to prepare.

## Updating the pinned digest

CI has no repository write access, by design. The artifact is a *prepared*
update, not an applied one:

1. Change site content, open a PR, merge it. The publish run produces the
   artifact.
2. Download it, confirm its `source_commit` is still the current `master` and
   that no newer image build has superseded it, then apply
   `zenith-compose.yml.patch` on a branch and open a PR.
3. Merge that PR. It touches only `zenith-compose.yml`, so it does not
   publish another image.

A rebuilt image does not change the pinned digest, and merging a digest
update does not update anything running on Zenith.

## Zenith submission

1. ~~Containerization PR merges, CI publishes the image to GHCR, anonymous
   pull and boot verified.~~ Done.
2. Compose PR adds `zenith-compose.yml` pinned to that verified digest, and
   merges.
3. The repository owner returns to Zenith's **Publish an app** page and
   submits the repository for review.

Merging these PRs does not itself deploy or update anything on Zenith, and a
later image build does not update the Zenith catalogue or any running
customer deployment.

Local Docker is optional for development; it is not required to validate this
pipeline, since CI performs the real build and boot checks.
