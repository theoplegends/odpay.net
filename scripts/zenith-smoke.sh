#!/usr/bin/env bash
# Boots the given image and checks it actually serves odpay.net.
# Usage: scripts/zenith-smoke.sh <image-ref>
set -euo pipefail

image="${1:?usage: zenith-smoke.sh <image-ref>}"
container="zenith-smoke-$$"

cleanup() {
    docker logs "$container" 2>&1 | tail -n 100 || true
    docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$container" "$image" >/dev/null

deadline=$((SECONDS + 30))
until docker exec "$container" wget -q -O /dev/null http://localhost/ 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "zenith-smoke: timed out waiting for nginx to answer on :80" >&2
        exit 1
    fi
    sleep 1
done

body=$(docker exec "$container" wget -q -O - http://localhost/)
if ! grep -q "odpay.net" <<<"$body"; then
    echo "zenith-smoke: response body missing expected 'odpay.net' marker" >&2
    exit 1
fi

headers=$(docker exec "$container" wget -q -S -O /dev/null http://localhost/ 2>&1)
if ! grep -qi "^ *X-Frame-Options: SAMEORIGIN" <<<"$headers"; then
    echo "zenith-smoke: missing X-Frame-Options header from nginx.conf" >&2
    exit 1
fi

well_known=$(docker exec "$container" wget -q -O - http://localhost/.well-known/matrix/server)
if ! grep -q "m.server" <<<"$well_known"; then
    echo "zenith-smoke: /.well-known/matrix/server did not return expected JSON" >&2
    exit 1
fi

echo "zenith-smoke: ok"
