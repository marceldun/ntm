#!/usr/bin/env bash
# V11 complete cloud-drive installer: fixed port, verified login, and low-memory self-healing.
set -Eeuo pipefail
umask 077

readonly DRIVE_ROOT='/var/lib/game-save-sync/saves'
readonly DRIVE_STATE='/var/lib/game-save-sync/web'
readonly DRIVE_APP='/opt/game-save-drive'
readonly DRIVE_ENV='/etc/game-save-drive.env'
readonly DRIVE_SERVICE='game-save-drive.service'
readonly HEALTH_SERVICE='game-save-drive-health.service'
readonly HEALTH_TIMER='game-save-drive-health.timer'
readonly HEALTH_SCRIPT='/usr/local/sbin/game-save-drive-healthcheck'
readonly PORT=8443
readonly APP_URL='https://raw.githubusercontent.com/marceldun/ntm/2d2d8c861d49ef3e52f827b5c049e218c341afd6/v11-web-folder-android-invite/cloud-drive/app.py'
readonly UI_URL='https://raw.githubusercontent.com/marceldun/ntm/2d2d8c861d49ef3e52f827b5c049e218c341afd6/v11-web-folder-android-invite/cloud-drive/index.html'
readonly APP_SHA='df964f451a934be3485c7950403fbe6ee557a5ca5337270ffa93b08acd47b2bc'
readonly UI_SHA='e277e822ca061b6095dd2b18aa06b61293d53376e4c816a4be7e2b18507b6288'

USERNAME="${1:-marcel}"
PASSWORD="${2:-456qwe456}"
PUBLIC_IP="${3:-}"
SYNCTHING_API_KEY="${4:-}"
ANDROID_ID="${5:-}"
TEMP_DIR=''

fail(){ printf '\n错误：%s\n' "$*" >&2; exit 1; }
on_error(){ local rc=$?; printf '\n安装失败（第 %s 行，退出码 %s）。日志：journalctl -u %s -n 80 --no-pager\n' "${BASH_LINENO[0]:-${LINENO}}" "$rc" "$DRIVE_SERVICE" >&2; exit "$rc"; }
cleanup(){ [[ -n $TEMP_DIR && -d $TEMP_DIR ]] && rm -rf -- "$TEMP_DIR"; }
trap on_error ERR
trap cleanup EXIT

[[ $EUID -eq 0 ]] || fail '请使用 root 或 sudo 运行。'
[[ -d /run/systemd/system ]] || fail '这台 VPS 没有运行 systemd。'
source /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
  *) fail "不支持 ${PRETTY_NAME:-当前系统}。" ;;
