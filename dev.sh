#!/bin/sh
# dev.sh — 本机开发一键启停脚本
#
# 这是开源版自带的本机开发脚本，不是生产部署工具。
# 生产部署见 docs/deploy.md；Docker 方式是推荐的部署路径。
#
# 支持的环境：
#   - macOS：PostgreSQL 通过 Homebrew 安装（任意版本，不绑定 14）
#   - Linux：PostgreSQL 通过系统包管理器安装（apt / yum / dnf，PostgreSQL 官方源或发行版仓库）
#   - Node.js >= 24.11（项目 package.json engines 的要求）
#   - 脚本在启动时自动检测 macOS / Linux，使用对应系统的路径和命令
#
# 用法：
#   ./dev.sh start    — 启动本机 PostgreSQL 开发实例、运行迁移和种子，再启动三个服务
#   ./dev.sh stop     — 停止三个服务和专属 PostgreSQL 实例（外部实例、远程库不动）
#   ./dev.sh restart  — stop + start
#   ./dev.sh logs     — 追踪日志
#   ./dev.sh status   — 显示当前运行状态
#   ./dev.sh check    — 仅检查环境，不启动任何东西
#
# 关于 PostgreSQL 所有权（三段式）：
#   1. DATABASE_URL 指向远程主机   → 直接使用，不操作 PostgreSQL 生命周期
#   2. 本机端口已有其他 PostgreSQL → 直接使用，不操作（不是本脚本启动的）
#   3. 本机端口无响应              → 启动项目专属实例（数据目录 .data/dev/pgdata）
#   专属实例的认定依据是 .data/dev/pgdata 这个目录本身：只要它存在且
#   postmaster 在跑，stop 就按进程组把它停掉，与本次会话之前是否已经
#   启动无关。外部实例（brew、apt 安装的系统 PostgreSQL 等）和远程
#   数据库一律不动。
#
# 进程退出：
#   三个服务（api / worker / web）各自用 setsid（等效 detached）起，
#   PID 写入 .data/dev/*.pid；stop 时按进程组先发 SIGTERM，等超时（worker
#   210 秒，其余 10 秒）还没退出再发 SIGKILL，npm 带起的 node --watch 子
#   进程一起收掉，不留孤儿。

set -eu

# 脚本所在目录作为工作目录
cd -P "$(dirname "$0")"

DIR=.data/dev
mkdir -p "$DIR"

PGDATA="$PWD/$DIR/pgdata"
PGLOG="$PWD/$DIR/postgres.log"

# ────────────────────────────────────────────────────────────────
# 0. 系统检测（macOS / Linux）
# ────────────────────────────────────────────────────────────────
case "$(uname -s)" in
  Darwin) OS_TYPE=macos ;;
  Linux)  OS_TYPE=linux ;;
  *) echo "error: unsupported OS ($(uname -s)). See docs/deploy.md for Docker deployment."; exit 1 ;;
esac

# ────────────────────────────────────────────────────────────────
# 1. 从 .env 解析连接配置（与 migrate.ts / seed.ts 用同一来源）
# ────────────────────────────────────────────────────────────────
# 用 shell 直接读取，不引入 node。优先级与 node --env-file-if-exists=.env 一致：
# 进程环境里已有的 DATABASE_URL 优先，其次是 .env 文件，最后是默认值。
RAW_URL="${DATABASE_URL:-}"
if [ -z "$RAW_URL" ] && [ -f .env ]; then
  # 与 dotenv 一样，重复的键以最后一条为准；去掉首尾引号和空白
  RAW_URL=$(grep -E '^[[:space:]]*DATABASE_URL[[:space:]]*=' .env | tail -1 \
    | sed "s/^[^=]*=//; s/^[\"']//; s/[\"']\$//" | tr -d '[:space:]')
fi
[ -z "$RAW_URL" ] && RAW_URL="postgres://127.0.0.1:5432/aihot"

