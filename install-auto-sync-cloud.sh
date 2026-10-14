#!/usr/bin/env bash
# Fresh VPS all-in-one installer: Syncthing auto-accept plus the web cloud drive.
# Usage: sudo bash install-auto-sync-cloud.sh [ANDROID_DEVICE_ID] [WEB_USER] [WEB_PASSWORD]
set -Eeuo pipefail
umask 077

readonly APP_USER='gamesync'
readonly APP_GROUP='gamesync'
readonly APP_STATE='/var/lib/game-save-sync'
readonly APP_SERVICE='game-save-sync.service'
readonly SYNC_ROOT="$APP_STATE/saves"
readonly API_URL='http://127.0.0.1:8384'
readonly CLOUD_INSTALLER_URL='https://raw.githubusercontent.com/marceldun/ntm/main/cloud-drive/install-cloud-drive.sh'
readonly CLOUD_INSTALLER_SHA='be33b24a0df32fc223fdc4cad7cc420c1286e3ae09e1edd380b11eabced74dd6'
readonly WINDOWS_SETUP_SHA='fb4f6902127147699907ec947b499c539741cdf83cbea6fb1510d5e317f8dc46'

ANDROID_ID="${1:-XFQ7AJQ-34V53ZD-DCIHLSA-7TERDRR-27RXR54-FZCKF4I-F3FHCSC-NV4SZA3}"
WEB_USER="${2:-marcel}"
WEB_PASSWORD="${3:-456qwe456}"
TEMP_DIR=''

fail() { printf '\n错误：%s\n' "$*" >&2; exit 1; }
on_error() {
  local code=$?
  printf '\n安装失败：第 %s 行，退出码 %s。同步日志：journalctl -u %s -n 80 --no-pager\n' \
    "${BASH_LINENO[0]:-${LINENO}}" "$code" "$APP_SERVICE" >&2
  exit "$code"
}
cleanup() { [[ -n $TEMP_DIR && -d $TEMP_DIR ]] && rm -rf -- "$TEMP_DIR"; }
trap on_error ERR
trap cleanup EXIT

[[ $EUID -eq 0 ]] || fail '请使用 root 或 sudo 运行。'
[[ -d /run/systemd/system ]] || fail '这台 VPS 没有运行 systemd。'
[[ -r /etc/os-release ]] || fail '无法识别操作系统。'
source /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
  *) fail "仅支持 Ubuntu 22.04/24.04 或 Debian 12/13；当前是 ${PRETTY_NAME:-未知系统}。" ;;
esac

ANDROID_ID=${ANDROID_ID^^}
[[ $ANDROID_ID =~ ^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$ ]] || \
  fail '安卓设备 ID 格式不对：必须是 8 组、每组 7 个字符。'
