#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import os
import re
import urllib.request
from pathlib import Path

REPO = os.environ["GITHUB_REPOSITORY"]
TOKEN = os.environ["GH_TOKEN"]
RUN_ID = os.environ["GITHUB_RUN_ID"]
PROVIDER_PATH = "subscriptions/japan-live-provider.yaml"
STATUS_PATH = "subscriptions/japan-rolling-status.json"
SUB_PATH = Path("/tmp/sub.yaml")

HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "qifu-japan-vpn-rolling",
}


def api_url(path: str) -> str:
    return f"https://api.github.com/repos/{REPO}/contents/{path}"


def get_file(path: str):
    req = urllib.request.Request(api_url(path), headers=HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
        raw = base64.b64decode(data.get("content", "")).decode("utf-8", "replace")
        return raw, data.get("sha", "")
    except Exception:
        return "", ""


def put_file(path: str, text: str, message: str):
    _, sha = get_file(path)
    payload = {
        "message": message,
        "content": base64.b64encode(text.encode("utf-8")).decode("ascii"),
    }
    if sha:
        payload["sha"] = sha
    req = urllib.request.Request(
        api_url(path),
        data=json.dumps(payload).encode("utf-8"),
        headers={**HEADERS, "Content-Type": "application/json"},
        method="PUT",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()


def proxy_section_from_sub(text: str) -> str:
    if "proxies:\n" not in text or "proxy-groups:\n" not in text:
        raise SystemExit("sub.yaml does not contain expected proxies/proxy-groups sections")
    section = text.split("proxies:\n", 1)[1].split("proxy-groups:\n", 1)[0].rstrip()
    section = re.sub(
        r'(?m)^(\s*- name:)\s*.*$',
        rf'\1 "🇯🇵 日本VPN-{RUN_ID}"',
        section,
        count=1,
    )
    if not re.search(r"(?m)^\s+server:\s*\S+", section):
        raise SystemExit("current proxy entry has no server")
    if not re.search(r"(?m)^\s+uuid:\s*\S+", section):
        raise SystemExit("current proxy entry has no uuid")
    return section + "\n"


def split_proxy_entries(provider_text: str):
    if "proxies:\n" not in provider_text:
        return []
    body = provider_text.split("proxies:\n", 1)[1]
    starts = [m.start() for m in re.finditer(r"(?m)^  - name:", body)]
    if not starts:
        return []
    entries = []
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(body)
        entry = body[start:end].rstrip() + "\n"
        if re.search(r"(?m)^\s+server:\s*\S+", entry):
            entries.append(entry)
    return entries


def server_of(entry: str) -> str:
    m = re.search(r"(?m)^\s+server:\s*([^\s#]+)", entry)
    return m.group(1) if m else ""


def run_id_of(entry: str) -> str:
    m = re.search(r"日本VPN-(\d+)", entry)
    return m.group(1) if m else ""


current_sub = SUB_PATH.read_text(encoding="utf-8", errors="replace")
current = proxy_section_from_sub(current_sub)
current_server = server_of(current)

old_text, _ = get_file(PROVIDER_PATH)
old_entries = split_proxy_entries(old_text)
previous = None
for entry in old_entries:
    if server_of(entry) and server_of(entry) != current_server:
        previous = entry
        break

provider = (
    "# Qifu rolling Japan VPN provider\n"
    f"# Current verified generation: {RUN_ID}\n"
    "# The previous generation is kept as a short overlap fallback.\n"
    "proxies:\n"
    + current
)
if previous:
    provider += previous

put_file(PROVIDER_PATH, provider, f"Rotate Japan VPN provider to run {RUN_ID}")

status = {
    "ready": True,
    "current_run_id": RUN_ID,
    "current_server": current_server,
    "previous_run_id": run_id_of(previous or "") or None,
    "previous_server": server_of(previous or "") or None,
    "provider_path": PROVIDER_PATH,
    "stable_subscription_path": "subscriptions/japan-rolling.yaml",
}
put_file(STATUS_PATH, json.dumps(status, ensure_ascii=False, indent=2) + "\n", f"Update Japan VPN rolling status {RUN_ID}")

print(json.dumps(status, ensure_ascii=False, indent=2))