# 解析 URL：postgres://[user[:pass]@]host[:port]/dbname[?...]
parse_db_url() {
  local url="$1"
  local rest hostpart hostport dbpart userinfo
  rest=$(printf '%s' "$url" | sed 's|^postgres[ql]*://||')
  if printf '%s' "$rest" | grep -q '@'; then
    hostpart=$(printf '%s' "$rest" | sed 's|^[^@]*@||')
  else
    hostpart="$rest"
  fi
  hostport=$(printf '%s' "$hostpart" | cut -d'/' -f1)
  dbpart=$(printf '%s' "$hostpart" | cut -d'/' -f2 | cut -d'?' -f1)

  # user[:password]（取最后一个 @ 之前的整段，密码里的裸 @ 不会截断）
  userinfo=$(printf '%s' "$rest" | sed -n 's|^\(.*\)@[^@]*$|\1|p')
  if [ -n "$userinfo" ]; then
    DB_USER="${userinfo%%:*}"
    case "$userinfo" in
      *:*) DB_PASS="${userinfo#*:}" ;;
      *)   DB_PASS="" ;;
    esac
  fi

  # 解析 IPv6 [::1]:5432
  if printf '%s' "$hostport" | grep -q '^\['; then
    DB_HOST=$(printf '%s' "$hostport" | sed 's/^\[\([^]]*\)\].*/\1/')
    DB_PORT=$(printf '%s' "$hostport" | sed 's/^\[[^]]*\]:\([0-9]*\).*/\1/')
  else
    DB_HOST=$(printf '%s' "$hostport" | cut -d':' -f1)
    DB_PORT=$(printf '%s' "$hostport" | cut -d':' -sf2)
  fi
  [ -z "$DB_PORT" ] && DB_PORT=5432
  [ -z "$DB_HOST" ] && DB_HOST="127.0.0.1"
  DB_NAME="${dbpart:-aihot}"
}

DB_HOST="" DB_PORT="" DB_NAME="" DB_USER="" DB_PASS=""
parse_db_url "$RAW_URL"

# ────────────────────────────────────────────────────────────────
# 2. 判断 DB_HOST 是否本机
# ────────────────────────────────────────────────────────────────
is_local_host() {
  case "$1" in
    127.0.0.1|localhost|::1|"[::1]"|"") return 0 ;;
    *) return 1 ;;
  esac
}

# ────────────────────────────────────────────────────────────────
# 3. Node.js 版本校验（>=24.11，精确到 minor）
# ────────────────────────────────────────────────────────────────
NODE_MIN_MAJOR=24
NODE_MIN_MINOR=11

node_version_ok() {
  command -v node > /dev/null 2>&1 || return 1
  local ver major minor
  ver=$(node --version 2>/dev/null | sed 's/^v//')
  major=$(printf '%s' "$ver" | cut -d. -f1)
  minor=$(printf '%s' "$ver" | cut -d. -f2)
  [ "$major" -gt "$NODE_MIN_MAJOR" ] && return 0
  [ "$major" -eq "$NODE_MIN_MAJOR" ] && [ "$minor" -ge "$NODE_MIN_MINOR" ] && return 0
  return 1
}

check_node() {
  # 先检查是否满足，不满足时尝试 nvm
  if ! node_version_ok; then
    local NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
      # shellcheck disable=SC1090
      . "$NVM_DIR/nvm.sh" --no-use > /dev/null 2>&1
      nvm use --lts > /dev/null 2>&1 || nvm use "$NODE_MIN_MAJOR" > /dev/null 2>&1 || true
    fi
  fi
  if ! node_version_ok; then
    local ver; ver=$(node --version 2>/dev/null || echo "未安装")
    echo "error: Node.js $ver does not meet requirement (need >= ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR})"
    echo "  suggest: nvm install ${NODE_MIN_MAJOR} or visit https://nodejs.org"
    exit 1
  fi
  echo "Node.js $(node --version) ✓"
}

# ────────────────────────────────────────────────────────────────
# 4. PostgreSQL：按 .data/dev/pgdata 判定所有权
#    专属实例（本仓库内这个数据目录）由脚本管理：start 时按需启动，
#    stop 时停掉。外部实例（本机别的 PostgreSQL）和远程数据库不碰。
# ────────────────────────────────────────────────────────────────

