#!/usr/bin/env bash
# Verifies the freshly published image is anonymously pullable and bootable,
# then writes the zenith-image-update/ handoff: image.json always, plus an
# updated zenith-compose.yml and a patch once that manifest exists.
#
# Expected environment (set by .github/workflows/publish-container.yml):
#   IMAGE_TAGS    - newline/space separated tags from docker/metadata-action
#   IMAGE_DIGEST  - digest output from docker/build-push-action
#   SOURCE_SHA    - commit the image was built from
set -euo pipefail

: "${IMAGE_TAGS:?IMAGE_TAGS is required}"
: "${IMAGE_DIGEST:?IMAGE_DIGEST is required}"
: "${SOURCE_SHA:?SOURCE_SHA is required}"

repo_ref=$(head -n1 <<<"$IMAGE_TAGS" | cut -d: -f1)
image_ref="${repo_ref}@${IMAGE_DIGEST}"

echo "Resolved image reference: $image_ref"

attempt=0
max_attempts=6
until result=$(python3 scripts/zenith-check-image.py "$image_ref" 2>&1); do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max_attempts" ]; then
        echo "$result" >&2
        echo "zenith-prepare-image-update: registry check failed after ${max_attempts} attempts" >&2
        exit 1
    fi
    echo "zenith-prepare-image-update: registry not ready yet (attempt ${attempt}/${max_attempts}), retrying..." >&2
    sleep 10
done
echo "$result"

top_digest=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['digest'])" "$result")
verified_ref="${repo_ref}@${top_digest}"

# Anonymous pull + real boot. The registry check above only proves the manifest
# and config are readable; it says nothing about layers or runtime behavior.
tmp_docker_config=$(mktemp -d)
trap 'rm -rf "$tmp_docker_config"' EXIT
DOCKER_CONFIG="$tmp_docker_config" docker pull --platform linux/amd64 "$verified_ref"
DOCKER_CONFIG="$tmp_docker_config" bash scripts/zenith-smoke.sh "$verified_ref"

mkdir -p zenith-image-update

# Prepares the reviewable digest update. Replaces only the image of the service
# this workflow publishes, leaving every other service, comment and setting
# untouched; refuses to guess when that service is ambiguous.
python3 - "$verified_ref" "$repo_ref" "$SOURCE_SHA" <<'PY'
import difflib, json, os, pathlib, sys

verified_ref, repo_ref, source_sha = sys.argv[1:4]
server, repo, run_id = (os.environ.get(k, "") for k in
                        ("GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID"))

meta = {
    "image": verified_ref,
    "platform": "linux/amd64",
    "source_commit": source_sha,
    "workflow_run_url": f"{server}/{repo}/actions/runs/{run_id}" if run_id else None,
}

manifest = pathlib.Path("zenith-compose.yml")
out = pathlib.Path("zenith-image-update")

if manifest.exists():
    import yaml

    original = manifest.read_text()
    services = (yaml.safe_load(original) or {}).get("services") or {}
    owned = {
        name: (svc or {}).get("image")
        for name, svc in services.items()
        if str((svc or {}).get("image", "")).split("@")[0].split(":")[0] == repo_ref
    }

    if not owned:
        sys.exit(f"zenith-prepare-image-update: no service in {manifest} uses {repo_ref}; "
                 "refusing to guess which image to update")
    if len(owned) > 1:
        sys.exit(f"zenith-prepare-image-update: {sorted(owned)} all use {repo_ref}; "
                 "ambiguous, refusing to update")

    service, old_ref = next(iter(owned.items()))
    meta["service"] = service
    meta["previous_image"] = old_ref

    if old_ref == verified_ref:
        meta["update"] = "none: manifest already pins this digest"
        print(f"zenith-prepare-image-update: {manifest} already pins {verified_ref}, nothing to prepare")
    else:
        if original.count(old_ref) != 1:
            sys.exit(f"zenith-prepare-image-update: '{old_ref}' appears "
                     f"{original.count(old_ref)} times in {manifest}; refusing a broad replace")
        updated = original.replace(old_ref, verified_ref, 1)
        (out / manifest.name).write_text(updated)
        patch = "".join(difflib.unified_diff(
            original.splitlines(keepends=True), updated.splitlines(keepends=True),
            fromfile=f"a/{manifest.name}", tofile=f"b/{manifest.name}"))
        (out / f"{manifest.name}.patch").write_text(patch)
        meta["update"] = f"service '{service}': {old_ref} -> {verified_ref}"
        print(f"zenith-prepare-image-update: prepared {manifest.name} update for service '{service}'")
        print(patch)
else:
    meta["update"] = "bootstrap: zenith-compose.yml does not exist yet"

(out / "image.json").write_text(json.dumps(meta, indent=2) + "\n")
print(json.dumps(meta, indent=2))
PY

# A prepared manifest is only useful if it is still a valid submission.
if [ -f zenith-image-update/zenith-compose.yml ]; then
    docker compose -f zenith-image-update/zenith-compose.yml config --quiet
    python3 scripts/zenith-check-compose.py zenith-image-update/zenith-compose.yml
fi

echo "zenith-prepare-image-update: wrote zenith-image-update/"
ls -1 zenith-image-update/