[[ $WEB_USER =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || fail '云盘用户名格式不正确。'
[[ ${#WEB_PASSWORD} -ge 8 ]] || fail '云盘密码至少需要 8 位。'

printf '[1/7] 安装低内存同步服务……\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends syncthing python3 ca-certificates curl openssl iproute2
if apt-get install -y --no-install-recommends qrencode; then HAVE_QR=1; else HAVE_QR=0; fi
command -v syncthing >/dev/null || fail 'Syncthing 安装失败。'
syncthing serve --help >/dev/null 2>&1 || fail 'Syncthing 版本过旧，不支持 serve 命令。'

printf '[2/7] 创建专用账户和云盘目录……\n'
getent group "$APP_GROUP" >/dev/null || groupadd --system "$APP_GROUP"
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --gid "$APP_GROUP" --home-dir "$APP_STATE" --shell /usr/sbin/nologin "$APP_USER"
fi
[[ $(id -gn "$APP_USER") == "$APP_GROUP" ]] || usermod --gid "$APP_GROUP" "$APP_USER"
install -d -o "$APP_USER" -g "$APP_GROUP" -m 0700 "$APP_STATE" "$SYNC_ROOT" "$SYNC_ROOT/电脑下载"
chown -R "$APP_USER:$APP_GROUP" "$APP_STATE"

printf '[3/7] 安装开机自启服务……\n'
systemctl stop "$APP_SERVICE" 2>/dev/null || true
cat > "/etc/systemd/system/$APP_SERVICE" <<EOF
[Unit]
Description=Automatic Android folder synchronization
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_GROUP
UMask=0077
Environment=GOGC=35
Environment=GOMEMLIMIT=128MiB
ExecStart=/usr/bin/syncthing serve --home=$APP_STATE --no-browser --no-restart --no-default-folder --gui-address=127.0.0.1:8384 --logflags=0
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=$APP_STATE

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$APP_SERVICE"

printf '[4/7] 开启“手机分享后 VPS 永久自动接收”……\n'
API_KEY=''
for attempt in $(seq 1 120); do
  if [[ -s "$APP_STATE/config.xml" ]]; then
    API_KEY=$(python3 - "$APP_STATE/config.xml" <<'PY' 2>/dev/null || true
import sys, xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).findtext('gui/apikey') or '')
PY
)
    if [[ -n $API_KEY ]] && curl -fsS --max-time 2 -H "X-API-Key: $API_KEY" \
      "$API_URL/rest/system/status" >/dev/null 2>&1; then
      break
    fi
  fi
  (( attempt % 10 == 0 )) && printf '.'
  sleep 0.5
done
printf '\n'
[[ -n $API_KEY ]] || fail '60 秒内没有生成 Syncthing API 密钥。'
curl -fsS --max-time 2 -H "X-API-Key: $API_KEY" "$API_URL/rest/system/status" >/dev/null || \
  fail '60 秒内 Syncthing API 没有启动。'

# BEGIN CONFIGURE_AUTO_SYNC_PY
python3 - "$APP_STATE" "$SYNC_ROOT" "$ANDROID_ID" "$API_URL" "$API_KEY" <<'PY'
import json
import pathlib
import sys
import urllib.request

state = pathlib.Path(sys.argv[1])
sync_root = sys.argv[2]
android_id, base, api_key = sys.argv[3:6]
headers = {'X-API-Key': api_key, 'Content-Type': 'application/json'}

def request(path, method='GET', obj=None):
    data = None if obj is None else json.dumps(obj).encode()
    req = urllib.request.Request(base + '/rest/' + path, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as response:
        body = response.read()
    return json.loads(body) if body else None

config = request('config')
server_id = request('system/status')['myID']
if android_id == server_id:
    raise SystemExit('你填的是 VPS 的设备 ID；需要安卓手机的设备 ID。')

marker = state / '.android-device-id'
old_id = marker.read_text().strip() if marker.exists() else ''
if old_id and old_id != android_id:
    config['devices'] = [item for item in config.get('devices', []) if item.get('deviceID') != old_id]
    for folder in config.get('folders', []):
        folder['devices'] = [item for item in folder.get('devices', []) if item.get('deviceID') != old_id]

device = next((item for item in config.get('devices', []) if item.get('deviceID') == android_id), None)
if device is None:
    device = {
        'deviceID': android_id,
        'name': 'Android',
        'addresses': ['dynamic'],
        'compression': 'metadata',
        'introducer': False,
    }
    config.setdefault('devices', []).append(device)
device.update({'addresses': ['dynamic'], 'autoAcceptFolders': True})
device['paused'] = False
device['allowedNetworks'] = []

defaults = config.setdefault('defaults', {}).setdefault('folder', {})
defaults.update({
    'path': sync_root,
    'type': 'sendreceive',
    'rescanIntervalS': 3600,
    'fsWatcherEnabled': True,
    'fsWatcherDelayS': 5,
    'ignorePerms': True,
    'versioning': {'type': 'simple', 'params': {'keep': '10'}},
})

folder = next((item for item in config.get('folders', []) if item.get('id') == 'pc-downloads'), None)
if folder is None:
    folder = {'id': 'pc-downloads', 'devices': []}
    config.setdefault('folders', []).append(folder)
folder.update({
    'label': '电脑下载',
    'path': str(pathlib.Path(sync_root) / '电脑下载'),
    'type': 'sendreceive',
    'rescanIntervalS': 3600,
    'fsWatcherEnabled': True,
    'fsWatcherDelayS': 5,
    'ignorePerms': True,
    'versioning': {'type': 'simple', 'params': {'keep': '10'}},
})
shared = {item.get('deviceID') for item in folder.get('devices', [])}
for wanted in (server_id, android_id):
    if wanted not in shared:
        folder.setdefault('devices', []).append({'deviceID': wanted})

options = config.setdefault('options', {})
options.update({
    'listenAddresses': [
        'tcp://0.0.0.0:22000',
        'quic://0.0.0.0:22000',
        'dynamic+https://relays.syncthing.net/endpoint',
    ],
    'globalAnnounceServers': ['default'],
    'startBrowser': False,
    'localAnnounceEnabled': True,
    'globalAnnounceEnabled': True,
    'relaysEnabled': True,
    'natEnabled': True,
    'reconnectionIntervalS': 10,
    'maxFolderConcurrency': 1,
})
if 'databaseTuning' in options:
    options['databaseTuning'] = 'small'
if 'crashReportingEnabled' in options:
    options['crashReportingEnabled'] = False
if 'urAccepted' in options:
    options['urAccepted'] = -1

request('config', 'PUT', config)
saved = request('config')
saved_device = next((item for item in saved.get('devices', []) if item.get('deviceID') == android_id), None)
if not saved_device or saved_device.get('autoAcceptFolders') is not True:
    raise SystemExit('写入后验证失败：自动接收没有开启。')
if pathlib.Path(saved.get('defaults', {}).get('folder', {}).get('path', '')) != pathlib.Path(sync_root):
    raise SystemExit('写入后验证失败：云盘目录不正确。')

(state / '.server-id').write_text(server_id + '\n')
marker.write_text(android_id + '\n')
PY
# END CONFIGURE_AUTO_SYNC_PY

chown "$APP_USER:$APP_GROUP" "$APP_STATE/.server-id" "$APP_STATE/.android-device-id"
systemctl restart "$APP_SERVICE"
for _ in $(seq 1 60); do
  if systemctl is-active --quiet "$APP_SERVICE" \
    && ss -H -ltn 'sport = :22000' | grep -q . \
    && ss -H -lun 'sport = :22000' | grep -q .; then
    break
  fi
  sleep 0.5
done
systemctl is-active --quiet "$APP_SERVICE" || fail '同步服务重启失败。'

if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 22000/tcp >/dev/null
  ufw allow 22000/udp >/dev/null
fi
ss -H -ltn 'sport = :22000' | grep -q . || fail 'Syncthing TCP 22000 没有监听。'
ss -H -lun 'sport = :22000' | grep -q . || fail 'Syncthing UDP 22000 没有监听。'

printf '[5/7] 下载并校验网页云盘安装器……\n'
TEMP_DIR=$(mktemp -d /tmp/auto-sync-cloud.XXXXXX)
curl -fL --retry 3 --connect-timeout 15 "$CLOUD_INSTALLER_URL" -o "$TEMP_DIR/install-cloud-drive.sh"
printf '%s  %s\n' "$CLOUD_INSTALLER_SHA" "$TEMP_DIR/install-cloud-drive.sh" | sha256sum -c -
bash -n "$TEMP_DIR/install-cloud-drive.sh"

printf '[6/7] 安装网页云盘……\n'
GAME_DRIVE_SKIP_APT=1 bash "$TEMP_DIR/install-cloud-drive.sh" "$WEB_USER" "$WEB_PASSWORD"

printf '[7/7] 最终检查……\n'
systemctl is-active --quiet "$APP_SERVICE" || fail '同步服务没有运行。'
systemctl is-active --quiet game-save-drive.service || fail '网页云盘没有运行。'

SERVER_ID=$(<"$APP_STATE/.server-id")
PORT=$(<"$APP_STATE/web/port")
PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')
[[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || PUBLIC_IP='你的VPS-IP'
if [[ $PORT == 443 ]]; then CLOUD_URL="https://$PUBLIC_IP/"; else CLOUD_URL="https://$PUBLIC_IP:$PORT/"; fi

printf '\n========== 全部安装成功 ==========\n'
printf '云盘地址：%s\n用户名：%s\n密码：%s\n' "$CLOUD_URL" "$WEB_USER" "$WEB_PASSWORD"
printf 'VPS 设备 ID：%s\n' "$SERVER_ID"
if [[ $HAVE_QR == 1 ]] && command -v qrencode >/dev/null 2>&1; then
  printf '\n手机 Syncthing-Fork → 添加设备 → 扫描下面二维码 → 保存：\n'
  qrencode -t ANSIUTF8 "$SERVER_ID" || true
else
  printf '\n手机 Syncthing-Fork → 添加设备 → 粘贴上面的 VPS 设备 ID → 保存。\n'
fi
printf '\n以后添加任何目录都只在手机操作：文件夹 → “+” → 选择目录 → 共享设备勾选 VPS → 保存。\n'
printf 'VPS 会永久自动接收，文件进入网页云盘；不再登录 VPS，不再运行代码。\n'
printf 'VPS 实际总目录：%s\n' "$SYNC_ROOT"
printf '\n电脑直接下载到 VPS：在 Windows PowerShell 复制下面一整行，只运行一次：\n'
printf "powershell -NoProfile -ExecutionPolicy Bypass -Command \"\$p=Join-Path \$env:TEMP 'windows-direct-download.ps1'; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/marceldun/ntm/main/windows-direct-download.ps1' -OutFile \$p; if((Get-FileHash \$p -Algorithm SHA256).Hash -ne '%s'.ToUpper()){throw 'SHA256 check failed'}; & \$p\"\n" "$WINDOWS_SETUP_SHA"
printf '手机收到“电脑下载”邀请后，选择手机 Download 目录并保存，只做一次。\n'