# 按系统类型查找 pg_ctl，返回完整路径
find_pg_ctl() {
  # 先找 PATH 上的（两个系统都适用）
  if command -v pg_ctl > /dev/null 2>&1; then
    command -v pg_ctl; return 0
  fi

  local f candidate all_candidates=""

  if [ "$OS_TYPE" = "macos" ]; then
    # macOS：Homebrew 安装路径（Apple Silicon + Intel，任意版本）
    for f in \
        /opt/homebrew/opt/postgresql@*/bin/pg_ctl \
        /usr/local/opt/postgresql@*/bin/pg_ctl \
        /opt/homebrew/bin/pg_ctl \
        /usr/local/bin/pg_ctl; do
      # shellcheck disable=SC2086
      for candidate in $f; do
        [ -x "$candidate" ] && all_candidates="$all_candidates $candidate"
      done
    done
    # 多版本时优先取 @版本号 最高的；sort -V 不可用的系统（BusyBox 等）退回第一个
    if [ -n "$all_candidates" ]; then
      local best
      best=$(printf '%s\n' $all_candidates | sort -t@ -k2 -rV 2>/dev/null | head -1)
      [ -n "$best" ] || best=$(printf '%s\n' $all_candidates | head -1)
      printf '%s\n' "$best"
      return 0
    fi

  else
    # Linux：PostgreSQL 官方 APT/YUM 源以及发行版仓库的常见路径
    for f in \
        /usr/lib/postgresql/*/bin/pg_ctl \
        /usr/pgsql-*/bin/pg_ctl \
        /usr/bin/pg_ctl \
        /usr/local/bin/pg_ctl; do
      # shellcheck disable=SC2086
      for candidate in $f; do
        [ -x "$candidate" ] && all_candidates="$all_candidates $candidate"
      done
    done
    # 多版本时优先取路径里版本号最高的（Debian 的 /usr/lib/postgresql/<ver>/bin）；
    # sort -V 不可用的系统退回第一个
    if [ -n "$all_candidates" ]; then
      local best
      best=$(printf '%s\n' $all_candidates | sort -t/ -k5 -rV 2>/dev/null | head -1)
      [ -n "$best" ] || best=$(printf '%s\n' $all_candidates | head -1)
      printf '%s\n' "$best"
      return 0
    fi
  fi

  return 1
}

pg_bin() {
  local tool="$1"
  local ctl
  ctl=$(find_pg_ctl 2>/dev/null) || return 1
  echo "$(dirname "$ctl")/$tool"
}

# 仅当需要启动专属实例时才调用（远程/外部 DB 不需要本地 pg_ctl）
require_pg_tools() {
  if ! find_pg_ctl > /dev/null 2>&1; then
    echo "错误：未找到 pg_ctl，无法启动专属开发 PostgreSQL 实例。"
    if [ "$OS_TYPE" = "macos" ]; then
      echo "  macOS 请先安装 PostgreSQL：brew install postgresql"
    else
      echo "  Debian/Ubuntu：sudo apt install postgresql"
      echo "  RHEL/CentOS/Fedora：sudo dnf install postgresql-server"
      echo "  或使用 PostgreSQL 官方源：https://www.postgresql.org/download/linux/"
    fi
    echo "  如果你已有可用的 PostgreSQL，在 .env 中设置 DATABASE_URL 指向它即可，无需本地 pg_ctl。"
    exit 1
  fi
}

# 检查专属实例是否正在运行（pg_ctl status）
own_pg_running() {
  local ctl; ctl=$(find_pg_ctl 2>/dev/null) || return 1
  "$ctl" status -D "$PGDATA" > /dev/null 2>&1
}

# 读 postmaster.pid 第 4 行：实例实际监听的端口；只在运行时存在
own_pg_port() {
  [ -f "$PGDATA/postmaster.pid" ] || return 1
  sed -n '4p' "$PGDATA/postmaster.pid"
}

# TCP 端口是否有响应（不依赖 HTTP 状态码）。nc 在 macOS 和主流 Linux 均自带；
# 个别发行版（如 Fedora 的 ncat）没有 -z，退回 curl。
tcp_ready() {
  local host="$1" port="$2"
  if command -v nc > /dev/null 2>&1; then
    nc -z -w2 "$host" "$port" > /dev/null 2>&1 && return 0
    return 1
  fi
  curl -s "http://$host:$port" -o /dev/null --max-time 2 > /dev/null 2>&1
}

