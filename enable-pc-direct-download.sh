#!/usr/bin/env bash
# Enable a Windows direct-download WebDAV drive backed by a Syncthing folder.
set -Eeuo pipefail
umask 077

readonly APP_STATE='/var/lib/game-save-sync'
readonly SYNC_ROOT="$APP_STATE/saves"
readonly DOWNLOAD_PATH="$SYNC_ROOT/电脑下载"
readonly APP_SERVICE='game-save-sync.service'
readonly API_URL='http://127.0.0.1:8384'
readonly ANDROID_ID='XFQ7AJQ-34V53ZD-DCIHLSA-7TERDRR-27RXR54-FZCKF4I-F3FHCSC-NV4SZA3'
readonly CLOUD_INSTALLER_URL='https://raw.githubusercontent.com/marceldun/ntm/main/cloud-drive/install-cloud-drive.sh'
readonly CLOUD_INSTALLER_SHA='be33b24a0df32fc223fdc4cad7cc420c1286e3ae09e1edd380b11eabced74dd6'
readonly WINDOWS_SETUP_SHA='fb4f6902127147699907ec947b499c539741cdf83cbea6fb1510d5e317f8dc46'

TEMP_DIR=''
fail() { printf '\n错误：%s\n' "$*" >&2; exit 1; }
on_error() { local rc=$?; printf '\n设置失败（第 %s 行，退出码 %s）。日志：journalctl -u %s -n 100 --no-pager\n' "${BASH_LINENO[0]:-${LINENO}}" "$rc" "$APP_SERVICE" >&2; exit "$rc"; }
cleanup() { [[ -n $TEMP_DIR && -d $TEMP_DIR ]] && rm -rf -- "$TEMP_DIR"; }
trap on_error ERR
trap cleanup EXIT

[[ $EUID -eq 0 ]] || fail '请使用 root 运行。'
[[ -d /run/systemd/system ]] || fail '这台 VPS 没有运行 systemd。'
[[ -s "$APP_STATE/config.xml" ]] || fail '没有找到 Syncthing 配置，请先完成 VPS 同步安装。'
id gamesync >/dev/null 2>&1 || fail '没有找到 gamesync 服务账户，请先完成 VPS 同步安装。'
for command in python3 curl systemctl; do command -v "$command" >/dev/null || fail "缺少命令：$command"; done

printf '[1/4] 创建“电脑下载”云盘目录……\n'
install -d -o gamesync -g gamesync -m 0700 "$DOWNLOAD_PATH"
systemctl start "$APP_SERVICE"

printf '[2/4] 注册双向同步并共享给安卓……'
API_KEY=''
for attempt in $(seq 1 120); do
  API_KEY=$(python3 - "$APP_STATE/config.xml" <<'PY' 2>/dev/null || true
import sys, xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).findtext('gui/apikey') or '')
PY
)
  if [[ -n $API_KEY ]] && curl -fsS --max-time 2 -H "X-API-Key: $API_KEY" "$API_URL/rest/system/status" >/dev/null 2>&1; then break; fi
  (( attempt % 10 == 0 )) && printf '.'
  sleep 0.5
done
printf '\n'
[[ -n $API_KEY ]] || fail '无法读取 Syncthing API 密钥。'

# BEGIN CONFIGURE_PC_DOWNLOADS_PY
python3 - "$DOWNLOAD_PATH" "$ANDROID_ID" "$API_URL" "$API_KEY" <<'PY'
import json
import pathlib
import sys
import urllib.request

folder_path, android_id, base, api_key = sys.argv[1:5]
headers = {'X-API-Key': api_key, 'Content-Type': 'application/json'}
def request(path, method='GET', obj=None):
    data = None if obj is None else json.dumps(obj).encode()
    req = urllib.request.Request(base + '/rest/' + path, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as response:
        body = response.read()
    return json.loads(body) if body else None

config = request('config')
server_id = request('system/status')['myID']
if not any(item.get('deviceID') == android_id for item in config.get('devices', [])):
    raise SystemExit('配置中没有安卓设备，请先运行最新版一键安装。')
folder = next((item for item in config.get('folders', []) if item.get('id') == 'pc-downloads'), None)
if folder is None:
    folder = {'id': 'pc-downloads', 'devices': []}
    config.setdefault('folders', []).append(folder)
folder.update({
    'label': '电脑下载',
    'path': folder_path,
    'type': 'sendreceive',
    'rescanIntervalS': 3600,
    'fsWatcherEnabled': True,
    'fsWatcherDelayS': 5,
    'ignorePerms': True,
    'versioning': {'type': 'simple', 'params': {'keep': '10'}},
})
shared = {item.get('deviceID') for item in folder.get('devices', [])}
for wanted in (server_id, android_id):
    if wanted not in shared: folder.setdefault('devices', []).append({'deviceID': wanted})
request('config', 'PUT', config)
saved = request('config')
matches = [item for item in saved.get('folders', []) if item.get('id') == 'pc-downloads']
if len(matches) != 1 or pathlib.Path(matches[0].get('path', '')) != pathlib.Path(folder_path):
    raise SystemExit('同步目录验证失败。')
devices = {item.get('deviceID') for item in matches[0].get('devices', [])}
if not {server_id, android_id}.issubset(devices): raise SystemExit('共享设备验证失败。')
PY
# END CONFIGURE_PC_DOWNLOADS_PY
curl -fsS --max-time 10 -X POST -H "X-API-Key: $API_KEY" "$API_URL/rest/db/scan?folder=pc-downloads" >/dev/null

printf '[3/4] 升级云盘并开启 HTTPS WebDAV……\n'
TEMP_DIR=$(mktemp -d /tmp/pc-direct-download.XXXXXX)
curl -fL --retry 5 --connect-timeout 15 "$CLOUD_INSTALLER_URL" -o "$TEMP_DIR/install-cloud-drive.sh"
printf '%s  %s\n' "$CLOUD_INSTALLER_SHA" "$TEMP_DIR/install-cloud-drive.sh" | sha256sum -c -
bash -n "$TEMP_DIR/install-cloud-drive.sh"
GAME_DRIVE_SKIP_APT=1 bash "$TEMP_DIR/install-cloud-drive.sh"

printf '[4/4] 验证 WebDAV 和证书下载……\n'
PORT=$(<"$APP_STATE/web/port")
curl -kfsS --max-time 5 "https://127.0.0.1:$PORT/certificate.pem" | openssl x509 -noout -subject >/dev/null
STATUS=$(curl -ksS --max-time 5 -o /dev/null -w '%{http_code}' -u 'marcel:456qwe456' -X PROPFIND -H 'Depth: 0' "https://127.0.0.1:$PORT/dav/")
[[ $STATUS == 207 ]] || fail "WebDAV 验证失败，HTTP $STATUS。"

printf '\nVPS 设置成功。“电脑下载”已共享给安卓。\n'
printf '手机接受“电脑下载”邀请并选择手机 Download 文件夹，只做这一次。\n'
printf '\n在 Windows PowerShell 复制下面一整行（会自动映射 V: 并设置 Chrome/Edge）：\n'
printf "powershell -NoProfile -ExecutionPolicy Bypass -Command \"\$p=Join-Path \$env:TEMP 'windows-direct-download.ps1'; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/marceldun/ntm/main/windows-direct-download.ps1' -OutFile \$p; if((Get-FileHash \$p -Algorithm SHA256).Hash -ne '%s'.ToUpper()){throw 'SHA256 check failed'}; & \$p\"\n" "$WINDOWS_SETUP_SHA"
