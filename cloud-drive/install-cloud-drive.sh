#!/usr/bin/env bash
# Install Game Save Drive on Ubuntu 22.04/24.04 or Debian 12/13.
# Usage: sudo bash install-cloud-drive.sh USERNAME PASSWORD
set -Eeuo pipefail
umask 077

readonly DRIVE_ROOT='/var/lib/game-save-sync/saves'
readonly DRIVE_STATE='/var/lib/game-save-sync/web'
readonly DRIVE_APP='/opt/game-save-drive'
readonly DRIVE_ENV='/etc/game-save-drive.env'
readonly DRIVE_SERVICE='game-save-drive.service'
readonly APP_URL='https://raw.githubusercontent.com/marceldun/ntm/main/cloud-drive/app.py'
readonly UI_URL='https://raw.githubusercontent.com/marceldun/ntm/main/cloud-drive/index.html'
readonly APP_SHA='53f57cda60eff42b75f07921cd078e406d17d9b7a6e46f6508b000f8bd22fe87'
readonly UI_SHA='1bdda6cb75147b75985f479b0d489e464852427149cb92271f597f9bc7c66ab6'

USERNAME="${1:-admin}"
PASSWORD="${2:-}"
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
[[ $USERNAME =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || fail '用户名只能包含字母、数字、点、下划线和短横线。'
if [[ -z $PASSWORD ]]; then
  read -r -s -p '设置云盘密码（至少 8 位）: ' PASSWORD
  printf '\n'
fi
[[ ${#PASSWORD} -ge 8 ]] || fail '密码至少需要 8 位。'
[[ -d $DRIVE_ROOT ]] || fail "没有找到 $DRIVE_ROOT；请先完成游戏存档同步脚本。"

printf '[1/5] 安装运行依赖……\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends python3 ca-certificates curl openssl

printf '[2/5] 下载并校验云盘程序……\n'
TEMP_DIR=$(mktemp -d /tmp/game-save-drive.XXXXXX)
curl -fL --retry 3 --connect-timeout 15 "$APP_URL" -o "$TEMP_DIR/app.py"
curl -fL --retry 3 --connect-timeout 15 "$UI_URL" -o "$TEMP_DIR/index.html"
printf '%s  %s\n' "$APP_SHA" "$TEMP_DIR/app.py" | sha256sum -c -
printf '%s  %s\n' "$UI_SHA" "$TEMP_DIR/index.html" | sha256sum -c -
python3 -m py_compile "$TEMP_DIR/app.py"
install -d -o root -g root -m 0755 "$DRIVE_APP"
install -o root -g root -m 0644 "$TEMP_DIR/app.py" "$DRIVE_APP/app.py"
install -o root -g root -m 0644 "$TEMP_DIR/index.html" "$DRIVE_APP/index.html"

printf '[3/5] 设置账户、HTTPS 和低权限服务……\n'
getent group gamesync >/dev/null || groupadd --system gamesync
if ! id gamesync >/dev/null 2>&1; then
  useradd --system --gid gamesync --home-dir /var/lib/game-save-sync --shell /usr/sbin/nologin gamesync
fi
install -d -o gamesync -g gamesync -m 0700 "$DRIVE_STATE" "$DRIVE_STATE/temp"
chown -R gamesync:gamesync "$DRIVE_ROOT"

export DRIVE_SETUP_PASSWORD="$PASSWORD"
AUTH_DATA=$(python3 - "$USERNAME" <<'PY'
import base64, hashlib, os, secrets, sys
def b64(value): return base64.urlsafe_b64encode(value).decode().rstrip('=')
salt = secrets.token_bytes(16)
password_hash = hashlib.pbkdf2_hmac('sha256', os.environ['DRIVE_SETUP_PASSWORD'].encode(), salt, 310_000)
print('DRIVE_USERNAME=' + sys.argv[1])
print('DRIVE_PASSWORD_SALT=' + b64(salt))
print('DRIVE_PASSWORD_HASH=' + b64(password_hash))
print('DRIVE_SESSION_SECRET=' + b64(secrets.token_bytes(32)))
PY
)
unset DRIVE_SETUP_PASSWORD
printf '%s\n' "$AUTH_DATA" > "$DRIVE_ENV"
chmod 0600 "$DRIVE_ENV"

PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')
[[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || PUBLIC_IP='127.0.0.1'
if [[ ! -s "$DRIVE_STATE/cert.pem" || ! -s "$DRIVE_STATE/key.pem" ]]; then
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -subj "/CN=$PUBLIC_IP" -addext "subjectAltName=IP:$PUBLIC_IP" \
    -keyout "$DRIVE_STATE/key.pem" -out "$DRIVE_STATE/cert.pem" >/dev/null 2>&1
fi
chown gamesync:gamesync "$DRIVE_STATE/cert.pem" "$DRIVE_STATE/key.pem"
chmod 0600 "$DRIVE_STATE/key.pem"

systemctl stop "$DRIVE_SERVICE" 2>/dev/null || true
PORT=443
if ss -H -ltn 'sport = :443' 2>/dev/null | grep -q .; then PORT=8443; fi
if ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q .; then
  fail "端口 $PORT 已被其他程序占用。"
fi
printf '%s\n' "$PORT" > "$DRIVE_STATE/port"
chown gamesync:gamesync "$DRIVE_STATE/port"

cat > "/etc/systemd/system/$DRIVE_SERVICE" <<EOF
[Unit]
Description=Game Save Drive web interface
After=network-online.target game-save-sync.service
Wants=network-online.target

[Service]
Type=simple
User=gamesync
Group=gamesync
UMask=0077
EnvironmentFile=$DRIVE_ENV
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 $DRIVE_APP/app.py --root $DRIVE_ROOT --static $DRIVE_APP --temp $DRIVE_STATE/temp --host 0.0.0.0 --port $PORT --cert $DRIVE_STATE/cert.pem --key $DRIVE_STATE/key.pem
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=/var/lib/game-save-sync
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

printf '[4/5] 启动服务并开放防火墙端口……\n'
systemctl daemon-reload
systemctl enable --now "$DRIVE_SERVICE"
if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "$PORT/tcp" >/dev/null
fi

for _ in $(seq 1 60); do
  curl -kfsS --max-time 2 "https://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -kfsS --max-time 2 "https://127.0.0.1:$PORT/" >/dev/null || fail '网页服务没有启动。'

printf '[5/5] 验证登录和存档目录……\n'
export DRIVE_VERIFY_PASSWORD="$PASSWORD"
python3 - "$USERNAME" "$PORT" <<'PY'
import http.cookiejar, json, os, ssl, sys, urllib.request
user, port = sys.argv[1], int(sys.argv[2])
context = ssl._create_unverified_context()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), urllib.request.HTTPSHandler(context=context))
req = urllib.request.Request(f'https://127.0.0.1:{port}/api/login', data=json.dumps({'username':user,'password':os.environ['DRIVE_VERIFY_PASSWORD']}).encode(), headers={'Content-Type':'application/json'})
with opener.open(req, timeout=5) as response: assert json.load(response)['ok']
with opener.open(f'https://127.0.0.1:{port}/api/list?path=', timeout=5) as response: assert 'entries' in json.load(response)
PY
unset DRIVE_VERIFY_PASSWORD PASSWORD AUTH_DATA

if [[ $PORT == 443 ]]; then PUBLIC_URL="https://$PUBLIC_IP/"; else PUBLIC_URL="https://$PUBLIC_IP:$PORT/"; fi
printf '\n安装成功。\n云盘地址：%s\n用户名：%s\n存档位置：%s\n' "$PUBLIC_URL" "$USERNAME" "$DRIVE_ROOT"
printf '首次访问时浏览器会提示自签名证书，确认继续访问即可。\n'