# 检查 DB_HOST:DB_PORT 上有没有 PostgreSQL 响应：
# 优先用同目录的 pg_isready（能确认是 PostgreSQL 而不只是端口开着），
# 没有它时才退回纯 TCP 探活。
pg_port_ready() {
  local pg_isready
  pg_isready=$(pg_bin pg_isready 2>/dev/null)
  if [ -n "$pg_isready" ] && [ -x "$pg_isready" ]; then
    "$pg_isready" -h "$DB_HOST" -p "$DB_PORT" > /dev/null 2>&1
    return
  fi
  tcp_ready "$DB_HOST" "$DB_PORT"
}

db_init() {
  local initdb; initdb=$(pg_bin initdb 2>/dev/null) || { echo "错误：未找到 initdb"; exit 1; }
  [ -x "$initdb" ] || { echo "错误：initdb 不可执行：$initdb"; exit 1; }
  echo "初始化开发 PostgreSQL 实例: $PGDATA"
  # --locale=C 在 macOS 和 Linux 上均可用；--no-locale 是 --locale=C 的别名，某些旧版 Linux 包不识别
  "$initdb" -D "$PGDATA" --locale=C -E UTF8 > "$PGLOG" 2>&1 || {
    echo "initdb 失败，日志：$PGLOG"
    tail -20 "$PGLOG" >&2
    exit 1
  }
  # listen_addresses / port / unix_socket_directories 由 sync_pg_conf 统一写入
  sync_pg_conf
}

# 把专属实例的监听设置同步成当前 .env 的配置。
# pgdata 是脚本自己建的目录，重写它的配置项是安全的（不会去改别人家的 postgresql.conf）。
sync_pg_conf() {
  local conf="$PGDATA/postgresql.conf"
  rm -f "$conf.tmp"
  { grep -v -E '^[[:space:]]*(port|listen_addresses|unix_socket_directories)[[:space:]]*=' "$conf" || true; } > "$conf.tmp"
  # listen_addresses='localhost' 同时绑定 127.0.0.1 和 ::1，DATABASE_URL 写成 localhost 也通
  # unix_socket_directories='/tmp' 避免 Debian 等系统的 /var/run/postgresql 写权限问题
  printf '\nlisten_addresses = %s\nport = %s\nunix_socket_directories = %s\nlogging_collector = off\n' \
    "'localhost'" "$DB_PORT" "'/tmp'" >> "$conf.tmp"
  mv "$conf.tmp" "$conf"
}

db_start() {
  # ① 远程 DB：DATABASE_URL 指向非本机主机，直接透传，不操作 PostgreSQL
  if ! is_local_host "$DB_HOST"; then
    echo "DATABASE_URL -> remote host $DB_HOST, using directly, not managing local PostgreSQL."
    return 0
  fi

  # ② 本机端口已有响应但不是本脚本的专属实例（外部 PostgreSQL）
  if pg_port_ready && ! own_pg_running; then
    echo "$DB_HOST:$DB_PORT 已有 PostgreSQL 在响应（外部实例），直接使用，不操作它。"
    return 0
  fi

  # ③ 专属实例在跑：核对监听端口与 .env 是否一致
  if own_pg_running; then
    local own_port
    own_port=$(own_pg_port 2>/dev/null) || own_port=""
    if [ -n "$own_port" ] && [ "$own_port" != "$DB_PORT" ]; then
      echo "专属实例监听端口 ${own_port:-?} 与 .env 的 $DB_PORT 不一致，重启专属实例到新端口…"
      local ctl; ctl=$(find_pg_ctl 2>/dev/null) || { echo "错误：未找到 pg_ctl，无法重启专属实例"; exit 1; }
      "$ctl" stop -D "$PGDATA" -m fast -s -w -t 30 || {
        echo "停止旧实例失败，请检查 $PGLOG"; exit 1; }
      # 旧实例停掉后，端口上可能正好有别人家的 PostgreSQL 起来 → 退化为 ②
      if pg_port_ready; then
        echo "$DB_HOST:$DB_PORT 已有 PostgreSQL 在响应（外部实例），直接使用，不操作它。"
        return 0
      fi
    else
      echo "开发 PostgreSQL 专属实例已在运行（${DB_HOST}:${DB_PORT}）"
      return 0
    fi
  fi

  # ④ 启动专属实例：此时才要求本地有 pg_ctl/initdb
  require_pg_tools
  if [ ! -f "$PGDATA/PG_VERSION" ]; then
    db_init
  else
    # pgdata 已存在（之前 init 过的）：把端口同步成 .env 当前值
    sync_pg_conf
  fi
  local ctl; ctl=$(find_pg_ctl)
  echo "启动开发 PostgreSQL 专属实例: $DB_HOST:$DB_PORT"
  "$ctl" start -D "$PGDATA" -l "$PGLOG" -s -w -t 30 || {
    echo "PostgreSQL 启动失败，日志：$PGLOG"
    tail -20 "$PGLOG" >&2
    exit 1
  }
  PG_STARTED_THIS_RUN=1
  echo "开发 PostgreSQL 专属实例已启动"
}

