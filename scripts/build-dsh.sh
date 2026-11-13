#!/usr/bin/env bash
# 构建并准备 Safarier 内置的 DeepSeek Harness (dsh) 运行环境
# 保证与系统/其他应用的 dsh 互相隔离，不共用 ~/.dsh 配置或端口

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DSH_DIR="$ROOT/.build/dsh"
TARGET_VERSION="0.2.2-rc.1"

echo "==> 检查 Safarier 内部 dsh 环境: $DSH_DIR"
mkdir -p "$DSH_DIR" "$DSH_DIR/bin"

if [ ! -f "$DSH_DIR/package.json" ]; then
  (cd "$DSH_DIR" && npm init -y >/dev/null)
fi

# 检查是否已安装指定版本
INSTALLED_VER="$(node -e "try { console.log(require('$DSH_DIR/node_modules/@deepseek-ai/dsh/package.json').version); } catch(e) { console.log(''); }" 2>/dev/null || true)"

if [ "$INSTALLED_VER" != "$TARGET_VERSION" ]; then
  echo "==> 安装最新版 @deepseek-ai/dsh@$TARGET_VERSION 到 $DSH_DIR..."
  (cd "$DSH_DIR" && npm install --no-audit --prefer-offline "@deepseek-ai/dsh@$TARGET_VERSION")
else
  echo "==> 已安装目标版本: $INSTALLED_VER"
fi

# 创建自包含 runner 包装脚本
RUNNER="$DSH_DIR/bin/dsh"
cat > "$RUNNER" <<'RUNNER_SCRIPT'
#!/usr/bin/env bash
# Safarier AI 专用 DeepSeek Harness 启动包装器
set -e

# 定位 Node.js 运行时
NODE_BIN=""
for cand in \
  "${NODE_BINARY:-}" \
  "$(dirname "$0")/node" \
  "/opt/homebrew/bin/node" \
  "/usr/local/bin/node" \
  "$HOME/.nvm/current/bin/node" \
  "$(which node 2>/dev/null || true)"
do
  if [ -n "$cand" ] && [ -x "$cand" ]; then
    NODE_BIN="$cand"
    break
  fi
done

if [ -z "$NODE_BIN" ]; then
  echo "错误: 未找到可用的 Node.js 运行时（需要 Node.js >= 22）" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTRYPOINT="$SCRIPT_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"

if [ ! -f "$ENTRYPOINT" ]; then
  echo "错误: dsh 入口文件不存在: $ENTRYPOINT" >&2
  exit 1
fi

# 隔离 DSH 用户数据目录到 Safarier 专有沙盒
export DSH_HOME="${DSH_HOME:-$HOME/Library/Application Support/Safarier/dsh}"
export DSH_AGENTS_HOME="${DSH_AGENTS_HOME:-$DSH_HOME/agents}"
mkdir -p "$DSH_HOME" "$DSH_AGENTS_HOME"

# 清理不兼容的 socks 代理变量，避免 dsh 启动警告
case "${all_proxy:-}" in
  socks*|SOCKS*) unset all_proxy ;;
esac
case "${ALL_PROXY:-}" in
  socks*|SOCKS*) unset ALL_PROXY ;;
esac

exec "$NODE_BIN" "$ENTRYPOINT" "$@"
RUNNER_SCRIPT

chmod +x "$RUNNER"
echo "==> Safarier 专用 dsh runner 就绪: $RUNNER"
"$RUNNER" -V
