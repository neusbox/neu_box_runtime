#!/bin/bash
# 安装 neu-box-runtime 与 neu-box-hook，并把 neu-box 设成 Docker 的默认 runtime。
#
# ⚠️ neu-box 是 **default-runtime**：这台机器上所有容器（包括跟我们完全无关的
#    业务容器）的启动都要经过 /usr/local/bin/neu-box-runtime。所以顺序是硬要求：
#
#        1. 装二进制
#        2. 验证它能执行（跑得起来、找得到真 runtime）
#        3. 最后才改 daemon.json
#
#    default-runtime 指向一个不存在或跑不起来的二进制，dockerd 会**起不了任何
#    容器**。顺序反了就可能落到这个状态。
#
# ⚠️ runtimes / default-runtime **不支持热加载**：改完必须重启 dockerd，重启会杀掉
#    当时所有运行中的容器。这个脚本**不会**替你重启，只把命令打出来。
#
# ⚠️ 改 daemon.json 之前会备份到 $DAEMON.neu-box-bak。uninstall.sh 靠它还原。
#
# 用法：
#   sudo bash scripts/install.sh              # 编译 + 安装
#   sudo bash scripts/install.sh --no-build   # 用 dist/ 里已有的二进制
#   sudo bash scripts/install.sh --force      # 覆盖已存在的 runtime.env（先备份）
set -euo pipefail

BIN_DIR=/usr/local/bin
RUNTIME_BIN="$BIN_DIR/neu-box-runtime"
HOOK_BIN="$BIN_DIR/neu-box-hook"
CONF_DIR=/etc/neu-box
CONF="$CONF_DIR/runtime.env"
WORKER_CONF="$CONF_DIR/worker.env"
DAEMON=/etc/docker/daemon.json
DAEMON_BAK="$DAEMON.neu-box-bak"
DEFAULT_PORT=59075
# 注入的 OCI hook 阶段。默认 createRuntime（契约默认值）：直连 runc 验过，且
# prestart 在 OCI 规范里已废弃。prestart 仍然能用、也仍然重要 —— 整条 Docker
# 链路上验过的只有它，createRuntime 在完整链路上还没跑过，出问题就切回它。
DEFAULT_PHASE=createRuntime

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

build=1
force=0
for arg in "$@"; do
    case "$arg" in
        --no-build) build=0 ;;
        --force) force=1 ;;
        -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "未知参数：$arg（--help 看用法）" >&2; exit 2 ;;
    esac
done

die() { echo "❌ $*" >&2; exit 1; }
say() { echo "── $*"; }

[ "$(id -u)" = 0 ] || die "需要 root：sudo bash $0"

# ────────────────────────────────────────────────────────────────────────────
say "1/6 编译二进制（CGO_ENABLED=0，静态；目标机不需要 glibc 匹配）"
# ────────────────────────────────────────────────────────────────────────────
runtime_src="$ROOT/dist/neu-box-runtime"
hook_src="$ROOT/dist/neu-box-hook"
if [ "$build" = 1 ]; then
    command -v go >/dev/null || die "找不到 go；用 --no-build 走 dist/ 里已有的二进制"
    mkdir -p "$ROOT/dist"
    ( cd "$ROOT" && CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' \
        -o dist/neu-box-runtime ./cmd/neu-runtime )
    ( cd "$ROOT" && CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' \
        -o dist/neu-box-hook ./cmd/neu-hook )
fi
[ -f "$runtime_src" ] || die "没有 $runtime_src（先编译，或去掉 --no-build）"
[ -f "$hook_src" ] || die "没有 $hook_src（先编译，或去掉 --no-build）"

# ────────────────────────────────────────────────────────────────────────────
say "2/6 安装二进制到 $BIN_DIR"
# ────────────────────────────────────────────────────────────────────────────
# 真 runtime 从 PATH 里找，不写死：契约的默认值是 /usr/local/bin/runc，但不同装机
# 方式（RPM、官方脚本）落点不一样。
real_runc="${NEU_BOX_REAL_RUNC:-$(command -v runc || true)}"
[ -n "$real_runc" ] || die "找不到 runc；先装 runc，或显式给 NEU_BOX_REAL_RUNC=/path/to/runc"
echo "真 runtime：$real_runc"

install -m 0755 "$runtime_src" "$RUNTIME_BIN"
install -m 0755 "$hook_src" "$HOOK_BIN"
# SELinux（本机 daemon.json 里 selinux-enabled: true）下新文件要有正确的标签，
# 否则 dockerd 起容器时可能被拒。
if command -v restorecon >/dev/null; then
    restorecon -v "$RUNTIME_BIN" "$HOOK_BIN" 2>/dev/null || true
fi

# ────────────────────────────────────────────────────────────────────────────
say "3/6 验证二进制能执行 —— 在动 daemon.json 之前"
# ────────────────────────────────────────────────────────────────────────────
# --help 会原样转发给真 runtime，等于同时验证了"wrapper 跑得起来"和"它能找到
# 真 runc"这两件事。这里失败就绝不碰 daemon.json。
if ! NEU_BOX_REAL_RUNC="$real_runc" "$RUNTIME_BIN" --help >/dev/null 2>&1; then
    die "错误：$RUNTIME_BIN --help 跑不通（真 runtime 是 $real_runc），daemon.json 保持不变"
fi
echo "✅ wrapper 可执行，且能把 argv 转发给 $real_runc"

# hook 喂一个空 state：应当很快退非零（"state 里没有 sandbox_cgroup"），
# 既证明它能跑，也证明它不会在缺参数时挂死。非零在这里是期望值。
hook_rc=0
printf '{}' | timeout 5 "$HOOK_BIN" >/dev/null 2>&1 || hook_rc=$?
if [ "$hook_rc" = 0 ]; then
    die "错误：$HOOK_BIN 收到空 state 竟然退 0，登记逻辑不对，daemon.json 保持不变"
fi
if [ "$hook_rc" = 124 ]; then
    die "错误：$HOOK_BIN 挂死了（5s 没退），daemon.json 保持不变"
fi
echo "✅ hook 可执行（空 state 退 $hook_rc，符合预期）"

# ────────────────────────────────────────────────────────────────────────────
say "4/6 生成 $CONF"
# ────────────────────────────────────────────────────────────────────────────
mkdir -p "$CONF_DIR"
chmod 0750 "$CONF_DIR"
if [ -f "$CONF" ] && [ "$force" != 1 ]; then
    echo "已存在，原样保留（要重写加 --force）"
else
    if [ -f "$CONF" ]; then
        backup="$CONF.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$CONF" "$backup"
        echo "已备份 → $backup"
    fi
    # 端口从 worker.env 里读，不写死：NEU_BOX_WORKER_URL 的端口和 worker 的
    # NEU_BOX_PORT 是同一件事，写死就会漂（契约里点名的"一份事实两处描述"）。
    worker_port=""
    if [ -f "$WORKER_CONF" ]; then
        worker_port=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?NEU_BOX_PORT[[:space:]]*=[[:space:]]*//p' "$WORKER_CONF" \
            | tail -n 1 | tr -d '"' | tr -d "'" | tr -d '[:space:]')
    fi
    case "$worker_port" in
        ''|*[!0-9]*)
            echo "⚠️  没从 $WORKER_CONF 读到 NEU_BOX_PORT，用默认端口 $DEFAULT_PORT"
            echo "     worker 改了端口的话，$CONF 里的 NEU_BOX_WORKER_URL 要跟着改"
            worker_port="$DEFAULT_PORT"
            ;;
        *) echo "从 $WORKER_CONF 读到端口 $worker_port" ;;
    esac

    cat > "$CONF" <<EOF