db_stop() {
  # 所有权只看 .data/dev/pgdata：它在本仓库内，归本次开发环境管。
  # 远程 DB（不在本机）和外部实例（不是这个 pgdata）一律不动。
  if ! is_local_host "$DB_HOST"; then
    echo "DATABASE_URL 指向远程主机，没有启动本地 PostgreSQL，无需停止。"
    return 0
  fi
  if ! own_pg_running; then
    echo "专属 PostgreSQL 实例未在运行（外部实例一律不操作），无需停止。"
    return 0
  fi
  local ctl
  ctl=$(find_pg_ctl 2>/dev/null) || {
    echo "警告：未找到 pg_ctl，无法停止专属实例，数据目录仍为 $PGDATA"
    return 1
  }
  echo "停止开发 PostgreSQL 专属实例…"
  "$ctl" stop -D "$PGDATA" -m fast -s -w -t 30 || {
    echo "PostgreSQL 停止失败，请检查 $PGLOG"
    return 1
  }
  echo "开发 PostgreSQL 专属实例已停止"
}

# ────────────────────────────────────────────────────────────────
# 5. 数据库建库 + 可重复执行的迁移 + 种子
# ────────────────────────────────────────────────────────────────
# 用与 .env 的 DATABASE_URL 相同的连接参数跑 psql/createdb：
# 同一份配置（host/port/user/password）既用于建库检查，也用于迁移和种子。
pg_client() {
  local bin="$1"; shift
  if [ -n "$DB_USER" ] && [ -n "$DB_PASS" ]; then
    PGPASSWORD="$DB_PASS" "$bin" -U "$DB_USER" "$@"
  elif [ -n "$DB_USER" ]; then
    "$bin" -U "$DB_USER" "$@"
  elif [ -n "$DB_PASS" ]; then
    PGPASSWORD="$DB_PASS" "$bin" "$@"
  else
    "$bin" "$@"
  fi
}

