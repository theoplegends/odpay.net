#!/usr/bin/env bash
# Boots the given image and checks it actually serves odpay.net.
# Usage: scripts/zenith-smoke.sh <image-ref>
set -euo pipefail

image="${1:?usage: zenith-smoke.sh <image-ref>}"
container="zenith-smoke-$$"

# Probe 127.0.0.1, not localhost. nginx.conf replaces the stock default.conf,
# so the nginx entrypoint skips adding its `listen [::]:80` line, and musl
# resolves localhost to ::1 first -- the connection would be refused while
# nginx is perfectly healthy on IPv4.
origin="http://127.0.0.1"

ok=no
cleanup() {
    if [ "$ok" != yes ]; then
        echo "--- container logs ---" >&2
        docker logs "$container" 2>&1 | tail -n 100 >&2 || true
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$container" "$image" >/dev/null

deadline=$((SECONDS + 30))
until docker exec "$container" wget -q -O /dev/null "$origin/" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "zenith-smoke: timed out waiting for nginx to answer on :80" >&2
        echo "zenith-smoke: last probe output:" >&2
        docker exec "$container" wget -O /dev/null "$origin/" 2>&1 | sed 's/^/  /' >&2 || true
        exit 1
    fi
    sleep 1
done

body=$(docker exec "$container" wget -q -O - "$origin/")
if ! grep -q "odpay.net" <<<"$body"; then
    echo "zenith-smoke: response body missing expected 'odpay.net' marker" >&2
    exit 1
fi

# No -q here: busybox prints the -S header dump on stderr and quiet mode can
# swallow it.
headers=$(docker exec "$container" wget -S -O /dev/null "$origin/" 2>&1)
if ! grep -qi "^ *X-Frame-Options: SAMEORIGIN" <<<"$headers"; then
    echo "zenith-smoke: missing X-Frame-Options header from nginx.conf" >&2
    echo "$headers" | sed 's/^/  /' >&2
    exit 1
fi

well_known=$(docker exec "$container" wget -q -O - "$origin/.well-known/matrix/server")
if ! grep -q "m.server" <<<"$well_known"; then
    echo "zenith-smoke: /.well-known/matrix/server did not return expected JSON" >&2
    exit 1
fi

ok=yes
echo "zenith-smoke: ok"
