#!/usr/bin/env bash
# Game Save Sync v2 — Ubuntu 22.04/24.04, Debian 12/13
# Usage: sudo bash gamesave-sync.sh [ANDROID_DEVICE_ID]
set -Eeuo pipefail
umask 077

readonly APP_USER='gamesync'
readonly APP_GROUP='gamesync'
readonly APP_STATE='/var/lib/game-save-sync'
readonly APP_SERVICE='game-save-sync.service'
readonly API_URL='http://127.0.0.1:8384'
ANDROID_ID="${1:-}"

fail() { printf '\n错误：%s\n' "$*" >&2; exit 1; }
on_error() {
  local code=$?
  printf '\n安装失败：第 %s 行，退出码 %s。查看日志：sudo journalctl -u %s -n 80 --no-pager\n' \
    "${BASH_LINENO[0]:-${LINENO}}" "$code" "$APP_SERVICE" >&2
  exit "$code"
}
trap on_error ERR

[[ $EUID -eq 0 ]] || fail '请运行：sudo bash gamesave-sync.sh'
[[ -d /run/systemd/system ]] || fail '这台机器没有运行 systemd，不支持本脚本。'
[[ -r /etc/os-release ]] || fail '无法识别操作系统。'
source /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
  *) fail "仅支持 Ubuntu 22.04/24.04 或 Debian 12/13；当前是 ${PRETTY_NAME:-未知系统}。" ;;
esac

if [[ -z $ANDROID_ID ]]; then
  printf '在安卓 Syncthing-Fork 中打开“本机设备 ID”，复制后粘贴到这里。\n'
  read -r -p '安卓设备 ID: ' ANDROID_ID
fi
ANDROID_ID=${ANDROID_ID^^}
[[ $ANDROID_ID =~ ^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$ ]] || \
  fail '安卓设备 ID 格式不对：必须是 8 组、每组 7 个字符。'

printf '[1/5] 安装 Syncthing（Ubuntu/Debian 官方签名软件包）……\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends syncthing python3 ca-certificates curl
# QR output saves typing, but its optional package must never block synchronization.
if apt-get install -y --no-install-recommends qrencode; then
  HAVE_QRENCODE=1
else
  HAVE_QRENCODE=0
fi
command -v syncthing >/dev/null || fail 'Syncthing 安装后仍找不到。'
syncthing serve --help >/dev/null 2>&1 || fail '系统 Syncthing 版本过旧，不支持 serve 命令。'

printf '[2/5] 创建低权限服务账户和存档目录……\n'
getent group "$APP_GROUP" >/dev/null || groupadd --system "$APP_GROUP"
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --gid "$APP_GROUP" --home-dir "$APP_STATE" --shell /usr/sbin/nologin "$APP_USER"
fi
[[ $(id -gn "$APP_USER") == "$APP_GROUP" ]] || usermod --gid "$APP_GROUP" "$APP_USER"
install -d -o "$APP_USER" -g "$APP_GROUP" -m 0700 "$APP_STATE"
for name in aethersx2 azahar ppsspp; do
  install -d -o "$APP_USER" -g "$APP_GROUP" -m 0700 "$APP_STATE/saves/$name"
done
# Repair files left by an interrupted or manually pasted older installer.
chown -R "$APP_USER:$APP_GROUP" "$APP_STATE"

printf '[3/5] 安装并启动低内存 systemd 服务……\n'
systemctl stop "$APP_SERVICE" 2>/dev/null || true
cat > "/etc/systemd/system/$APP_SERVICE" <<EOF
[Unit]
Description=Automatic Android emulator save synchronization
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

printf '[4/5] 等待本地 API，然后自动写入安卓设备和三个同步目录……\n'
API_KEY=''
for _ in $(seq 1 120); do
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
  sleep 0.5
done
[[ -n $API_KEY ]] || fail '60 秒内没有生成 API 密钥。'
curl -fsS --max-time 2 -H "X-API-Key: $API_KEY" "$API_URL/rest/system/status" >/dev/null || \
  fail '60 秒内 Syncthing API 没有启动。'

# BEGIN CONFIGURE_API_PY
python3 - "$APP_STATE" "$ANDROID_ID" "$API_URL" "$API_KEY" <<'PY'
import json
import pathlib
import sys
import urllib.request

