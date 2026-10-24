#!/usr/bin/env python3
"""Prove a web-created folder becomes a pending offer on a real second Syncthing peer."""
import base64
import hashlib
import http.cookiejar
import json
import os
import pathlib
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

HERE = pathlib.Path(__file__).resolve().parents[1]
APP = HERE / "cloud-drive" / "app.py"
INDEX = HERE / "cloud-drive" / "index.html"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def b64(value):
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


class RealSyncthingInvitationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("syncthing"):
            raise unittest.SkipTest("syncthing binary is required")
        cls.temp = tempfile.TemporaryDirectory(prefix="v11-real-invite-")
        cls.base_dir = pathlib.Path(cls.temp.name)
        cls.processes = []
        cls.peers = []
        for name in ("vps", "android"):
            home = cls.base_dir / name
            subprocess.run(["syncthing", "generate", f"--home={home}"], check=True,
                           stdout=subprocess.DEVNULL)
            gui_port, sync_port = free_port(), free_port()
            process = subprocess.Popen([
                "syncthing", "serve", f"--home={home}", "--no-browser", "--no-restart",
                "--no-upgrade", "--no-default-folder", f"--gui-address=127.0.0.1:{gui_port}",
                "--logflags=0",
            ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            cls.processes.append(process)
            api_key = cls.xml_value(home / "config.xml", "gui/apikey")
            peer = {"home": home, "gui": gui_port, "sync": sync_port, "key": api_key,
                    "api": f"http://127.0.0.1:{gui_port}", "process": process}
            cls.wait_api(peer)
            peer["id"] = cls.api(peer, "system/status")["myID"]
            config = cls.api(peer, "config")
            config["options"].update({
                "listenAddresses": [f"tcp://127.0.0.1:{sync_port}"],
                "globalAnnounceEnabled": False,
                "localAnnounceEnabled": False,
                "relaysEnabled": False,
                "natEnabled": False,
                "reconnectionIntervalS": 1,
            })
            cls.api(peer, "config", "PUT", config)
            cls.peers.append(peer)
        cls.vps, cls.android = cls.peers
        cls.add_device(cls.vps, cls.android, f"tcp://127.0.0.1:{cls.android['sync']}")
        cls.add_device(cls.android, cls.vps, f"tcp://127.0.0.1:{cls.vps['sync']}")
        cls.wait_connected()
        cls.start_drive()

    @classmethod
    def tearDownClass(cls):
        for process in getattr(cls, "processes", []):
            process.terminate()
        for process in getattr(cls, "processes", []):
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
        if hasattr(cls, "temp"):
            cls.temp.cleanup()

    @staticmethod
    def xml_value(path, element):
        import xml.etree.ElementTree as ET
        return ET.parse(path).findtext(element) or ""

    @classmethod
    def api(cls, peer, path, method="GET", body=None):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            peer["api"] + "/rest/" + path, data=data, method=method,
            headers={"X-API-Key": peer["key"], "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            payload = response.read()
        return json.loads(payload) if payload else None

    @classmethod
    def wait_api(cls, peer):
        for _ in range(100):
            try:
                cls.api(peer, "system/status")
                return
            except Exception:
                if peer["process"].poll() is not None:
                    raise RuntimeError(peer["process"].stderr.read().decode(errors="replace"))
                time.sleep(0.1)
        raise RuntimeError("Syncthing API did not start")

    @classmethod
    def add_device(cls, local, remote, address):
        config = cls.api(local, "config")
        if not any(item.get("deviceID") == remote["id"] for item in config.get("devices", [])):
            config.setdefault("devices", []).append({
                "deviceID": remote["id"], "name": remote["home"].name,
                "addresses": [address], "compression": "metadata",
            })
        cls.api(local, "config", "PUT", config)

    @classmethod
    def wait_connected(cls):
        for _ in range(150):
            try:
                connections = cls.api(cls.android, "system/connections")["connections"]
                if connections.get(cls.vps["id"], {}).get("connected"):
                    return
            except Exception:
                pass
            time.sleep(0.1)
        raise RuntimeError("the real Syncthing peers did not connect")

    @classmethod
    def start_drive(cls):
        root = cls.base_dir / "drive-root"
        static = cls.base_dir / "static"
        upload_temp = cls.base_dir / "upload-temp"
        root.mkdir(); static.mkdir(); upload_temp.mkdir()
        (static / "index.html").write_bytes(INDEX.read_bytes())
        cert, key = cls.base_dir / "cert.pem", cls.base_dir / "key.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
            "-keyout", str(key), "-out", str(cert),
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        salt = secrets.token_bytes(16)
        env = os.environ.copy()
        env.update({
            "DRIVE_USERNAME": "marcel",
            "DRIVE_PASSWORD_SALT": b64(salt),
            "DRIVE_PASSWORD_HASH": b64(hashlib.pbkdf2_hmac("sha256", b"456qwe456", salt, 310_000)),
            "DRIVE_SESSION_SECRET": b64(secrets.token_bytes(32)),
            "SYNCTHING_API_URL": cls.vps["api"],
            "SYNCTHING_API_KEY": cls.vps["key"],
            "SYNCTHING_ANDROID_DEVICE_ID": cls.android["id"],
        })
        cls.drive_port = free_port()
        cls.drive = subprocess.Popen([
            sys.executable, str(APP), "--root", str(root), "--static", str(static),
            "--temp", str(upload_temp), "--host", "127.0.0.1", "--port", str(cls.drive_port),
            "--cert", str(cert), "--key", str(key),
        ], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        cls.processes.append(cls.drive)
        context = ssl._create_unverified_context()
        cls.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
            urllib.request.HTTPSHandler(context=context),
        )
        cls.drive_url = f"https://127.0.0.1:{cls.drive_port}"
        for _ in range(80):
            try:
                cls.opener.open(cls.drive_url + "/", timeout=1).close()
                break
            except Exception:
                time.sleep(0.1)
        cls.drive_json("/api/login", {"username": "marcel", "password": "456qwe456"})

    @classmethod
    def drive_json(cls, path, body):
        request = urllib.request.Request(
            cls.drive_url + path, data=json.dumps(body).encode(), method="POST",
            headers={"Content-Type": "application/json"},
        )
        with cls.opener.open(request, timeout=10) as response:
            return json.load(response)

    def test_web_folder_reaches_android_as_pending_invitation(self):
        result = self.drive_json("/api/mkdir", {"path": "", "name": "手机邀请测试"})
        self.assertTrue(result["androidInvitation"])
        folders = self.api(self.vps, "config/folders")
        shared = next(folder for folder in folders if folder["label"] == "手机邀请测试")
        self.assertIn(self.android["id"], {device["deviceID"] for device in shared["devices"]})
        for _ in range(150):
            pending = self.api(self.android, "cluster/pending/folders") or {}
            if shared["id"] in pending:
                break
            time.sleep(0.1)
        else:
            self.fail("the Android peer never received the pending folder invitation")
        self.assertIn(self.vps["id"], pending[shared["id"]]["offeredBy"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
