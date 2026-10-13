#!/usr/bin/env bash
# Repair VPS-side Syncthing connectivity for the preconfigured Android device.
set -Eeuo pipefail
umask 077

readonly APP_STATE='/var/lib/game-save-sync'
readonly APP_SERVICE='game-save-sync.service'
readonly API_URL='http://127.0.0.1:8384'
readonly ANDROID_ID='XFQ7AJQ-34V53ZD-DCIHLSA-7TERDRR-27RXR54-FZCKF4I-F3FHCSC-NV4SZA3'

fail() { printf '\n错误：%s\n' "$*" >&2; exit 1; }
on_error() { local rc=$?; printf '\n修复失败（第 %s 行，退出码 %s）。日志：journalctl -u %s -n 100 --no-pager\n' "${BASH_LINENO[0]:-${LINENO}}" "$rc" "$APP_SERVICE" >&2; exit "$rc"; }
trap on_error ERR

[[ $EUID -eq 0 ]] || fail '请使用 root 运行。'
[[ -d /run/systemd/system ]] || fail '这台 VPS 没有运行 systemd。'
[[ -s "$APP_STATE/config.xml" ]] || fail '没有找到同步配置，请运行最新版一键安装命令。'
for command in syncthing python3 curl systemctl ss; do command -v "$command" >/dev/null || fail "缺少命令：$command"; done

printf '[1/5] 修复目录权限和同步服务……\n'
getent group gamesync >/dev/null || groupadd --system gamesync
if ! id gamesync >/dev/null 2>&1; then
  useradd --system --gid gamesync --home-dir "$APP_STATE" --shell /usr/sbin/nologin gamesync
fi
chown -R gamesync:gamesync "$APP_STATE"
cat > "/etc/systemd/system/$APP_SERVICE" <<'EOF'
[Unit]
Description=Automatic Android folder synchronization
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=gamesync
Group=gamesync
UMask=0077
Environment=GOGC=35
Environment=GOMEMLIMIT=128MiB
ExecStart=/usr/bin/syncthing serve --home=/var/lib/game-save-sync --no-browser --no-restart --no-default-folder --gui-address=127.0.0.1:8384 --logflags=0
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=/var/lib/game-save-sync

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$APP_SERVICE" >/dev/null
systemctl restart "$APP_SERVICE"

printf '[2/5] 等待 Syncthing 本地接口……'
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
[[ -n $API_KEY ]] || fail '无法读取 API 密钥。'
curl -fsS --max-time 2 -H "X-API-Key: $API_KEY" "$API_URL/rest/system/status" >/dev/null || fail 'Syncthing 没有启动。'

printf '[3/5] 强制开启直连、QUIC、全局发现和中继……\n'
# BEGIN REPAIR_CONNECTION_PY
python3 - "$ANDROID_ID" "$API_URL" "$API_KEY" <<'PY'
import json
import sys
import urllib.request

android_id, base, api_key = sys.argv[1:4]
headers = {'X-API-Key': api_key, 'Content-Type': 'application/json'}
def request(path, method='GET', obj=None):
    data = None if obj is None else json.dumps(obj).encode()
    req = urllib.request.Request(base + '/rest/' + path, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as response:
        body = response.read()
    return json.loads(body) if body else None

config = request('config')
device = next((item for item in config.get('devices', []) if item.get('deviceID') == android_id), None)
if device is None:
    device = {'deviceID': android_id, 'name': 'Android'}
    config.setdefault('devices', []).append(device)
device.update({
    'name': device.get('name') or 'Android',
    'addresses': ['dynamic'],
    'compression': 'metadata',
    'paused': False,
    'autoAcceptFolders': True,
    'allowedNetworks': [],
})

options = config.setdefault('options', {})
options.update({
    'listenAddresses': [
        'tcp://0.0.0.0:22000',
        'quic://0.0.0.0:22000',
        'dynamic+https://relays.syncthing.net/endpoint',
    ],
    'globalAnnounceServers': ['default'],
    'globalAnnounceEnabled': True,
    'localAnnounceEnabled': True,
    'relaysEnabled': True,
    'natEnabled': True,
    'reconnectionIntervalS': 10,
})
request('config', 'PUT', config)
saved = request('config')
saved_device = next(item for item in saved['devices'] if item.get('deviceID') == android_id)
expected = {'tcp://0.0.0.0:22000', 'quic://0.0.0.0:22000', 'dynamic+https://relays.syncthing.net/endpoint'}
if saved_device.get('paused') or saved_device.get('addresses') != ['dynamic']:
    raise SystemExit('安卓设备配置验证失败。')
if not expected.issubset(set(saved.get('options', {}).get('listenAddresses', []))):
    raise SystemExit('监听地址验证失败。')
PY
# END REPAIR_CONNECTION_PY

printf '[4/5] 开放防火墙并重启……\n'
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22000/tcp >/dev/null 2>&1 || true
  ufw allow 22000/udp >/dev/null 2>&1 || true
fi
systemctl restart "$APP_SERVICE"
for attempt in $(seq 1 60); do
  if systemctl is-active --quiet "$APP_SERVICE" && ss -H -ltn 'sport = :22000' | grep -q .; then break; fi
  (( attempt % 10 == 0 )) && printf '.'
  sleep 0.5
done
printf '\n'
systemctl is-active --quiet "$APP_SERVICE" || fail '服务重启失败。'
ss -H -ltn 'sport = :22000' | grep -q . || fail 'TCP 22000 没有监听。'
ss -H -lun 'sport = :22000' | grep -q . || fail 'UDP 22000 没有监听。'

printf '[5/5] 等待安卓连接（最多 60 秒）……'
CONNECTED=0
CONNECTION_TYPE=''
for attempt in $(seq 1 60); do
  RESULT=$(python3 - "$ANDROID_ID" "$API_URL" "$API_KEY" <<'PY' 2>/dev/null || true
import json, sys, urllib.request
device, base, key = sys.argv[1:4]
req = urllib.request.Request(base + '/rest/system/connections', headers={'X-API-Key': key})
with urllib.request.urlopen(req, timeout=3) as response: data = json.load(response)
item = data.get('connections', {}).get(device, {})
print(('1' if item.get('connected') else '0') + '\t' + str(item.get('type', '')))
PY
)
  if [[ ${RESULT%%$'\t'*} == 1 ]]; then CONNECTED=1; CONNECTION_TYPE=${RESULT#*$'\t'}; break; fi
  (( attempt % 5 == 0 )) && printf '.'
  sleep 1
done
printf '\n'

if [[ $CONNECTED == 1 ]]; then
  printf '\n修复成功：安卓已经连接，通道：%s。自动同步已恢复。\n' "${CONNECTION_TYPE:-Syncthing}"
else
  printf '\nVPS 已修复并确认 TCP/UDP 22000 正常监听。\n'
  printf '现在只需在手机打开 Syncthing-Fork，并确认顶部开关为“运行”；连接会自动建立，不要重新扫码。\n'
fi
