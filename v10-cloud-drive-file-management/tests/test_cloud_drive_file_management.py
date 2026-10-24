#!/usr/bin/env python3
"""End-to-end HTTPS tests for V10 file and folder management."""
import base64
import hashlib
import http.cookiejar
import json
import os
import pathlib
import secrets
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parents[1]
APP = HERE / "cloud-drive" / "app.py"
INDEX = HERE / "cloud-drive" / "index.html"


def b64(value):
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


class CloudDriveManagementTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="cloud-drive-v10-")
        cls.base_dir = pathlib.Path(cls.temp.name)
        cls.root = cls.base_dir / "root"
        cls.static = cls.base_dir / "static"
        cls.upload_temp = cls.base_dir / "temp"
        cls.root.mkdir()
        cls.static.mkdir()
        cls.upload_temp.mkdir()
        (cls.static / "index.html").write_bytes(INDEX.read_bytes())
        cls.cert = cls.base_dir / "cert.pem"
        cls.key = cls.base_dir / "key.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
            "-keyout", str(cls.key), "-out", str(cls.cert),
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            cls.port = sock.getsockname()[1]
        salt = secrets.token_bytes(16)
        env = os.environ.copy()
        env.update({
            "DRIVE_USERNAME": "marcel",
            "DRIVE_PASSWORD_SALT": b64(salt),
            "DRIVE_PASSWORD_HASH": b64(hashlib.pbkdf2_hmac("sha256", b"456qwe456", salt, 310_000)),
            "DRIVE_SESSION_SECRET": b64(secrets.token_bytes(32)),
        })
        cls.process = subprocess.Popen([
            sys.executable, str(APP), "--root", str(cls.root), "--static", str(cls.static),
            "--temp", str(cls.upload_temp), "--host", "127.0.0.1", "--port", str(cls.port),
            "--cert", str(cls.cert), "--key", str(cls.key),
        ], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        context = ssl._create_unverified_context()
        cls.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
            urllib.request.HTTPSHandler(context=context),
        )
        cls.base = f"https://127.0.0.1:{cls.port}"
        for _ in range(80):
            try:
                cls.opener.open(cls.base + "/", timeout=1).close()
                break
            except Exception:
                if cls.process.poll() is not None:
                    raise RuntimeError(cls.process.stderr.read().decode(errors="replace"))
                time.sleep(0.1)
        else:
            raise RuntimeError("cloud drive did not start")
        cls.json_request("/api/login", {"username": "marcel", "password": "456qwe456"})

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        try:
            cls.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.process.kill()
        cls.temp.cleanup()

    @classmethod
    def json_request(cls, path, body=None):
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
        request = urllib.request.Request(
            cls.base + path, data=data,
            headers={"Content-Type": "application/json"} if data is not None else {},
        )
        with cls.opener.open(request, timeout=10) as response:
            return response.status, json.load(response)

    @classmethod
    def upload(cls, directory, name, payload):
        url = (cls.base + "/api/upload?path=" + urllib.parse.quote(directory) +
               "&name=" + urllib.parse.quote(name))
        request = urllib.request.Request(url, data=payload, method="POST",
                                         headers={"Content-Type": "application/octet-stream"})
        with cls.opener.open(request, timeout=10) as response:
            return json.load(response)

    def test_01_ui_exposes_all_requested_controls(self):
        with self.opener.open(self.base + "/", timeout=5) as response:
            html = response.read().decode()
        for control in ("selectAll", "deleteSelected", "renameSelected", "moveSelected",
                        "folderDialog", "data-new-folder"):
            self.assertIn(control, html)

    def test_02_create_rename_move_and_batch_delete(self):
        self.assertTrue(self.json_request("/api/mkdir", {"path": "", "name": "源目录"})[1]["ok"])
        self.assertTrue(self.json_request("/api/mkdir", {"path": "", "name": "目标目录"})[1]["ok"])
        self.assertTrue(self.json_request("/api/mkdir", {"path": "源目录", "name": "子目录"})[1]["ok"])
        self.assertTrue(self.upload("", "旧名称.txt", b"rename-me")["ok"])
        self.assertTrue(self.upload("", "保留.txt", b"keep-me")["ok"])

        renamed = self.json_request("/api/rename", {"path": "旧名称.txt", "name": "新名称.txt"})[1]
        self.assertEqual(renamed["path"], "新名称.txt")
        renamed_folder = self.json_request(
            "/api/rename", {"path": "源目录", "name": "已重命名目录"})[1]
        self.assertEqual(renamed_folder["path"], "已重命名目录")

        folders = self.json_request("/api/folders")[1]["folders"]
        folder_paths = {item["path"] for item in folders}
        self.assertIn("目标目录", folder_paths)
        self.assertIn("已重命名目录/子目录", folder_paths)

        moved = self.json_request("/api/move", {
            "paths": ["新名称.txt", "已重命名目录"], "destination": "目标目录",
        })[1]["paths"]
        self.assertEqual(set(moved), {"目标目录/新名称.txt", "目标目录/已重命名目录"})
        self.assertEqual((self.root / "目标目录" / "新名称.txt").read_bytes(), b"rename-me")
        self.assertTrue((self.root / "目标目录" / "已重命名目录" / "子目录").is_dir())

        with self.assertRaises(urllib.error.HTTPError) as error:
            self.json_request("/api/move", {
                "paths": ["目标目录"], "destination": "目标目录/已重命名目录/子目录",
            })
        self.assertEqual(error.exception.code, 400)
        self.assertTrue((self.root / "目标目录").is_dir())

        deleted = self.json_request("/api/delete", {
            "paths": ["目标目录/新名称.txt", "目标目录/已重命名目录"],
        })[1]
        self.assertEqual(deleted["deleted"], 2)
        self.assertFalse((self.root / "目标目录" / "新名称.txt").exists())
        self.assertFalse((self.root / "目标目录" / "已重命名目录").exists())
        self.assertTrue((self.root / "保留.txt").is_file())

    def test_03_reject_invalid_name_and_collision_without_data_loss(self):
        self.upload("", "甲.txt", b"A")
        self.upload("", "乙.txt", b"B")
        for body in (
            {"path": "甲.txt", "name": "../越界.txt"},
            {"path": "甲.txt", "name": "乙.txt"},
        ):
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.json_request("/api/rename", body)
            self.assertEqual(error.exception.code, 400)
        self.assertEqual((self.root / "甲.txt").read_bytes(), b"A")
        self.assertEqual((self.root / "乙.txt").read_bytes(), b"B")
        result = self.json_request("/api/delete", {
            "paths": ["甲.txt", "乙.txt", "保留.txt", "目标目录"],
        })[1]
        self.assertEqual(result["deleted"], 4)
        self.assertEqual(list(self.root.iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