# Neu Box Runtime configuration —— 见 deploy/config/runtime.env.example。
# 由 scripts/install.sh 生成（$(date -Is)）。
# 环境变量优先于此文件；NEU_BOX_CONFIG 可以指向另一个文件。

NEU_BOX_WORKER_URL=http://127.0.0.1:$worker_port
NEU_BOX_HOOK=$HOOK_BIN
# 整条 Docker 链路上验过的是 prestart；createRuntime 只直连 runc 验过。
# 真机第一次跑 createRuntime，出问题就把这行改成 prestart。
NEU_BOX_HOOK_PHASE=$DEFAULT_PHASE
NEU_BOX_REAL_RUNC=$real_runc
EOF
    # 和 worker.env 一致：%attr(0640,root,root)。
    chown root:root "$CONF"
    chmod 0640 "$CONF"
    echo "已写入 $CONF"
fi

# ────────────────────────────────────────────────────────────────────────────
say "5/6 把 neu-box 设成默认 runtime（daemon.json）"
# ────────────────────────────────────────────────────────────────────────────
command -v python3 >/dev/null || die "需要一个 python3 来改 JSON"
if [ -f "$DAEMON" ]; then
    if [ -f "$DAEMON_BAK" ]; then
        echo "备份已存在，保留旧的那份：$DAEMON_BAK"
    else
        cp -a "$DAEMON" "$DAEMON_BAK"
        echo "已备份 → $DAEMON_BAK"
    fi
else
    mkdir -p "$(dirname "$DAEMON")"
    printf '{}\n' > "$DAEMON"
    echo "$DAEMON 不存在，已新建（卸载时没有备份可还原，会改成删掉我们的键）"
fi

python3 - "$DAEMON" "$RUNTIME_BIN" <<'PY'
import json
import sys

path, wrapper = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as stream:
    raw = stream.read().strip()
config = json.loads(raw) if raw else {}
if not isinstance(config, dict):
    raise SystemExit(f'❌ {path} 顶层不是 JSON 对象，拒绝改')

previous = config.get('default-runtime')
config['default-runtime'] = 'neu-box'
runtimes = config.setdefault('runtimes', {})
if not isinstance(runtimes, dict):
    raise SystemExit(f'❌ {path} 里的 runtimes 不是 JSON 对象，拒绝改')
stale = runtimes.get('neu-box-hook')
runtimes['neu-box'] = {'path': wrapper}

with open(path, 'w', encoding='utf-8') as stream:
    json.dump(config, stream, indent=4)
    stream.write('\n')

print(f'  default-runtime = neu-box')
print(f'  runtimes.neu-box = {wrapper}')
if previous and previous != 'neu-box':
    print(f'⚠️  原来的 default-runtime 是 {previous!r}，已被覆盖；'
          f'还原用 {path}.neu-box-bak', file=sys.stderr)
if stale:
    print(f'ℹ️  还留着实验期的 runtimes.neu-box-hook = {stale}，'
          f'它只在显式 --runtime neu-box-hook 时用到，可手工删掉', file=sys.stderr)
PY

# ────────────────────────────────────────────────────────────────────────────
say "6/6 完成 —— 但还没有生效"
# ────────────────────────────────────────────────────────────────────────────
cat <<EOF

接下来必须手工做（脚本不替你重启 dockerd）：

  1) 先看看有哪些容器会被重启杀掉：   docker ps
  2) 重启 dockerd：                   systemctl restart docker
  3) 确认 runtime 注册上了：          docker info --format '{{.DefaultRuntime}} {{.Runtimes}}'
  4) 确认 worker 在听：               curl -sS http://127.0.0.1:<port>/sandbox/status

注意：重启 dockerd 会杀掉当时所有运行中的容器。

回滚：sudo bash scripts/uninstall.sh
EOF