db_ensure() {
  # 优先用 PATH 上的 psql / createdb（覆盖远程 DB 无本地 pg_ctl 的场景）
  local psql createdb esc_name
  if command -v psql > /dev/null 2>&1; then
    psql=$(command -v psql)
  else
    psql=$(pg_bin psql 2>/dev/null) || { echo "错误：未找到 psql，请确认 PostgreSQL 客户端工具已安装"; exit 1; }
  fi
  if command -v createdb > /dev/null 2>&1; then
    createdb=$(command -v createdb)
  else
    createdb=$(pg_bin createdb 2>/dev/null) || { echo "错误：未找到 createdb，请确认 PostgreSQL 客户端工具已安装"; exit 1; }
  fi
  # 先确认连得上（远程地址、密码不对、端口写错都会在这里给出明确报错，
  # 而不是被后面的建库检查误报成 createdb 失败）
  if ! pg_client "$psql" -h "$DB_HOST" -p "$DB_PORT" -d postgres -tAc "SELECT 1" > /dev/null 2>&1; then
    echo "错误：连不上 ${DB_HOST}:${DB_PORT}（数据库未启动、地址端口不对或凭据不正确）。"
    echo "  本机开发可把 DATABASE_URL 指向本机 PostgreSQL，或直接删掉这一项用脚本自带的专属实例。"
    exit 1
  fi
  # 库名来自使用者自己的 .env，转义单引号后内联进 SQL 字面量
  esc_name=$(printf '%s' "$DB_NAME" | sed "s/'/''/g")
  if ! pg_client "$psql" -h "$DB_HOST" -p "$DB_PORT" -d postgres \
       -tAc "SELECT 1 FROM pg_database WHERE datname='$esc_name'" 2>/dev/null | grep -q 1; then
    echo "数据库 '$DB_NAME' 不存在，正在创建…"
    pg_client "$createdb" -h "$DB_HOST" -p "$DB_PORT" "$DB_NAME" || { echo "createdb 失败"; exit 1; }
    echo "数据库 '$DB_NAME' 已创建"
  fi
  # 迁移（始终执行，migrate.ts 内部跳过已应用的，幂等）
  echo "运行迁移…"
  node --env-file-if-exists=.env scripts/migrate.ts || { echo "迁移失败，请检查错误后重试。"; exit 1; }
  # 种子（始终执行，seed.ts 内部做幂等判断）
  echo "运行种子数据…"
  node --env-file-if-exists=.env scripts/seed.ts || { echo "种子数据写入失败，请检查错误后重试。"; exit 1; }
}

# ────────────────────────────────────────────────────────────────
# 6. 服务启动（detached 进程组，PID 记录，启动健康检查）
# ────────────────────────────────────────────────────────────────
pid_alive() {
  local pid; pid=$(cat "$1" 2>/dev/null) || return 1
  kill -0 "$pid" 2>/dev/null
}

# 等待服务就绪：进程还活着 + 端口有响应，两项都满足才算成功。
# 期间进程退出（启动失败）立即返回 1；端口响应后再确认一次进程存活，
# 避免把别人占用该端口的监听当成自己的服务。超时 30 秒。
wait_for_port() {
  local port="$1" pidfile="$2" i=0 timeout=30
  while [ "$i" -lt "$timeout" ]; do
    pid_alive "$pidfile" || return 1
    if tcp_ready 127.0.0.1 "$port"; then
      sleep 1
      pid_alive "$pidfile" && return 0
      return 1
    fi
    sleep 1; i=$((i + 1))
  done
  return 1
}

# 停止一个服务：先按进程组发 SIGTERM，等 grace 秒；仍不退出发 SIGKILL。
# npm 带起的 node --watch 与它下面的子进程都在同一个进程组里，一起收掉。
# worker 的 grace 要够长：它要等进行中的付费调用收尾（实测空闲收尾也要十几秒，
# docs/deploy.md 要求至少 210 秒），提前杀掉会让调用结果不明。
stop_service() {
  local s="$1" grace="${2:-10}"
  local pidfile="$PWD/$DIR/$s.pid"
  local pid; pid=$(cat "$pidfile" 2>/dev/null) || { echo "$s 未在运行"; return 0; }
  if kill -15 "-$pid" 2>/dev/null; then
    local i=0
    [ "$grace" -gt 20 ] && echo "等待 $s 收尾（最多 ${grace} 秒）…"
    while [ "$i" -lt "$grace" ] && kill -0 "-$pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
    if kill -0 "-$pid" 2>/dev/null; then
      kill -9 "-$pid" 2>/dev/null || true
      echo "$s 超过 ${grace} 秒仍未退出，已强制结束（pgid=${pid}）"
    else
      echo "$s stopped (pgid=$pid)"
    fi
  elif kill -9 "$pid" 2>/dev/null; then
    echo "$s stopped (pid=$pid)"
  else
    echo "$s 进程已不存在"
  fi
  rm -f "$pidfile"
}