state = pathlib.Path(sys.argv[1])
android_id, base, api_key = sys.argv[2:5]
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
    raise SystemExit('你填的是 VPS 的设备 ID；需要填写安卓手机的设备 ID。')

old_marker = state / '.android-device-id'
old_id = old_marker.read_text().strip() if old_marker.exists() else ''
if old_id and old_id != android_id:
    config['devices'] = [d for d in config['devices'] if d.get('deviceID') != old_id]
    for folder in config['folders']:
        folder['devices'] = [d for d in folder.get('devices', []) if d.get('deviceID') != old_id]

device = next((d for d in config['devices'] if d.get('deviceID') == android_id), None)
if device is None:
    device = {
        'deviceID': android_id,
        'name': 'Android',
        'addresses': ['dynamic'],
        'compression': 'metadata',
        'introducer': False,
        'autoAcceptFolders': False,
    }
    config['devices'].append(device)
else:
    device['name'] = device.get('name') or 'Android'
    device['addresses'] = ['dynamic']

for name in ('aethersx2', 'azahar', 'ppsspp'):
    folder_id = 'saves-' + name
    path = str(state / 'saves' / name)
    folder = next((f for f in config['folders'] if f.get('id') == folder_id), None)
    if folder is None:
        folder = {
            'id': folder_id,
            'label': name,
            'path': path,
            'type': 'sendreceive',
            'devices': [],
            'rescanIntervalS': 3600,
            'fsWatcherEnabled': True,
            'fsWatcherDelayS': 5,
            'ignorePerms': True,
            'versioning': {'type': 'simple', 'params': {'keep': '10'}},
        }
        config['folders'].append(folder)
    folder.update({
        'label': name,
        'path': path,
        'type': 'sendreceive',
        'fsWatcherEnabled': True,
        'fsWatcherDelayS': 5,
        'rescanIntervalS': 3600,
        'ignorePerms': True,
        'versioning': {'type': 'simple', 'params': {'keep': '10'}},
    })
    known = {d.get('deviceID') for d in folder.get('devices', [])}
    for wanted in (server_id, android_id):
        if wanted not in known:
            folder.setdefault('devices', []).append({'deviceID': wanted})

options = config['options']
options['startBrowser'] = False
options['localAnnounceEnabled'] = False
options['globalAnnounceEnabled'] = True
options['relaysEnabled'] = True
options['maxFolderConcurrency'] = 1
if 'databaseTuning' in options:
    options['databaseTuning'] = 'small'
if 'crashReportingEnabled' in options:
    options['crashReportingEnabled'] = False
if 'urAccepted' in options:
    options['urAccepted'] = -1

request('config', 'PUT', config)
(state / '.server-id').write_text(server_id + '\n')
old_marker.write_text(android_id + '\n')
print(server_id)
PY
# END CONFIGURE_API_PY

chown "$APP_USER:$APP_GROUP" "$APP_STATE/.server-id" "$APP_STATE/.android-device-id"
systemctl restart "$APP_SERVICE"
for _ in $(seq 1 60); do
  systemctl is-active --quiet "$APP_SERVICE" && break
  sleep 0.5
done
systemctl is-active --quiet "$APP_SERVICE" || fail '服务重启失败。'

if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 22000/tcp >/dev/null
  ufw allow 22000/udp >/dev/null
fi

SERVER_ID=$(<"$APP_STATE/.server-id")
printf '[5/5] 完成。VPS 设备 ID：\n%s\n\n' "$SERVER_ID"
if [[ $HAVE_QRENCODE == 1 ]] && command -v qrencode >/dev/null 2>&1; then
  printf '安卓操作：Syncthing-Fork → 添加设备 → 扫描下面二维码 → 保存。\n'
  qrencode -t ANSIUTF8 "$SERVER_ID" || true
else
  printf '安卓操作：Syncthing-Fork → 添加设备 → 粘贴上面的 VPS 设备 ID → 保存。\n'
fi
printf '\n随后接受 3 个共享邀请，各选择一次对应模拟器的真实存档目录。以后自动上传、自动下载。\n'
printf '服务状态：sudo systemctl status %s --no-pager\n' "$APP_SERVICE"
printf '注意：安卓 12 无 root 通常无法让同步软件读取 AetherSX2 的 Android/data 私有目录。\n'

