#!/usr/bin/env bash
# Verifies the freshly published image is anonymously pullable and bootable,
# then writes zenith-image-update/image.json as the handoff for the compose PR.
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

tmp_docker_config=$(mktemp -d)
trap 'rm -rf "$tmp_docker_config"' EXIT
DOCKER_CONFIG="$tmp_docker_config" docker pull --platform linux/amd64 "$verified_ref"
DOCKER_CONFIG="$tmp_docker_config" bash scripts/zenith-smoke.sh "$verified_ref"

mkdir -p zenith-image-update
python3 - "$verified_ref" "$SOURCE_SHA" "${GITHUB_SERVER_URL:-}" "${GITHUB_REPOSITORY:-}" "${GITHUB_RUN_ID:-}" <<'PY' > zenith-image-update/image.json
import json, sys

image_ref, source_sha, server_url, repository, run_id = sys.argv[1:6]
run_url = f"{server_url}/{repository}/actions/runs/{run_id}" if server_url and repository and run_id else None

json.dump({
    "image": image_ref,
    "platform": "linux/amd64",
    "source_commit": source_sha,
    "workflow_run_url": run_url,
}, sys.stdout, indent=2)
print()
PY

cat zenith-image-update/image.json
echo "zenith-prepare-image-update: wrote zenith-image-update/image.json"