start_service() {
  local s="$1" port="$2"
  local pidfile="$PWD/$DIR/$s.pid" logfile="$PWD/$DIR/$s.log"
  if [ -f "$pidfile" ] && pid_alive "$pidfile"; then
    echo "$s 已在运行（pid $(cat "$pidfile")），跳过。"
    return 0
  fi
  rm -f "$pidfile"
  # 端口已被别人占用时先报错，别把占用者的监听当成自己的服务就绪
  if [ -n "$port" ] && tcp_ready 127.0.0.1 "$port"; then
    echo "错误：端口 $port 已被占用（不是本次启动的服务）。请先停止占用它的进程再重试。"
    return 1
  fi
  # detached 启动，自成进程组（等效 setsid）
  node -e '
    const [svc, log, pid] = process.argv.slice(1);
    const { spawn } = require("node:child_process");
    const { openSync, writeFileSync } = require("node:fs");
    const out = openSync(log, "w");
    const ch = spawn("npm", ["run", "dev:" + svc], {
      detached: true, stdio: ["ignore", out, out], cwd: process.cwd()
    });
    writeFileSync(pid, String(ch.pid));
    ch.unref(); process.exit(0);
  ' "$s" "$logfile" "$pidfile"
  # 短暂等待确认进程存活（防止启动失败却写入了 PID）
  sleep 0.5
  if ! pid_alive "$pidfile"; then
    echo "错误：$s 启动失败（进程已退出）。日志：$DIR/$s.log"
    tail -5 "$logfile" 2>/dev/null >&2
    rm -f "$pidfile"; return 1
  fi
  local pid; pid=$(cat "$pidfile")
  if [ -n "$port" ]; then
    echo "$s started (pid $pid), waiting for port $port ..."
    if ! wait_for_port "$port" "$pidfile"; then
      echo "错误：$s 未能在 30 秒内在端口 $port 就绪，清理本次启动的进程。日志：$DIR/$s.log"
      tail -5 "$logfile" 2>/dev/null >&2
      stop_service "$s"
      return 1
    fi
    echo "$s 就绪 → http://127.0.0.1:$port  日志：$DIR/$s.log"
  else
    # 没有端口的服务（worker）：多等几秒确认没有立刻退出
    sleep 2
    if ! pid_alive "$pidfile"; then
      echo "错误：$s 启动后很快退出。日志：$DIR/$s.log"
      tail -5 "$logfile" 2>/dev/null >&2
      rm -f "$pidfile"; return 1
    fi
    echo "$s started (pid $pid)  log: $DIR/$s.log"
  fi
}

# ────────────────────────────────────────────────────────────────
# 命令入口
# ────────────────────────────────────────────────────────────────
# 本次 start 是否自己拉起了专属 PostgreSQL 实例（失败清理时据此决定要不要停库）
PG_STARTED_THIS_RUN=0

do_check() {
  echo "=== 环境检查 ==="
  check_node
  echo "DATABASE_URL 解析结果："
  echo "  主机: $DB_HOST  端口: $DB_PORT  数据库: $DB_NAME"
  if ! is_local_host "$DB_HOST"; then
    echo "  类型: 远程数据库（不管理生命周期）"
  elif pg_port_ready; then
    echo "  PostgreSQL 响应: ✓ (端口 $DB_PORT 可达)"
    if own_pg_running; then
      echo "  类型: 本脚本的专属开发实例（运行中）"
    else
      echo "  类型: 外部本机实例（运行中，不管理生命周期）"
    fi
  else
    echo "  PostgreSQL 响应: ✗ (端口 $DB_PORT 无响应)"
    if [ -f "$PGDATA/PG_VERSION" ]; then
      echo "  类型: 专属开发实例（pgdata 已存在，但实例未运行）"
    else
      echo "  类型: 专属开发实例（pgdata 未初始化，start 时自动创建）"
    fi
    if ! find_pg_ctl > /dev/null 2>&1; then
      echo "  警告: 未找到 pg_ctl，start 时将无法启动专属实例"
      echo "        如已有可用 PostgreSQL，在 .env 设置 DATABASE_URL 指向它即可"
    fi
  fi
  for s in api worker web; do
    local pidfile="$DIR/$s.pid"
    if [ -f "$pidfile" ] && pid_alive "$pidfile"; then
      echo "  $s: 运行中（pid $(cat "$pidfile")）"
    else
      echo "  $s: 未运行"
    fi
  done
  echo "=== 检查完成 ==="
}

