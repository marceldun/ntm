#!/usr/bin/env python3
"""Accept token-bearing PCs and share this VPS's unique download folder."""
import argparse
import json
import pathlib
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


def api_key(config_path):
    return ET.parse(config_path).findtext("gui/apikey") or ""


def request(base, key, path, method="GET", value=None):
    data = None if value is None else json.dumps(value).encode()
    req = urllib.request.Request(
        base + "/rest/" + path,
        data=data,
        method=method,
        headers={"X-API-Key": key, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as response:
        body = response.read()
    return json.loads(body) if body else None


def reconcile(args):
    key = api_key(args.config)
    if not key:
        raise RuntimeError("Syncthing API key is missing")
    expected_name = "PC-" + pathlib.Path(args.token).read_text().strip()
    pending = request(args.api, key, "cluster/pending/devices") or {}
    config = request(args.api, key, "config")
    changed = False

    known = {item.get("deviceID") for item in config.get("devices", [])}
    for device_id, details in pending.items():
        if details.get("name") != expected_name or device_id in known:
            continue
        config.setdefault("devices", []).append({
            "deviceID": device_id,
            "name": "Windows-PC",
            "addresses": ["dynamic"],
            "compression": "metadata",
            "autoAcceptFolders": True,
            "paused": False,
        })
        known.add(device_id)
        changed = True

    for device in config.get("devices", []):
        if device.get("name") == "Windows-PC":
            if device.get("autoAcceptFolders") is not True:
                device["autoAcceptFolders"] = True
                changed = True
            if device.get("paused"):
                device["paused"] = False
                changed = True

    folder = next((item for item in config.get("folders", [])
                   if item.get("id") == args.folder_id), None)
    if folder:
        wanted_path = str(pathlib.Path(args.root) / args.folder_label)
        if folder.get("path") != wanted_path:
            folder["path"] = wanted_path
            changed = True
        shared = {item.get("deviceID") for item in folder.get("devices", [])}
        for device_id in (args.android,) + tuple(
                item.get("deviceID") for item in config.get("devices", [])
                if item.get("name") == "Windows-PC"):
            if device_id and device_id not in shared:
                folder.setdefault("devices", []).append({"deviceID": device_id})
                shared.add(device_id)
                changed = True

    if changed:
        request(args.api, key, "config", "PUT", config)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--android", required=True)
    parser.add_argument("--folder-id", required=True)
    parser.add_argument("--folder-label", required=True)
    parser.add_argument("--api", default="http://127.0.0.1:8384")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    while True:
        try:
            reconcile(args)
        except (OSError, RuntimeError, ValueError, urllib.error.URLError, ET.ParseError) as exc:
            print(f"enrollment retry: {exc}", flush=True)
        if args.once:
            return
        time.sleep(3)


if __name__ == "__main__":
    main()