esac
[[ $USERNAME =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || fail '用户名格式不正确。'
[[ ${#PASSWORD} -ge 8 ]] || fail '密码至少需要 8 位。'
[[ -d $DRIVE_ROOT ]] || fail "没有找到 $DRIVE_ROOT；请先完成完整同步安装。"
if [[ -z $SYNCTHING_API_KEY && -s /var/lib/game-save-sync/config.xml ]]; then
  SYNCTHING_API_KEY=$(python3 - /var/lib/game-save-sync/config.xml <<'PY'
import sys, xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).findtext('gui/apikey') or '')
PY
  )
fi
if [[ -z $ANDROID_ID && -s /var/lib/game-save-sync/.android-device-id ]]; then
  ANDROID_ID=$(tr -d '\r\n' < /var/lib/game-save-sync/.android-device-id)
fi
[[ $SYNCTHING_API_KEY =~ ^[A-Za-z0-9]+$ ]] || fail '无法读取 Syncthing API 密钥。'
[[ $ANDROID_ID =~ ^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$ ]] || fail '无法读取安卓设备 ID。'

printf '[1/6] 安装运行依赖……\n'
if [[ ${GAME_DRIVE_SKIP_APT:-0} != 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends python3 ca-certificates curl openssl iproute2
fi
for dependency in python3 curl openssl ss; do command -v "$dependency" >/dev/null || fail "缺少运行依赖：$dependency"; done

printf '[2/6] 下载并校验云盘程序……\n'
TEMP_DIR=$(mktemp -d /tmp/game-save-drive-v11.XXXXXX)
curl -fL --retry 5 --retry-all-errors --connect-timeout 15 "$APP_URL" -o "$TEMP_DIR/app.py"
curl -fL --retry 5 --retry-all-errors --connect-timeout 15 "$UI_URL" -o "$TEMP_DIR/index.html"
printf '%s  %s\n' "$APP_SHA" "$TEMP_DIR/app.py" | sha256sum -c -
printf '%s  %s\n' "$UI_SHA" "$TEMP_DIR/index.html" | sha256sum -c -
python3 -m py_compile "$TEMP_DIR/app.py"
install -d -o root -g root -m 0755 "$DRIVE_APP"
install -o root -g root -m 0644 "$TEMP_DIR/app.py" "$DRIVE_APP/app.py"
install -o root -g root -m 0644 "$TEMP_DIR/index.html" "$DRIVE_APP/index.html"

printf '[3/6] 修复账户、密码和 HTTPS 证书……\n'
getent group gamesync >/dev/null || groupadd --system gamesync
if ! id gamesync >/dev/null 2>&1; then
  useradd --system --gid gamesync --home-dir /var/lib/game-save-sync --shell /usr/sbin/nologin gamesync
fi
install -d -o gamesync -g gamesync -m 0700 "$DRIVE_STATE" "$DRIVE_STATE/temp"
chown -R gamesync:gamesync "$DRIVE_ROOT"
EXISTING_SESSION_SECRET=''
if [[ -r $DRIVE_ENV ]]; then EXISTING_SESSION_SECRET=$(sed -n 's/^DRIVE_SESSION_SECRET=//p' "$DRIVE_ENV" | head -n 1); fi
export DRIVE_SETUP_PASSWORD="$PASSWORD" DRIVE_SETUP_SESSION_SECRET="$EXISTING_SESSION_SECRET"
AUTH_DATA=$(python3 - "$USERNAME" <<'PY'
import base64, hashlib, os, secrets, sys
def b64(value): return base64.urlsafe_b64encode(value).decode().rstrip('=')
salt = secrets.token_bytes(16)
password_hash = hashlib.pbkdf2_hmac('sha256', os.environ['DRIVE_SETUP_PASSWORD'].encode(), salt, 310_000)
session_secret = os.environ.get('DRIVE_SETUP_SESSION_SECRET') or b64(secrets.token_bytes(32))
print('DRIVE_USERNAME=' + sys.argv[1])
print('DRIVE_PASSWORD_SALT=' + b64(salt))
print('DRIVE_PASSWORD_HASH=' + b64(password_hash))
print('DRIVE_SESSION_SECRET=' + session_secret)
PY
)
unset DRIVE_SETUP_PASSWORD DRIVE_SETUP_SESSION_SECRET EXISTING_SESSION_SECRET
printf '%s\n' "$AUTH_DATA" > "$DRIVE_ENV"
printf 'SYNCTHING_API_URL=http://127.0.0.1:8384\nSYNCTHING_API_KEY=%s\nSYNCTHING_ANDROID_DEVICE_ID=%s\n' \
  "$SYNCTHING_API_KEY" "$ANDROID_ID" >> "$DRIVE_ENV"
chmod 0600 "$DRIVE_ENV"

if [[ ! $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then PUBLIC_IP=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true); fi
if [[ ! $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'); fi
[[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || PUBLIC_IP='127.0.0.1'
RENEW_CERT=0
[[ -s "$DRIVE_STATE/cert.pem" && -s "$DRIVE_STATE/key.pem" ]] || RENEW_CERT=1
if (( RENEW_CERT == 0 )); then
  openssl x509 -checkend 2592000 -noout -in "$DRIVE_STATE/cert.pem" >/dev/null 2>&1 || RENEW_CERT=1
  openssl x509 -noout -ext subjectAltName -in "$DRIVE_STATE/cert.pem" 2>/dev/null | grep -Fq "IP Address:$PUBLIC_IP" || RENEW_CERT=1
  if ! openssl x509 -noout -modulus -in "$DRIVE_STATE/cert.pem" 2>/dev/null | sha256sum > "$TEMP_DIR/cert.mod"; then RENEW_CERT=1; fi
  if ! openssl rsa -noout -modulus -in "$DRIVE_STATE/key.pem" 2>/dev/null | sha256sum > "$TEMP_DIR/key.mod"; then RENEW_CERT=1; fi
  cmp -s "$TEMP_DIR/cert.mod" "$TEMP_DIR/key.mod" || RENEW_CERT=1
fi
if (( RENEW_CERT == 1 )); then
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 -subj "/CN=$PUBLIC_IP" \
    -addext "subjectAltName=IP:$PUBLIC_IP,IP:127.0.0.1" -keyout "$DRIVE_STATE/key.pem.new" -out "$DRIVE_STATE/cert.pem.new" >/dev/null 2>&1
  mv -f "$DRIVE_STATE/key.pem.new" "$DRIVE_STATE/key.pem"
  mv -f "$DRIVE_STATE/cert.pem.new" "$DRIVE_STATE/cert.pem"
fi
chown gamesync:gamesync "$DRIVE_STATE/cert.pem" "$DRIVE_STATE/key.pem"
chmod 0600 "$DRIVE_STATE/key.pem"
printf '%s\n' "$PORT" > "$DRIVE_STATE/port"
chown gamesync:gamesync "$DRIVE_STATE/port"

printf '[4/6] 固定 8443 并安装开机自启、自愈服务……\n'
systemctl stop "$HEALTH_TIMER" "$DRIVE_SERVICE" 2>/dev/null || true
if ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q .; then
  fail "端口 $PORT 被其他程序占用：$(ss -H -ltnp "sport = :$PORT" 2>/dev/null | head -n 1)"
fi
cat > "/etc/systemd/system/$DRIVE_SERVICE" <<EOF
[Unit]
Description=V11 self-healing VPS cloud drive
After=network-online.target game-save-sync.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=gamesync
Group=gamesync
UMask=0077
EnvironmentFile=$DRIVE_ENV
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 $DRIVE_APP/app.py --root $DRIVE_ROOT --static $DRIVE_APP --temp $DRIVE_STATE/temp --host 0.0.0.0 --port $PORT --cert $DRIVE_STATE/cert.pem --key $DRIVE_STATE/key.pem
Restart=always
RestartSec=3
MemoryMax=128M
TasksMax=64
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
cat > "$HEALTH_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -u
if curl -kfsS --connect-timeout 3 --max-time 8 https://127.0.0.1:8443/ >/dev/null; then exit 0; fi
systemctl restart game-save-drive.service
for _ in $(seq 1 20); do
  curl -kfsS --connect-timeout 2 --max-time 3 https://127.0.0.1:8443/ >/dev/null && exit 0
  sleep 0.5
done
exit 1
EOF
chmod 0755 "$HEALTH_SCRIPT"
cat > "/etc/systemd/system/$HEALTH_SERVICE" <<EOF
[Unit]
Description=Repair the VPS cloud drive if its HTTPS check fails
After=network-online.target

[Service]
Type=oneshot
ExecStart=$HEALTH_SCRIPT
MemoryMax=32M
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
EOF
cat > "/etc/systemd/system/$HEALTH_TIMER" <<EOF
[Unit]
Description=Check the VPS cloud drive every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true
Unit=$HEALTH_SERVICE

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now "$DRIVE_SERVICE" "$HEALTH_TIMER"
if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow 8443/tcp >/dev/null; fi
for _ in $(seq 1 60); do
  curl -kfsS --max-time 2 "https://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -kfsS --max-time 3 "https://127.0.0.1:$PORT/" >/dev/null || fail '网页服务没有启动。'
ss -H -ltn "sport = :$PORT" | grep -q . || fail '8443 端口没有监听。'

printf '[5/6] 验证真实登录、上传和下载……\n'
export DRIVE_VERIFY_PASSWORD="$PASSWORD"
python3 - "$USERNAME" "$PORT" <<'PY'
import hashlib, http.cookiejar, json, os, ssl, sys, urllib.parse, urllib.request
user, port = sys.argv[1], int(sys.argv[2]); base = f'https://127.0.0.1:{port}'
context = ssl._create_unverified_context()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), urllib.request.HTTPSHandler(context=context))
req = urllib.request.Request(base + '/api/login', data=json.dumps({'username':user,'password':os.environ['DRIVE_VERIFY_PASSWORD']}).encode(), headers={'Content-Type':'application/json'})
with opener.open(req, timeout=8) as response: assert json.load(response)['ok']
payload = os.urandom(262144); name = 'v11-install-test.bin'
req = urllib.request.Request(base + '/api/upload?path=&name=' + urllib.parse.quote(name), data=payload, method='POST', headers={'Content-Type':'application/octet-stream'})
with opener.open(req, timeout=15) as response: assert json.load(response)['ok']
def post(path, body):
    request = urllib.request.Request(base + path, data=json.dumps(body).encode(), method='POST', headers={'Content-Type':'application/json'})
    with opener.open(request, timeout=8) as response: return json.load(response)
assert post('/api/rename', {'path':name, 'name':'v11-renamed-test.bin'})['ok']
created = post('/api/mkdir', {'path':'', 'name':'v11-install-folder'})
assert created['ok'] and created['androidInvitation'] is True
assert post('/api/move', {'paths':['v11-renamed-test.bin'], 'destination':'v11-install-folder'})['ok']
with opener.open(base + '/api/download?path=' + urllib.parse.quote('v11-install-folder/v11-renamed-test.bin'), timeout=15) as response: downloaded = response.read()
assert hashlib.sha256(downloaded).digest() == hashlib.sha256(payload).digest()
with opener.open(base + '/api/folders', timeout=8) as response: assert any(item['path'] == 'v11-install-folder' for item in json.load(response)['folders'])
assert post('/api/delete', {'paths':['v11-install-folder']})['deleted'] == 1
with opener.open(base + '/api/list?path=', timeout=8) as response: assert 'entries' in json.load(response)
PY
unset DRIVE_VERIFY_PASSWORD PASSWORD AUTH_DATA

printf '[6/6] 验证异常退出后自动恢复……\n'
OLD_PID=$(systemctl show -p MainPID --value "$DRIVE_SERVICE")
kill -KILL "$OLD_PID"
NEW_PID='0'
for _ in $(seq 1 60); do
  NEW_PID=$(systemctl show -p MainPID --value "$DRIVE_SERVICE")
  if [[ $NEW_PID != 0 && $NEW_PID != "$OLD_PID" ]] && curl -kfsS --max-time 2 "https://127.0.0.1:$PORT/" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
[[ $NEW_PID != 0 && $NEW_PID != "$OLD_PID" ]] || fail '自动恢复测试失败。'
curl -kfsS --max-time 3 "https://127.0.0.1:$PORT/" >/dev/null || fail '恢复后的网页服务不可用。'
systemctl is-enabled --quiet "$DRIVE_SERVICE"
systemctl is-enabled --quiet "$HEALTH_TIMER"
systemctl is-active --quiet "$DRIVE_SERVICE"
systemctl is-active --quiet "$HEALTH_TIMER"
printf '\nV11 云盘已修复。\n云盘地址：https://%s:8443/\n用户名：%s\n存档位置：%s\n' "$PUBLIC_IP" "$USERNAME" "$DRIVE_ROOT"
printf '固定 8443、开机自启、进程自动重启和每分钟健康检查均已启用。\n'