do_start() {
  check_node
  PG_STARTED_THIS_RUN=0
  db_start          # 按 pgdata 判定所有权；远程/外部实例不动
  db_ensure         # 建库 + 迁移 + 种子（始终执行，幂等）
  local FAILED=0
  start_service api 3001  || FAILED=1
  start_service worker "" || FAILED=1
  start_service web 3000  || FAILED=1
  if [ "$FAILED" = "1" ]; then
    echo ""
    echo "部分服务启动失败，正在停止本次启动的服务…"
    stop_service api 10
    stop_service worker 210
    stop_service web 10
    # 只停本次 start 自己拉起来的专属实例；之前就在跑的不动
    if [ "$PG_STARTED_THIS_RUN" = "1" ]; then db_stop || true; fi
    echo "已清理。请查看上方错误和日志后重试。"
    exit 1
  fi
  echo ""
  echo "开发环境已就绪："
  echo "  网站 → http://127.0.0.1:3000"
  echo "  API  → http://127.0.0.1:3001"
  echo "  日志 → $DIR/api.log  $DIR/worker.log  $DIR/web.log"
  echo "  停止 → ./dev.sh stop"
}

do_stop() {
  local failed=0
  stop_service api 10 || failed=1
  stop_service worker 210 || failed=1   # worker 要等进行中的付费调用收尾
  stop_service web 10 || failed=1
  db_stop || failed=1
  return "$failed"
}

do_status() {
  echo "=== 开发环境状态 ==="
  for s in api worker web; do
    local pidfile="$DIR/$s.pid"
    if [ -f "$pidfile" ] && pid_alive "$pidfile"; then
      echo "  $s: 运行中（pid $(cat "$pidfile")）  日志：$DIR/$s.log"
    else
      echo "  $s: 未运行"
    fi
  done
  if ! is_local_host "$DB_HOST"; then
    echo "  PostgreSQL: remote ($DB_HOST:$DB_PORT), not managing lifecycle"
  elif own_pg_running; then
    echo "  PostgreSQL: dedicated dev instance running (data dir: $PGDATA)"
  elif pg_port_ready; then
    echo "  PostgreSQL: 端口 $DB_PORT 有响应（外部本机实例，不管理生命周期）"
  else
    echo "  PostgreSQL: 未运行"
  fi
}

case "${1:-}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop || true; do_start ;;
  logs)
    # 只启动过部分服务时也能用：缺的日志文件先建空的，tail 不报错
    for f in api worker web; do : >> "$DIR/$f.log"; done
    tail -n 100 -f "$DIR/api.log" "$DIR/worker.log" "$DIR/web.log"
    ;;
  status)  do_status ;;
  check)   do_check ;;
  *)
    echo "用法: ./dev.sh <命令>"
    echo ""
    echo "命令："
    echo "  start    启动开发环境（迁移 + 种子 + 三个服务；PostgreSQL 按三段式决定是否启动）"
    echo "  stop     停止三个服务和专属 PostgreSQL 实例；外部实例和远程数据库一律不动"
    echo "  restart  stop + start"
    echo "  logs     追踪三个服务的日志"
    echo "  status   显示当前运行状态"
    echo "  check    仅检查环境，不启动任何东西"
    echo ""
    echo "PostgreSQL 策略："
    echo "  DATABASE_URL 指向远程主机  → 直接使用，不操作本地 PostgreSQL"
    echo "  本机端口已有其他 PostgreSQL → 直接使用，不操作它"
    echo "  本机端口无响应             → 启动项目专属实例（需要系统已安装 PostgreSQL）"
    echo "  专属实例由 .data/dev/pgdata 判定归属：stop 会停掉它，与是否本次启动无关"
    echo ""
    echo "支持环境：macOS（Homebrew PostgreSQL）和 Linux（apt / yum / dnf 安装的 PostgreSQL）。"
    echo "生产部署请参阅 docs/deploy.md。"
    ;;
esac
