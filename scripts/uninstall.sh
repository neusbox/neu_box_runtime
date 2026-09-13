#!/bin/bash
# 卸载 neu-box-runtime / neu-box-hook，并把 daemon.json 还原回安装前的样子。
#
# ⚠️ 顺序是硬要求，方向和 install.sh 相反：**先还原 daemon.json，再删二进制**。
#    default-runtime 还指着 neu-box 的时候把二进制删掉，dockerd 会起不了任何
#    容器。
#
# ⚠️ 还原用的是安装时的备份 $DAEMON.neu-box-bak。那是一份**快照**：安装之后你手工
#    改过 daemon.json 的话，还原会把那些改动一起抹掉。没有备份（装机时 daemon.json
#    本来不存在）时改成外科手术式地摘掉我们加的两个键。
#
# ⚠️ 和安装时一样，daemon.json 改完要重启 dockerd 才生效；脚本不会替你重启。
#
# 用法：
#   sudo bash scripts/uninstall.sh            # 还原 + 删二进制，保留 runtime.env
#   sudo bash scripts/uninstall.sh --purge    # 连 /etc/neu-box/runtime.env 一起删
set -euo pipefail

BIN_DIR=/usr/local/bin
RUNTIME_BIN="$BIN_DIR/neu-box-runtime"
HOOK_BIN="$BIN_DIR/neu-box-hook"
CONF_DIR=/etc/neu-box
CONF="$CONF_DIR/runtime.env"
DAEMON=/etc/docker/daemon.json
DAEMON_BAK="$DAEMON.neu-box-bak"

purge=0
for arg in "$@"; do
    case "$arg" in
        --purge) purge=1 ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "未知参数：$arg（--help 看用法）" >&2; exit 2 ;;
    esac
done

die() { echo "❌ $*" >&2; exit 1; }
say() { echo "── $*"; }

[ "$(id -u)" = 0 ] || die "需要 root：sudo bash $0"

# ────────────────────────────────────────────────────────────────────────────
say "1/4 还原 $DAEMON（必须在删二进制之前）"
# ────────────────────────────────────────────────────────────────────────────
if [ -f "$DAEMON_BAK" ]; then
    cp -a "$DAEMON_BAK" "$DAEMON"
    echo "已从 $DAEMON_BAK 还原（安装时的快照；装完之后手工改过的内容会被覆盖）"
elif [ -f "$DAEMON" ]; then
    command -v python3 >/dev/null || die "没有备份，又需要 python3 来摘键"
    python3 - "$DAEMON" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as stream:
    raw = stream.read().strip()
config = json.loads(raw) if raw else {}
if not isinstance(config, dict):
    raise SystemExit(f'❌ {path} 顶层不是 JSON 对象，拒绝改')

changed = []
if config.get('default-runtime') == 'neu-box':
    del config['default-runtime']
    changed.append('default-runtime')
else:
    kept = config.get('default-runtime')
    if kept:
        print(f'ℹ️  default-runtime 是 {kept!r}，不是 neu-box，没动它')

runtimes = config.get('runtimes')
if isinstance(runtimes, dict) and 'neu-box' in runtimes:
    del runtimes['neu-box']
    changed.append('runtimes.neu-box')
    if not runtimes:
        del config['runtimes']

with open(path, 'w', encoding='utf-8') as stream:
    json.dump(config, stream, indent=4)
    stream.write('\n')

print('  摘掉的键：' + (', '.join(changed) if changed else '（没有）'))
PY
else
    echo "没有 $DAEMON，跳过"
fi

# ────────────────────────────────────────────────────────────────────────────
say "2/4 删除二进制"
# ────────────────────────────────────────────────────────────────────────────
for binary in "$RUNTIME_BIN" "$HOOK_BIN"; do
    if [ -e "$binary" ]; then
        rm -f "$binary"
        echo "已删除 $binary"
    else
        echo "$binary 本来就不在"
    fi
done

# ────────────────────────────────────────────────────────────────────────────
say "3/4 配置文件"
# ────────────────────────────────────────────────────────────────────────────
if [ "$purge" = 1 ]; then
    rm -f "$CONF"
    echo "已删除 $CONF"
    # 备份文件留着：里面可能有你手工改过的东西，不该由脚本替你决定。
    if compgen -G "$CONF.bak.*" >/dev/null; then
        echo "保留备份：$(ls -1 "$CONF.bak."* | tr '\n' ' ')（要删自己删）"
    fi
    if [ -d "$CONF_DIR" ] && [ -z "$(ls -A "$CONF_DIR")" ]; then
        rmdir "$CONF_DIR"
        echo "已删除空目录 $CONF_DIR"
    fi
else
    echo "保留 $CONF（要一起删：sudo bash $0 --purge）"
fi

# ────────────────────────────────────────────────────────────────────────────
say "4/4 完成 —— 但还没有生效"
# ────────────────────────────────────────────────────────────────────────────
cat <<'EOF'

接下来必须手工做（脚本不替你重启 dockerd）：

  1) 先看看有哪些容器会被重启杀掉：   docker ps
  2) 重启 dockerd：                   systemctl restart docker
  3) 确认 neu-box 已经不在 runtime 列表里：
       docker info --format '{{.DefaultRuntime}} {{.Runtimes}}'

注意：重启 dockerd 会杀掉当时所有运行中的容器。

（重装：sudo bash scripts/install.sh ）
EOF
