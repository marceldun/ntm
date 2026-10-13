#!/usr/bin/env python3
"""Small authenticated web drive for the Syncthing game-save directory."""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.cookies
import json
import mimetypes
import os
import pathlib
import secrets
import shutil
import ssl
import tempfile
import threading
import time
import urllib.parse
import zipfile
from collections import defaultdict, deque
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PBKDF2_ITERATIONS = 310_000
MAX_JSON = 1_048_576
SESSION_SECONDS = 7 * 24 * 60 * 60
LOGIN_ATTEMPTS = defaultdict(deque)
LOGIN_LOCK = threading.Lock()


def env_required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"Missing environment variable: {name}")
    return value


def b64decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def b64encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


class DriveServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, root: pathlib.Path, static: pathlib.Path, temp: pathlib.Path):
        super().__init__(address, handler)
        self.root = root.resolve()
        self.static = static.resolve()
        self.temp = temp.resolve()
        self.username = env_required("DRIVE_USERNAME")
        self.password_salt = b64decode(env_required("DRIVE_PASSWORD_SALT"))
        self.password_hash = b64decode(env_required("DRIVE_PASSWORD_HASH"))
        self.session_secret = b64decode(env_required("DRIVE_SESSION_SECRET"))


class DriveHandler(BaseHTTPRequestHandler):
    server: DriveServer
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", flush=True)

    def send_headers(self, status=200, content_type="application/json; charset=utf-8", length=None,
                     extra=None, cache="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; "
                         "script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
        if length is not None:
            self.send_header("Content-Length", str(length))
        if extra:
            for key, value in extra.items():
                self.send_header(key, value)
        self.end_headers()

    def json_response(self, obj, status=200, extra=None):
        body = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
        self.send_headers(status, length=len(body), extra=extra)
        self.wfile.write(body)

    def error_json(self, status, message):
        self.json_response({"error": message}, status)

    def read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise ValueError("请求长度无效")
        if length < 0 or length > MAX_JSON:
            raise ValueError("请求过大")
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise ValueError("JSON 格式无效")

    def relative_path(self, raw: str, must_exist=True) -> pathlib.Path:
        raw = urllib.parse.unquote(raw or "").replace("\\", "/").strip("/")
        parts = pathlib.PurePosixPath(raw).parts if raw else ()
        if any(part in ("", ".", "..") or "\x00" in part for part in parts):
            raise ValueError("路径无效")
        candidate = self.server.root.joinpath(*parts).resolve(strict=False)
        try:
            candidate.relative_to(self.server.root)
        except ValueError:
            raise ValueError("路径越界")
        if must_exist and not candidate.exists():
            raise FileNotFoundError(raw)
        return candidate

    def relative_name(self, path: pathlib.Path) -> str:
        return path.relative_to(self.server.root).as_posix()

    def session_cookie(self):
        cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        morsel = cookie.get("gs_session")
        return morsel.value if morsel else ""

    def session_valid(self):
        token = self.session_cookie()
        try:
            payload64, signature64 = token.split(".", 1)
            payload = b64decode(payload64)
            expected = hmac.new(self.server.session_secret, payload, hashlib.sha256).digest()
            if not hmac.compare_digest(expected, b64decode(signature64)):
                return False
            data = json.loads(payload)
            return data.get("u") == self.server.username and int(data.get("e", 0)) >= int(time.time())
        except Exception:
            return False

    def new_session(self):
        payload = json.dumps({"u": self.server.username, "e": int(time.time()) + SESSION_SECONDS},
                             separators=(",", ":")).encode()
        signature = hmac.new(self.server.session_secret, payload, hashlib.sha256).digest()
        return b64encode(payload) + "." + b64encode(signature)

    def require_auth(self):
        if self.session_valid():
            return True
        self.error_json(HTTPStatus.UNAUTHORIZED, "请先登录")
        return False

    def login_allowed(self):
        now = time.time()
        key = self.client_address[0]
        with LOGIN_LOCK:
            attempts = LOGIN_ATTEMPTS[key]
            while attempts and attempts[0] < now - 300:
                attempts.popleft()
            if len(attempts) >= 10:
                return False
            attempts.append(now)
            return True

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        try:
            if parsed.path in ("/", "/index.html"):
                return self.serve_index()
            if parsed.path == "/api/me":
                if not self.require_auth(): return
                return self.json_response({"username": self.server.username})
            if parsed.path == "/api/list":
                if not self.require_auth(): return
                return self.list_directory(urllib.parse.parse_qs(parsed.query).get("path", [""])[0])
            if parsed.path in ("/api/file", "/api/download"):
                if not self.require_auth(): return
                path = urllib.parse.parse_qs(parsed.query).get("path", [""])[0]
                inline = parsed.path == "/api/file"
                return self.send_path(self.relative_path(path), inline)
            return self.error_json(HTTPStatus.NOT_FOUND, "地址不存在")
        except FileNotFoundError:
            return self.error_json(HTTPStatus.NOT_FOUND, "文件不存在")
        except (ValueError, PermissionError) as exc:
            return self.error_json(HTTPStatus.BAD_REQUEST, str(exc))
        except BrokenPipeError:
            return

    def do_POST(self):
        parsed = urllib.parse.urlsplit(self.path)
        try:
            if parsed.path == "/api/login":
                return self.login()
            if parsed.path == "/api/logout":
                return self.json_response({"ok": True}, extra={
                    "Set-Cookie": "gs_session=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict"
                })
            if not self.require_auth(): return
            if parsed.path == "/api/upload":
                query = urllib.parse.parse_qs(parsed.query)
                return self.upload(query.get("path", [""])[0], query.get("name", [""])[0])
            if parsed.path == "/api/mkdir":
                data = self.read_json()
                return self.mkdir(data.get("path", ""), data.get("name", ""))
            if parsed.path == "/api/archive":
                return self.archive(self.read_json().get("paths", []))
            return self.error_json(HTTPStatus.NOT_FOUND, "地址不存在")
        except FileNotFoundError:
            return self.error_json(HTTPStatus.NOT_FOUND, "文件不存在")
        except (ValueError, PermissionError) as exc:
            return self.error_json(HTTPStatus.BAD_REQUEST, str(exc))
        except BrokenPipeError:
            return

    def serve_index(self):
        path = self.server.static / "index.html"
        body = path.read_bytes()
        self.send_headers(200, "text/html; charset=utf-8", len(body), cache="no-cache")
        self.wfile.write(body)

    def login(self):
        if not self.login_allowed():
            return self.error_json(HTTPStatus.TOO_MANY_REQUESTS, "登录失败次数过多，请五分钟后再试")
        data = self.read_json()
        supplied = hashlib.pbkdf2_hmac("sha256", str(data.get("password", "")).encode(),
                                       self.server.password_salt, PBKDF2_ITERATIONS)
        valid = hmac.compare_digest(str(data.get("username", "")), self.server.username)
        valid &= hmac.compare_digest(supplied, self.server.password_hash)
        if not valid:
            time.sleep(0.35)
            return self.error_json(HTTPStatus.UNAUTHORIZED, "用户名或密码错误")
        token = self.new_session()
        return self.json_response({"ok": True}, extra={
            "Set-Cookie": f"gs_session={token}; Path=/; Max-Age={SESSION_SECONDS}; HttpOnly; Secure; SameSite=Strict"
        })

    def list_directory(self, raw):
        directory = self.relative_path(raw)
        if not directory.is_dir():
            raise ValueError("这不是文件夹")
        entries = []
        for entry in directory.iterdir():
            if entry.name.startswith(".") or entry.is_symlink():
                continue
            try:
                stat = entry.stat()
            except OSError:
                continue
            is_dir = entry.is_dir()
            mime = "inode/directory" if is_dir else (mimetypes.guess_type(entry.name)[0] or "application/octet-stream")
            entries.append({
                "name": entry.name,
                "path": self.relative_name(entry),
                "directory": is_dir,
                "size": 0 if is_dir else stat.st_size,
                "modified": int(stat.st_mtime * 1000),
                "mime": mime,
                "image": mime.startswith("image/"),
            })
        return self.json_response({"path": self.relative_name(directory) if directory != self.server.root else "",
                                   "entries": entries})

    def upload(self, raw_directory, raw_name):
        directory = self.relative_path(raw_directory)
        name = pathlib.PurePath(urllib.parse.unquote(raw_name)).name
        if not name or name in (".", "..") or name.startswith(".") or "\x00" in name:
            raise ValueError("文件名无效")
        if not directory.is_dir():
            raise ValueError("上传目标不是文件夹")
        try:
            remaining = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            raise ValueError("文件长度无效")
        if remaining < 0:
            raise ValueError("必须提供文件长度")
        target = self.relative_path(self.relative_name(directory / name), must_exist=False)
        fd, temporary = tempfile.mkstemp(prefix=".upload-", dir=directory)
        try:
            with os.fdopen(fd, "wb") as output:
                while remaining:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ValueError("上传中断")
                    output.write(chunk)
                    remaining -= len(chunk)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, target)
        except Exception:
            try: os.unlink(temporary)
            except OSError: pass
            raise
        return self.json_response({"ok": True, "path": self.relative_name(target)})

    def mkdir(self, raw_directory, raw_name):
        directory = self.relative_path(raw_directory)
        name = str(raw_name).strip()
        if not name or pathlib.PurePath(name).name != name or name.startswith("."):
            raise ValueError("文件夹名称无效")
        target = self.relative_path(self.relative_name(directory / name), must_exist=False)
        target.mkdir(mode=0o700)
        return self.json_response({"ok": True, "path": self.relative_name(target)})

    def archive(self, raw_paths):
        if not isinstance(raw_paths, list) or not raw_paths or len(raw_paths) > 500:
            raise ValueError("请选择 1 到 500 个项目")
        paths = [self.relative_path(str(item)) for item in raw_paths]
        fd, archive_name = tempfile.mkstemp(prefix="download-", suffix=".zip", dir=self.server.temp)
        os.close(fd)
        try:
            with zipfile.ZipFile(archive_name, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=3) as archive:
                for path in paths:
                    base = self.relative_name(path)
                    if path.is_dir():
                        for child in path.rglob("*"):
                            if child.is_file() and not child.is_symlink() and not any(p.startswith(".") for p in child.relative_to(path).parts):
                                archive.write(child, pathlib.PurePosixPath(base) / child.relative_to(path))
                    elif path.is_file():
                        archive.write(path, base)
            return self.send_file(pathlib.Path(archive_name), False, "game-saves.zip", delete_after=True)
        except Exception:
            try: os.unlink(archive_name)
            except OSError: pass
            raise

    def send_path(self, path, inline):
        if path.is_dir():
            return self.archive([self.relative_name(path)])
        if not path.is_file():
            raise ValueError("无法下载此项目")
        return self.send_file(path, inline, path.name)

    def send_file(self, path, inline, download_name, delete_after=False):
        stat = path.stat()
        size = stat.st_size
        start, end = 0, size - 1
        status = HTTPStatus.OK
        range_header = self.headers.get("Range", "") if inline else ""
        if range_header.startswith("bytes="):
            try:
                left, right = range_header[6:].split("-", 1)
                start = int(left) if left else 0
                end = int(right) if right else size - 1
                if start < 0 or end < start or end >= size: raise ValueError
                status = HTTPStatus.PARTIAL_CONTENT
            except ValueError:
                return self.error_json(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, "Range 无效")
        length = max(0, end - start + 1)
        mime = mimetypes.guess_type(download_name)[0] or "application/octet-stream"
        disposition = "inline" if inline else "attachment"
        quoted = urllib.parse.quote(download_name, safe="")
        extra = {
            "Content-Disposition": f"{disposition}; filename*=UTF-8''{quoted}",
            "Accept-Ranges": "bytes",
        }
        if status == HTTPStatus.PARTIAL_CONTENT:
            extra["Content-Range"] = f"bytes {start}-{end}/{size}"
        self.send_headers(status, mime, length, extra=extra, cache="private, max-age=60")
        try:
            with path.open("rb") as source:
                source.seek(start)
                remaining = length
                while remaining:
                    chunk = source.read(min(1024 * 1024, remaining))
                    if not chunk: break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        finally:
            if delete_after:
                try: path.unlink()
                except OSError: pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=pathlib.Path)
    parser.add_argument("--static", required=True, type=pathlib.Path)
    parser.add_argument("--temp", required=True, type=pathlib.Path)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8443, type=int)
    parser.add_argument("--cert")
    parser.add_argument("--key")
    args = parser.parse_args()
    args.root.mkdir(parents=True, exist_ok=True)
    args.temp.mkdir(parents=True, exist_ok=True)
    server = DriveServer((args.host, args.port), DriveHandler, args.root, args.static, args.temp)
    if args.cert and args.key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(args.cert, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"Game Save Drive listening on {args.host}:{args.port}, root={server.root}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
