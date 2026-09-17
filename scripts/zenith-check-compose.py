#!/usr/bin/env python3
"""Check zenith-compose.yml against the hard rules in the Zenith compose contract.

A `docker compose config` parse proves the file is valid Compose; it does not
prove it is a valid Zenith submission. This checks the submission rules that
Compose itself is happy to accept.

Usage: scripts/zenith-check-compose.py [path]
"""
from __future__ import annotations

import re
import sys

import yaml

HEADER = "# https://zenith.hosting/developers"
MAX_BYTES = 128 * 1024
X_ZENITH_FIELDS = {"catalog", "expose", "storage", "configs", "env"}
STORAGE_FIELDS = {"volume", "label", "description", "default_size", "public"}
DNS_LABEL = re.compile(r"\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\Z")
QUANTITY = re.compile(r"\A[0-9]+(\.[0-9]+)?(Ki|Mi|Gi|Ti|K|M|G|T)?\Z")
INTERPOLATION = re.compile(r"\$(?!\$)\{?[A-Za-z_][A-Za-z0-9_]*\}?")
LEGACY_TOKEN = re.compile(r"\{\{ZENITH_[A-Z0-9_]*\}\}")

errors: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def walk_strings(node, path="") -> list[tuple[str, str]]:
    if isinstance(node, dict):
        out = []
        for k, v in node.items():
            out += walk_strings(v, f"{path}.{k}")
        return out
    if isinstance(node, list):
        out = []
        for i, v in enumerate(node):
            out += walk_strings(v, f"{path}[{i}]")
        return out
    if isinstance(node, str):
        return [(path, node)]
    return []


def is_bind_source(source: str) -> bool:
    return (
        source.startswith(("/", ".", "~"))
        or "/" in source
        or "$" in source
    )


def check_volumes(name: str, service: dict, declared: set[str]) -> None:
    for entry in service.get("volumes") or []:
        if isinstance(entry, str):
            parts = entry.split(":")
            if len(parts) == 1:
                continue  # anonymous volume
            source = parts[0]
            if is_bind_source(source):
                err(f"service '{name}': bind mount '{entry}' is rejected by Zenith")
            elif source not in declared:
                err(f"service '{name}': volume '{source}' is not a declared top-level volume")
        elif isinstance(entry, dict):
            if entry.get("type") == "bind":
                err(f"service '{name}': bind mount '{entry.get('source')}' is rejected by Zenith")
            elif entry.get("type") == "volume":
                source = entry.get("source")
                if source and source not in declared:
                    err(f"service '{name}': volume '{source}' is not a declared top-level volume")


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "zenith-compose.yml"

    try:
        raw = open(path, "rb").read()
    except OSError as exc:
        print(f"zenith-check-compose: cannot read {path}: {exc}", file=sys.stderr)
        return 1

    if not raw.strip():
        err("file is empty")
    if len(raw) > MAX_BYTES:
        err(f"file is {len(raw)} bytes, over the {MAX_BYTES} byte limit")

    text = raw.decode("utf-8")
    lines = text.splitlines()
    if not lines or lines[0] != HEADER:
        err(f"first line must be exactly '{HEADER}'")
    elif len(lines) < 2 or lines[1].strip():
        err("a blank line must follow the developer-page URL comment")

    doc = yaml.safe_load(text)
    if not isinstance(doc, dict):
        err("top level must be a mapping")
        print_errors()
        return 1

    for path_, value in walk_strings(doc):
        if INTERPOLATION.search(value):
            err(f"unresolved interpolation at {path_.lstrip('.')}: '{value}' -- "
                "use a fixed non-secret value or x-zenith.env")
        if LEGACY_TOKEN.search(value):
            err(f"legacy {{{{ZENITH_*}}}} token at {path_.lstrip('.')}: '{value}'")

    if "include" in doc:
        err("top-level 'include' is rejected by Zenith")

    for section in ("configs", "secrets"):
        for key, value in (doc.get(section) or {}).items():
            if isinstance(value, dict) and "file" in value:
                err(f"top-level {section}.{key} uses 'file', which Zenith cannot read")

    services = doc.get("services")
    if not isinstance(services, dict) or not services:
        err("at least one service is required")
        print_errors()
        return 1

    declared_volumes = set((doc.get("volumes") or {}).keys())
    labels: dict[str, str] = {}

    for name, service in services.items():
        service = service or {}
        label = str(name).replace("_", "-")
        key = label.lower()
        if key in labels and labels[key] != name:
            err(f"service names '{labels[key]}' and '{name}' collide as DNS label '{key}'")
        labels[key] = name
        if not DNS_LABEL.match(label):
            err(f"service '{name}' does not render as a DNS label")
        if label.startswith("zenith-ready-"):
            err(f"service '{name}' must not start with 'zenith-ready-'")
        if not service.get("image"):
            err(f"service '{name}' has no 'image'; Zenith does not build 'build:' entries")
        if "build" in service:
            err(f"service '{name}' declares 'build', which Zenith ignores")
        if "extends" in service:
            err(f"service '{name}' uses 'extends', which is rejected by Zenith")
        if "env_file" in service:
            err(f"service '{name}' uses 'env_file', which Zenith cannot read")
        check_volumes(name, service, declared_volumes)

    xz = doc.get("x-zenith")
    if not isinstance(xz, dict):
        err("'x-zenith' is required")
        print_errors()
        return 1

    unknown = set(xz) - X_ZENITH_FIELDS
    if unknown:
        err(f"unknown x-zenith fields fail the typed parser: {sorted(unknown)}")

    catalog = xz.get("catalog")
    if not isinstance(catalog, dict) or not str(catalog.get("name") or "").strip():
        err("x-zenith.catalog.name is required and must be non-empty")

    expose = xz.get("expose")
    if not isinstance(expose, list) or not expose:
        err("at least one x-zenith.expose entry is required")
    else:
        primaries = 0
        for i, entry in enumerate(expose):
            where = f"x-zenith.expose[{i}]"
            if not isinstance(entry, dict):
                err(f"{where} must be a mapping")
                continue
            service = entry.get("service")
            if service not in services:
                err(f"{where}.service '{service}' does not match a Compose service")
            port = entry.get("port")
            if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
                err(f"{where}.port must be an integer from 1 through 65535")
            if not isinstance(entry.get("web"), bool):
                err(f"{where}.web must be explicitly true or false")
            if not str(entry.get("label") or "").strip():
                primaries += 1
        if primaries > 1:
            err("more than one x-zenith.expose entry has no label; only one is the primary host")

    for key, entry in (xz.get("storage") or {}).items():
        where = f"x-zenith.storage.{key}"
        if not isinstance(entry, dict):
            err(f"{where} must be a mapping")
            continue
        unknown = set(entry) - STORAGE_FIELDS
        if unknown:
            err(f"{where} has unsupported fields: {sorted(unknown)}")
        volume = entry.get("volume")
        if volume not in declared_volumes:
            err(f"{where}.volume '{volume}' is not a declared top-level volume")
        elif (doc.get("volumes") or {}).get(volume, {}) and \
                (doc["volumes"][volume] or {}).get("external"):
            err(f"{where}.volume '{volume}' must not be external")
        size = entry.get("default_size")
        if size is not None and not QUANTITY.match(str(size)):
            err(f"{where}.default_size '{size}' is not a Kubernetes quantity such as 2Gi")

    print_errors()
    if errors:
        return 1
    print(f"zenith-check-compose: {path} satisfies the contract's hard rules "
          f"({len(services)} service(s))")
    return 0


def print_errors() -> None:
    for e in errors:
        print(f"zenith-check-compose: {e}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
