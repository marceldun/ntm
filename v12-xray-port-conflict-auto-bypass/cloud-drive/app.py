#!/usr/bin/env python3
"""Small authenticated web drive for the Syncthing game-save directory."""
from __future__ import annotations

import argparse
import base64
import email.utils
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
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zipfile
from collections import defaultdict, deque
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PBKDF2_ITERATIONS = 310_000
MAX_JSON = 1_048_576
# A successful login remains valid on this browser for ten years. The signed,
# HttpOnly cookie can still be revoked immediately with the explicit logout.
SESSION_SECONDS = 10 * 365 * 24 * 60 * 60
LOGIN_ATTEMPTS = defaultdict(deque)
LOGIN_LOCK = threading.Lock()


class SyncError(ValueError):
    """A safe user-facing error from the local Syncthing integration."""


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

    def __init__(self, address, handler, root: pathlib.Path, static: pathlib.Path,
                 temp: pathlib.Path, cert: pathlib.Path | None = None):
        super().__init__(address, handler)
        self.root = root.resolve()
        self.static = static.resolve()
        self.temp = temp.resolve()
        self.cert = cert.resolve() if cert else None
        self.username = env_required("DRIVE_USERNAME")
        self.password_salt = b64decode(env_required("DRIVE_PASSWORD_SALT"))
        self.password_hash = b64decode(env_required("DRIVE_PASSWORD_HASH"))
        self.session_secret = b64decode(env_required("DRIVE_SESSION_SECRET"))
        self.dav_auth_cache = {}
        self.dav_auth_lock = threading.Lock()
        self.sync_api = os.environ.get("SYNCTHING_API_URL", "").rstrip("/")
        self.sync_key = os.environ.get("SYNCTHING_API_KEY", "")
        self.android_id = os.environ.get("SYNCTHING_ANDROID_DEVICE_ID", "")
        self.sync_lock = threading.Lock()

    def sync_request(self, path, method="GET", body=None):
        if not self.sync_api or not self.sync_key or not self.android_id:
            raise SyncError("Syncthing 自动邀请尚未配置")
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
        request = urllib.request.Request(
            self.sync_api + "/rest/" + path, data=data, method=method,
            headers={"X-API-Key": self.sync_key, "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                payload = response.read()
            return json.loads(payload) if payload else None
        except Exception as exc:
            raise SyncError("Syncthing 自动邀请配置失败") from exc

    def sync_folders(self):
        return self.sync_request("config/folders") or []

    @staticmethod
    def managed_folder(folder):
        return str(folder.get("id", "")).startswith("web-drive-")

    def folder_for_path(self, path):
        wanted = str(path.resolve())
        return next((folder for folder in self.sync_folders()
                     if pathlib.Path(folder.get("path", "")).resolve() == pathlib.Path(wanted)), None)

    def share_web_folder(self, path):
        with self.sync_lock:
            existing = self.folder_for_path(path)
            if existing:
                devices = {item.get("deviceID") for item in existing.get("devices", [])}
                if self.android_id not in devices:
                    existing.setdefault("devices", []).append({"deviceID": self.android_id})
                    self.sync_request("config/folders/" + urllib.parse.quote(existing["id"], safe=""), "PUT", existing)
                return existing["id"]
            server_id = self.sync_request("system/status")["myID"]
            folder_id = "web-drive-" + uuid.uuid4().hex[:20]
            folder = {
                "id": folder_id,
                "label": path.name,
                "path": str(path.resolve()),
                "type": "sendreceive",
                "rescanIntervalS": 10,
                "fsWatcherEnabled": True,
                "fsWatcherDelayS": 2,
                "ignorePerms": True,
                "devices": [{"deviceID": server_id}, {"deviceID": self.android_id}],
                "versioning": {"type": "simple", "params": {"keep": "10"}},
            }
            self.sync_request("config/folders", "POST", folder)
            saved = next((item for item in self.sync_folders() if item.get("id") == folder_id), None)
            if not saved or self.android_id not in {item.get("deviceID") for item in saved.get("devices", [])}:
                try: self.sync_request("config/folders/" + urllib.parse.quote(folder_id, safe=""), "DELETE")
                except SyncError: pass
                raise SyncError("手机共享邀请写入后验证失败")
            return folder_id

    def update_web_folder(self, old_path, new_path):
        with self.sync_lock:
            folder = self.folder_for_path(old_path)
            if not folder or not self.managed_folder(folder):
                return False
            folder["path"] = str(new_path.resolve())
            folder["label"] = new_path.name
            self.sync_request("config/folders/" + urllib.parse.quote(folder["id"], safe=""), "PUT", folder)
            return True

    def unshare_web_folder(self, path):
        with self.sync_lock:
            folder = self.folder_for_path(path)
            if not folder or not self.managed_folder(folder):
                return None
            self.sync_request("config/folders/" + urllib.parse.quote(folder["id"], safe=""), "DELETE")
            return folder

    def restore_web_folder(self, folder):
        if folder:
            with self.sync_lock:
                self.sync_request("config/folders", "POST", folder)


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

    def bytes_response(self, body: bytes, status=200, content_type="application/octet-stream", extra=None):
        self.send_headers(status, content_type, len(body), extra=extra)
        if self.command != "HEAD":
            self.wfile.write(body)

    def empty_response(self, status=204, extra=None):
        self.send_headers(status, "text/plain; charset=utf-8", 0, extra=extra)

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

    def password_valid(self, username, password):
        supplied = hashlib.pbkdf2_hmac("sha256", str(password).encode(),
                                       self.server.password_salt, PBKDF2_ITERATIONS)
        valid = hmac.compare_digest(str(username), self.server.username)
        return valid and hmac.compare_digest(supplied, self.server.password_hash)

    def dav_auth_valid(self):
        authorization = self.headers.get("Authorization", "")
        cache_key = hashlib.sha256(authorization.encode()).digest()
        now = time.monotonic()
        with self.server.dav_auth_lock:
            if self.server.dav_auth_cache.get(cache_key, 0) > now:
                return True
        if authorization.startswith("Basic "):
            try:
                decoded = base64.b64decode(authorization[6:], validate=True).decode("utf-8")
                username, password = decoded.split(":", 1)
                if self.password_valid(username, password):
                    with self.server.dav_auth_lock:
                        if len(self.server.dav_auth_cache) >= 256:
                            self.server.dav_auth_cache.clear()
                        self.server.dav_auth_cache[cache_key] = now + 600
                    return True
            except (ValueError, UnicodeDecodeError):
                pass
        self.empty_response(HTTPStatus.UNAUTHORIZED, {
            "WWW-Authenticate": 'Basic realm="VPS Cloud Drive", charset="UTF-8"'
        })
        return False

    @staticmethod
    def is_dav_path(path):
        return path == "/dav" or path.startswith("/dav/")

    def dav_path(self, url_path, must_exist=True):
        if not self.is_dav_path(url_path):
            raise ValueError("WebDAV 路径无效")
        return self.relative_path(url_path[4:], must_exist=must_exist)

    def dav_href(self, path):
        relative = self.relative_name(path) if path != self.server.root else ""
        href = "/dav/" + urllib.parse.quote(relative, safe="/")
        if path.is_dir() and not href.endswith("/"):
            href += "/"
        return href

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
            if self.is_dav_path(parsed.path):
                if not self.dav_auth_valid(): return
                return self.send_path(self.dav_path(parsed.path), True)
            if parsed.path == "/certificate.pem":
                if not self.server.cert or not self.server.cert.is_file():
                    return self.error_json(HTTPStatus.NOT_FOUND, "证书不存在")
                return self.bytes_response(self.server.cert.read_bytes(), content_type="application/x-pem-file")
            if parsed.path in ("/", "/index.html"):
                return self.serve_index()
            if parsed.path == "/api/me":
                if not self.require_auth(): return
                return self.json_response({"username": self.server.username})
            if parsed.path == "/api/list":
                if not self.require_auth(): return
                return self.list_directory(urllib.parse.parse_qs(parsed.query).get("path", [""])[0])
            if parsed.path == "/api/folders":
                if not self.require_auth(): return
                return self.list_folders()
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

    def do_HEAD(self):
        parsed = urllib.parse.urlsplit(self.path)
        try:
            if not self.is_dav_path(parsed.path):
                return self.empty_response(HTTPStatus.NOT_FOUND)
            if not self.dav_auth_valid(): return
            path = self.dav_path(parsed.path)
            if path.is_dir():
                return self.empty_response(HTTPStatus.OK, {"DAV": "1, 2"})
            stat = path.stat()
            mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
            self.send_headers(HTTPStatus.OK, mime, stat.st_size, extra={
                "Accept-Ranges": "bytes", "ETag": f'"{stat.st_mtime_ns:x}-{stat.st_size:x}"'
            })
        except FileNotFoundError:
            self.empty_response(HTTPStatus.NOT_FOUND)
        except (ValueError, PermissionError):
            self.empty_response(HTTPStatus.BAD_REQUEST)

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
            if parsed.path == "/api/delete":
                return self.delete_items(self.read_json().get("paths", []))
            if parsed.path == "/api/rename":
                data = self.read_json()
                return self.rename_item(data.get("path", ""), data.get("name", ""))
            if parsed.path == "/api/move":
                data = self.read_json()
                return self.move_items(data.get("paths", []), data.get("destination", ""))
            return self.error_json(HTTPStatus.NOT_FOUND, "地址不存在")
        except FileNotFoundError:
            return self.error_json(HTTPStatus.NOT_FOUND, "文件不存在")
        except BrokenPipeError:
            return
        except (ValueError, PermissionError, OSError) as exc:
            return self.error_json(HTTPStatus.BAD_REQUEST, str(exc))

    def serve_index(self):
        path = self.server.static / "index.html"
        body = path.read_bytes()
        self.send_headers(200, "text/html; charset=utf-8", len(body), cache="no-cache")
        self.wfile.write(body)

    def login(self):
        if not self.login_allowed():
            return self.error_json(HTTPStatus.TOO_MANY_REQUESTS, "登录失败次数过多，请五分钟后再试")
        data = self.read_json()
        if not self.password_valid(data.get("username", ""), data.get("password", "")):
            time.sleep(0.35)
            return self.error_json(HTTPStatus.UNAUTHORIZED, "用户名或密码错误")
        token = self.new_session()
        return self.json_response({"ok": True}, extra={
            "Set-Cookie": f"gs_session={token}; Path=/; Max-Age={SESSION_SECONDS}; HttpOnly; Secure; SameSite=Strict"
        })

    def do_OPTIONS(self):
        parsed = urllib.parse.urlsplit(self.path)
        if self.is_dav_path(parsed.path):
            if not self.dav_auth_valid(): return
            return self.empty_response(HTTPStatus.OK, {
                "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, COPY, MOVE, PROPFIND, PROPPATCH, LOCK, UNLOCK",
                "DAV": "1, 2", "MS-Author-Via": "DAV"
            })
        self.empty_response(HTTPStatus.NO_CONTENT, {"Allow": "OPTIONS, GET, HEAD, POST"})

    def do_PROPFIND(self):
        parsed = urllib.parse.urlsplit(self.path)
        try:
            if not self.is_dav_path(parsed.path): return self.empty_response(HTTPStatus.NOT_FOUND)
            if not self.dav_auth_valid(): return
            self.read_dav_body()
            path = self.dav_path(parsed.path)
            depth = self.headers.get("Depth", "1")
            if depth not in ("0", "1"): return self.empty_response(HTTPStatus.FORBIDDEN)
            paths = [path]
            if depth == "1" and path.is_dir():
                paths.extend(sorted((item for item in path.iterdir()
                                     if not item.name.startswith(".") and not item.is_symlink()),
                                    key=lambda item: item.name.casefold()))
            ET.register_namespace("D", "DAV:")
            multistatus = ET.Element("{DAV:}multistatus")
            for item in paths:
                stat = item.stat()
                response = ET.SubElement(multistatus, "{DAV:}response")
                ET.SubElement(response, "{DAV:}href").text = self.dav_href(item)
                propstat = ET.SubElement(response, "{DAV:}propstat")
                prop = ET.SubElement(propstat, "{DAV:}prop")
                ET.SubElement(prop, "{DAV:}displayname").text = item.name if item != self.server.root else "VPS云盘"
                resource = ET.SubElement(prop, "{DAV:}resourcetype")
                if item.is_dir(): ET.SubElement(resource, "{DAV:}collection")
                if item.is_file():
                    ET.SubElement(prop, "{DAV:}getcontentlength").text = str(stat.st_size)
                    ET.SubElement(prop, "{DAV:}getcontenttype").text = mimetypes.guess_type(item.name)[0] or "application/octet-stream"
                ET.SubElement(prop, "{DAV:}getlastmodified").text = email.utils.formatdate(stat.st_mtime, usegmt=True)
                ET.SubElement(prop, "{DAV:}creationdate").text = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stat.st_ctime))
                ET.SubElement(prop, "{DAV:}getetag").text = f'"{stat.st_mtime_ns:x}-{stat.st_size:x}"'
                supported = ET.SubElement(prop, "{DAV:}supportedlock")
                lockentry = ET.SubElement(supported, "{DAV:}lockentry")
                lockscope = ET.SubElement(lockentry, "{DAV:}lockscope")
                ET.SubElement(lockscope, "{DAV:}exclusive")
                locktype = ET.SubElement(lockentry, "{DAV:}locktype")
                ET.SubElement(locktype, "{DAV:}write")
                ET.SubElement(propstat, "{DAV:}status").text = "HTTP/1.1 200 OK"
            body = ET.tostring(multistatus, encoding="utf-8", xml_declaration=True)
            self.bytes_response(body, HTTPStatus.MULTI_STATUS, "application/xml; charset=utf-8", {"DAV": "1, 2"})
        except FileNotFoundError:
            self.empty_response(HTTPStatus.NOT_FOUND)
        except (ValueError, PermissionError, OSError):
            self.empty_response(HTTPStatus.BAD_REQUEST)

    def read_dav_body(self, output=None):
        transfer = self.headers.get("Transfer-Encoding", "").lower()
        if transfer == "chunked":
            while True:
                line = self.rfile.readline(128)
                if not line: raise ValueError("上传中断")
                size = int(line.split(b";", 1)[0].strip(), 16)
                if size == 0:
                    while self.rfile.readline(8192) not in (b"\r\n", b"\n", b""): pass
                    break
                data = self.rfile.read(size)
                if len(data) != size: raise ValueError("上传中断")
                if output: output.write(data)
                if self.rfile.read(2) != b"\r\n": raise ValueError("分块格式无效")
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length < 0: raise ValueError("文件长度无效")
        while length:
            data = self.rfile.read(min(1024 * 1024, length))
            if not data: raise ValueError("上传中断")
            if output: output.write(data)
            length -= len(data)

    def do_PUT(self):
        parsed = urllib.parse.urlsplit(self.path)
        temporary = None
        try:
            if not self.is_dav_path(parsed.path): return self.empty_response(HTTPStatus.NOT_FOUND)
            if not self.dav_auth_valid(): return
            target = self.dav_path(parsed.path, must_exist=False)
            if target == self.server.root or target.name.startswith("."): raise ValueError("文件名无效")
            if not target.parent.is_dir(): return self.empty_response(HTTPStatus.CONFLICT)
            existed = target.exists()
            fd, temporary = tempfile.mkstemp(prefix=".webdav-", dir=target.parent)
            with os.fdopen(fd, "wb") as output:
                self.read_dav_body(output)
                output.flush(); os.fsync(output.fileno())
            os.replace(temporary, target); temporary = None
            self.empty_response(HTTPStatus.NO_CONTENT if existed else HTTPStatus.CREATED)
        except FileNotFoundError:
            self.empty_response(HTTPStatus.CONFLICT)
        except (ValueError, PermissionError, OSError):
            self.empty_response(HTTPStatus.BAD_REQUEST)
        finally:
            if temporary:
                try: os.unlink(temporary)
                except OSError: pass

    def do_MKCOL(self):
        parsed = urllib.parse.urlsplit(self.path)
        try:
            if not self.is_dav_path(parsed.path): return self.empty_response(HTTPStatus.NOT_FOUND)
            if not self.dav_auth_valid(): return
            self.read_dav_body()
            target = self.dav_path(parsed.path, must_exist=False)
            if target.exists(): return self.empty_response(HTTPStatus.METHOD_NOT_ALLOWED)
            if not target.parent.is_dir(): return self.empty_response(HTTPStatus.CONFLICT)
            target.mkdir(mode=0o700)
            self.empty_response(HTTPStatus.CREATED)
        except (ValueError, PermissionError, OSError):
            self.empty_response(HTTPStatus.BAD_REQUEST)

    def do_DELETE(self):
        parsed = urllib.parse.urlsplit(self.path)
        try:
            if not self.is_dav_path(parsed.path): return self.empty_response(HTTPStatus.NOT_FOUND)
            if not self.dav_auth_valid(): return
            target = self.dav_path(parsed.path)
            if target == self.server.root: return self.empty_response(HTTPStatus.FORBIDDEN)
            shutil.rmtree(target) if target.is_dir() else target.unlink()
            self.empty_response(HTTPStatus.NO_CONTENT)
        except FileNotFoundError:
            self.empty_response(HTTPStatus.NOT_FOUND)
        except (ValueError, PermissionError, OSError):
            self.empty_response(HTTPStatus.BAD_REQUEST)

    def dav_destination(self):
        destination = urllib.parse.urlsplit(self.headers.get("Destination", "")).path
        return self.dav_path(destination, must_exist=False)

    def do_MOVE(self):
        self.dav_copy_or_move(move=True)

    def do_COPY(self):
        self.dav_copy_or_move(move=False)

    def dav_copy_or_move(self, move):
        parsed = urllib.parse.urlsplit(self.path)
        try:
            if not self.is_dav_path(parsed.path): return self.empty_response(HTTPStatus.NOT_FOUND)
            if not self.dav_auth_valid(): return
            source = self.dav_path(parsed.path)
            target = self.dav_destination()
            if source == self.server.root or target == self.server.root: return self.empty_response(HTTPStatus.FORBIDDEN)
            if not target.parent.is_dir(): return self.empty_response(HTTPStatus.CONFLICT)
            existed = target.exists()
            if existed and self.headers.get("Overwrite", "T").upper() != "T":
                return self.empty_response(HTTPStatus.PRECONDITION_FAILED)
            if existed:
                shutil.rmtree(target) if target.is_dir() else target.unlink()
            if move:
                shutil.move(str(source), str(target))
            elif source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copy2(source, target)
            self.empty_response(HTTPStatus.NO_CONTENT if existed else HTTPStatus.CREATED)
        except FileNotFoundError:
            self.empty_response(HTTPStatus.NOT_FOUND)
        except (ValueError, PermissionError, OSError):
            self.empty_response(HTTPStatus.BAD_REQUEST)

    def do_LOCK(self):
        parsed = urllib.parse.urlsplit(self.path)
        try:
            if not self.is_dav_path(parsed.path): return self.empty_response(HTTPStatus.NOT_FOUND)
            if not self.dav_auth_valid(): return
            self.read_dav_body()
            target = self.dav_path(parsed.path, must_exist=False)
            if not target.exists():
                if not target.parent.is_dir(): return self.empty_response(HTTPStatus.CONFLICT)
                target.touch(mode=0o600)
            token = "opaquelocktoken:" + str(uuid.uuid4())
            ET.register_namespace("D", "DAV:")
            prop = ET.Element("{DAV:}prop")
            discovery = ET.SubElement(prop, "{DAV:}lockdiscovery")
            active = ET.SubElement(discovery, "{DAV:}activelock")
            scope = ET.SubElement(active, "{DAV:}lockscope"); ET.SubElement(scope, "{DAV:}exclusive")
            locktype = ET.SubElement(active, "{DAV:}locktype"); ET.SubElement(locktype, "{DAV:}write")
            ET.SubElement(active, "{DAV:}depth").text = "infinity"
            ET.SubElement(active, "{DAV:}timeout").text = "Second-3600"
            locktoken = ET.SubElement(active, "{DAV:}locktoken"); ET.SubElement(locktoken, "{DAV:}href").text = token
            body = ET.tostring(prop, encoding="utf-8", xml_declaration=True)
            self.bytes_response(body, HTTPStatus.OK, "application/xml; charset=utf-8", {
                "Lock-Token": f"<{token}>", "Timeout": "Second-3600", "DAV": "1, 2"
            })
        except (ValueError, PermissionError, OSError):
            self.empty_response(HTTPStatus.BAD_REQUEST)

    def do_UNLOCK(self):
        parsed = urllib.parse.urlsplit(self.path)
        if not self.is_dav_path(parsed.path): return self.empty_response(HTTPStatus.NOT_FOUND)
        if not self.dav_auth_valid(): return
        self.empty_response(HTTPStatus.NO_CONTENT)

    def do_PROPPATCH(self):
        parsed = urllib.parse.urlsplit(self.path)
        if not self.is_dav_path(parsed.path): return self.empty_response(HTTPStatus.NOT_FOUND)
        if not self.dav_auth_valid(): return
        try: self.read_dav_body()
        except (ValueError, OSError): return self.empty_response(HTTPStatus.BAD_REQUEST)
        ET.register_namespace("D", "DAV:")
        multistatus = ET.Element("{DAV:}multistatus")
        response = ET.SubElement(multistatus, "{DAV:}response")
        ET.SubElement(response, "{DAV:}href").text = parsed.path
        propstat = ET.SubElement(response, "{DAV:}propstat")
        ET.SubElement(propstat, "{DAV:}prop")
        ET.SubElement(propstat, "{DAV:}status").text = "HTTP/1.1 200 OK"
        self.bytes_response(ET.tostring(multistatus, encoding="utf-8", xml_declaration=True),
                            HTTPStatus.MULTI_STATUS, "application/xml; charset=utf-8")

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

    def list_folders(self):
        folders = [{"path": "", "name": "我的存档"}]
        for current, names, _ in os.walk(self.server.root, followlinks=False):
            base = pathlib.Path(current)
            names[:] = sorted(name for name in names
                              if not name.startswith(".") and not (base / name).is_symlink())
            for name in names:
                path = base / name
                folders.append({"path": self.relative_name(path), "name": self.relative_name(path)})
                if len(folders) >= 5000:
                    return self.json_response({"folders": folders, "truncated": True})
        return self.json_response({"folders": folders, "truncated": False})

    @staticmethod
    def valid_item_name(raw):
        name = str(raw).strip()
        if (not name or name in (".", "..") or name.startswith(".") or
                "/" in name or "\\" in name or "\x00" in name):
            raise ValueError("名称无效")
        return name

    def checked_paths(self, raw_paths):
        if not isinstance(raw_paths, list) or not raw_paths or len(raw_paths) > 500:
            raise ValueError("请选择 1 到 500 个项目")
        result = []
        seen = set()
        for raw in raw_paths:
            path = self.relative_path(str(raw))
            if path == self.server.root:
                raise ValueError("不能操作云盘根目录")
            if path not in seen:
                seen.add(path)
                result.append(path)
        return result

    def delete_items(self, raw_paths):
        paths = self.checked_paths(raw_paths)
        # Delete deeper entries first if an API caller supplied nested selections.
        paths.sort(key=lambda path: len(path.parts), reverse=True)
        removed_shares = []
        try:
            for path in paths:
                if path.is_dir() and path.parent == self.server.root:
                    folder = self.server.unshare_web_folder(path)
                    if folder:
                        removed_shares.append(folder)
        except Exception:
            for folder in removed_shares:
                try: self.server.restore_web_folder(folder)
                except SyncError: pass
            raise
        deleted = 0
        try:
            for path in paths:
                if not path.exists():
                    continue
                shutil.rmtree(path) if path.is_dir() else path.unlink()
                deleted += 1
        except Exception:
            for folder in removed_shares:
                try: self.server.restore_web_folder(folder)
                except SyncError: pass
            raise
        return self.json_response({"ok": True, "deleted": deleted})

    def rename_item(self, raw_path, raw_name):
        source = self.checked_paths([raw_path])[0]
        name = self.valid_item_name(raw_name)
        target = (source.parent / name).resolve(strict=False)
        try:
            target.relative_to(self.server.root)
        except ValueError:
            raise ValueError("目标路径越界")
        if target == source:
            return self.json_response({"ok": True, "path": self.relative_name(source)})
        if target.exists():
            raise ValueError("同名文件或文件夹已经存在")
        managed = source.is_dir() and source.parent == self.server.root
        source.rename(target)
        if managed:
            try:
                self.server.update_web_folder(source, target)
            except Exception:
                target.rename(source)
                raise
        return self.json_response({"ok": True, "path": self.relative_name(target)})

    def move_items(self, raw_paths, raw_destination):
        sources = self.checked_paths(raw_paths)
        destination = self.relative_path(str(raw_destination))
        if not destination.is_dir():
            raise ValueError("移动目标不是文件夹")
        targets = []
        for source in sources:
            if destination == source.parent:
                raise ValueError("项目已经在这个文件夹中")
            if source.is_dir():
                try:
                    destination.relative_to(source)
                except ValueError:
                    pass
                else:
                    raise ValueError("不能把文件夹移动到它自己里面")
            target = destination / source.name
            if target.exists() or target in targets:
                raise ValueError("目标文件夹中存在同名项目")
            targets.append(target)
        moved_pairs = []
        removed_shares = []
        new_shares = []
        try:
            for source, target in zip(sources, targets):
                shutil.move(str(source), str(target))
                moved_pairs.append((source, target))
            for source, target in moved_pairs:
                if not target.is_dir():
                    continue
                if source.parent == self.server.root and target.parent != self.server.root:
                    folder = self.server.unshare_web_folder(source)
                    if folder:
                        removed_shares.append(folder)
                elif source.parent != self.server.root and target.parent == self.server.root:
                    new_shares.append((target, self.server.share_web_folder(target)))
        except Exception:
            for target, _ in new_shares:
                try: self.server.unshare_web_folder(target)
                except SyncError: pass
            for source, target in reversed(moved_pairs):
                if target.exists() and not source.exists():
                    shutil.move(str(target), str(source))
            for folder in removed_shares:
                try: self.server.restore_web_folder(folder)
                except SyncError: pass
            raise
        moved = [self.relative_name(target) for _, target in moved_pairs]
        return self.json_response({"ok": True, "paths": moved})

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
        name = self.valid_item_name(raw_name)
        target = self.relative_path(self.relative_name(directory / name), must_exist=False)
        target.mkdir(mode=0o700)
        invitation = False
        if directory == self.server.root:
            try:
                self.server.share_web_folder(target)
                invitation = True
            except Exception:
                target.rmdir()
                raise
        return self.json_response({"ok": True, "path": self.relative_name(target),
                                   "androidInvitation": invitation})

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
    cert_path = pathlib.Path(args.cert) if args.cert else None
    server = DriveServer((args.host, args.port), DriveHandler, args.root, args.static, args.temp, cert_path)
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
