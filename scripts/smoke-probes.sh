# scripts/smoke.sh / e2e/smoke.sh source 本文件，不单独执行。
# shellcheck shell=bash
# Flood：sso=none。flood 没有 OIDC 和代登录请求头支持：
# - 核心注入 WONTON_TORRENT_CLIENT_URL 时走上游自带的 auth=none，无应用登录页，主人身份由云吞网关认证；
# - 没注入时（能力依赖核心尚未合入），保留 flood 自带账号，第一次打开在应用里注册。
export IDENTITY_NA=1
export SMOKE_NOTE="flood 不支持 OIDC 和代登录请求头；有下载器连接时用上游 auth=none（无应用登录），没有时用自带账号，两种都由云吞网关把守。"
export E2E_NOTE="flood 不支持 OIDC 和代登录请求头；有下载器连接时无应用登录，主人身份由云吞网关认证。"

web_assert() { grep -qi '<title>Flood</title>'; }

WEB_URL="${E2E_WEB_URL:-${SMOKE_WEB_URL:-}}"

# flood 会话：auth=none 下 GET /api/auth/verify 无条件发 jwt Cookie；
# 自带账号模式（能力核心未合入的过渡态）下，若还没有用户就注册一个（凭据随机生成、只存进本次冒烟的
# 状态文件），已有用户就用状态文件里的凭据登录。
flood_jar() {
  local jar="${FLOOD_JAR:-${E2E_DIR:-${SMOKE_DIR:-?}}/.wonton/flood-jar}"
  mkdir -p "$(dirname "$jar")"
  cp -f "${E2E_JAR:-${SMOKE_JAR:-}}" "$jar"
  printf '%s' "$jar"
}

flood_session() (
  set -eu
  local jar out verify code creds user pass
  jar="$(flood_jar)"
  creds="$(dirname "$jar")/flood-creds"
  out="$(curl -sS --noproxy '*' -b "$jar" -c "$jar" --max-time 20 -w '\n%{http_code}' "$WEB_URL/api/auth/verify")"
  code="${out##*$'\n'}"
  verify="${out%$'\n'*}"
  if [ "$code" = 200 ]; then
    printf '%s' "$jar"; return 0
  fi
  if [ "$code" != 401 ]; then
    echo "flood 会话建立失败：HTTP $code $(head -c 120 <<<"$verify")"; return 1
  fi
  # auth=none 下 verify 返回 200，到不了这里；走到这里说明是自带账号模式。
  if grep -q '"initialUser":true' <<<"$verify"; then
    user="wonton-smoke-$RANDOM"
    pass="$(head -c 24 /dev/urandom | base64 | tr -d '/+=')"
    printf '%s %s\n' "$user" "$pass" >"$creds"
    curl -fsS --noproxy '*' -b "$jar" -c "$jar" --max-time 20 \
      -H 'Content-Type: application/json' \
      -d "{\"username\":\"$user\",\"password\":\"$pass\",\"client\":{\"client\":\"qBittorrent\",\"type\":\"web\",\"version\":1,\"url\":\"http://127.0.0.1:1\",\"username\":\"\",\"password\":\"\"},\"level\":10}" \
      "$WEB_URL/api/auth/register" >/dev/null
    printf '%s' "$jar"; return 0
  fi
  [ -f "$creds" ] || { echo "flood 自带账号模式下没有可用的测试用户凭据（$creds 不存在）"; return 1; }
  user="$(awk '{print $1}' "$creds")"
  pass="$(awk '{print $2}' "$creds")"
  curl -fsS --noproxy '*' -b "$jar" -c "$jar" --max-time 20 \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$user\",\"password\":\"$pass\"}" \
    "$WEB_URL/api/auth/authenticate" >/dev/null || {
    echo "flood 测试用户登录失败：$user"; return 1; }
  printf '%s' "$jar"
)

# data_write：写一条 RSS 订阅（flood 的按用户持久数据，升级重装都在数据库里）。
# URL 用 192.0.2.x 文档地址，间隔 24h：冒烟期间不会被真正抓取。
data_write() (
  set -eu
  local jar feeds url
  jar="$(flood_session)"
  url="http://192.0.2.10/wonton-smoke-$(date +%s).xml"
  feeds="$(curl -sS --noproxy '*' -b "$jar" --max-time 20 \
    -X PUT -H 'Content-Type: application/json' \
    -d "{\"label\":\"wonton-smoke\",\"url\":\"$url\",\"interval\":86400}" \
    "$WEB_URL/api/feed-monitor/feeds")" || {
    echo "写入 RSS 订阅失败：$(head -c 200 <<<"$feeds")"; return 1; }
  echo "已写 RSS 订阅 wonton-smoke：$url"
)

# data_check：升级/重装后订阅还在，label 和 URL 前缀对得上。
data_check() (
  set -eu
  local jar feeds
  jar="$(flood_session)"
  feeds="$(curl -sS --noproxy '*' -b "$jar" --max-time 20 \
    "$WEB_URL/api/feed-monitor/feeds")"
  jq -e 'any(.[]; .label == "wonton-smoke" and (.url | startswith("http://192.0.2.10/wonton-smoke-")))' \
    <<<"$feeds" >/dev/null || { echo "升级/重装后找不到 wonton-smoke 订阅：$(head -c 200 <<<"$feeds")"; return 1; }
  echo "wonton-smoke 订阅还在：升级/重装保住了数据"
)
