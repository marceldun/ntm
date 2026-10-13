#!/usr/bin/env bash
# One-time switch: automatically accept every folder shared by the paired Android device.
# After this, new folders are added only from Syncthing-Fork; no VPS command is needed.
set -Eeuo pipefail
umask 077

readonly APP_USER='gamesync'
readonly APP_GROUP='gamesync'
readonly APP_STATE='/var/lib/game-save-sync'
readonly APP_SERVICE='game-save-sync.service'
readonly SYNC_ROOT="$APP_STATE/saves"
readonly API_URL='http://127.0.0.1:8384'

fail() { printf '\n错误：%s\n' "$*" >&2; exit 1; }
on_error() {
  local code=$?
  printf '\n设置失败：第 %s 行，退出码 %s。查看日志：journalctl -u %s -n 80 --no-pager\n' \
    "${BASH_LINENO[0]:-${LINENO}}" "$code" "$APP_SERVICE" >&2
  exit "$code"
}
trap on_error ERR

[[ $EUID -eq 0 ]] || fail '请使用 root 或 sudo 运行。'
[[ -d /run/systemd/system ]] || fail '这台 VPS 没有运行 systemd。'
[[ -s "$APP_STATE/config.xml" ]] || fail '没有找到现有同步配置；请先运行 gamesave-sync.sh。'
[[ -s "$APP_STATE/.android-device-id" ]] || fail '没有找到已配对的安卓设备；请先运行 gamesave-sync.sh。'
id "$APP_USER" >/dev/null 2>&1 || fail 'gamesync 服务账户不存在；请先运行 gamesave-sync.sh。'
getent group "$APP_GROUP" >/dev/null || fail 'gamesync 服务组不存在；请先运行 gamesave-sync.sh。'

ANDROID_ID=$(tr -d '[:space:]' < "$APP_STATE/.android-device-id")
[[ $ANDROID_ID =~ ^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$ ]] || fail '保存的安卓设备 ID 无效。'

printf '[1/3] 准备云盘总目录……\n'
install -d -o "$APP_USER" -g "$APP_GROUP" -m 0700 "$SYNC_ROOT"

printf '[2/3] 连接同步服务……\n'
systemctl start "$APP_SERVICE"
API_KEY=''
for _ in $(seq 1 60); do
  API_KEY=$(python3 - "$APP_STATE/config.xml" <<'PY' 2>/dev/null || true
import sys, xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).findtext('gui/apikey') or '')
PY
)
  if [[ -n $API_KEY ]] && curl -fsS --max-time 2 -H "X-API-Key: $API_KEY" \
    "$API_URL/rest/system/status" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
[[ -n $API_KEY ]] || fail '无法读取 Syncthing API 密钥。'
curl -fsS --max-time 2 -H "X-API-Key: $API_KEY" "$API_URL/rest/system/status" >/dev/null || \
  fail 'Syncthing 本地 API 没有启动。'

printf '[3/3] 开启“安卓分享后 VPS 自动接收”……\n'
# BEGIN ENABLE_AUTO_ACCEPT_PY
python3 - "$ANDROID_ID" "$SYNC_ROOT" "$API_URL" "$API_KEY" <<'PY'
import json
import pathlib
import sys
import urllib.request

android_id, sync_root, base, api_key = sys.argv[1:5]
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
    raise SystemExit('安卓设备不在 Syncthing 配置中；请先完成手机与 VPS 配对。')

# Syncthing will accept future folder offers from this one paired device only.
device['autoAcceptFolders'] = True
# Auto-accepted folders are created below the default folder template path.
config.setdefault('defaults', {}).setdefault('folder', {})['path'] = sync_root
request('config', 'PUT', config)

saved = request('config')
saved_device = next((item for item in saved.get('devices', []) if item.get('deviceID') == android_id), None)
if not saved_device or saved_device.get('autoAcceptFolders') is not True:
    raise SystemExit('写入后验证失败：自动接收没有开启。')
if pathlib.Path(saved.get('defaults', {}).get('folder', {}).get('path', '')) != pathlib.Path(sync_root):
    raise SystemExit('写入后验证失败：云盘目录不正确。')
PY
# END ENABLE_AUTO_ACCEPT_PY

printf '\n设置成功，而且只需设置这一次。\n'
printf '以后添加任意目录：手机 Syncthing-Fork → “文件夹”右上角“+” → 选择目录 → 在“共享设备”勾选 VPS → 保存。\n'
printf 'VPS 会自动接收，无需再登录 VPS；文件自动出现在网页云盘和 %s 下。\n' "$SYNC_ROOT"
printf 'Android 12 要求每个新目录首次由你点选一次，这是系统的文件访问授权，无法远程代点。\n'
