#!/bin/bash

# Graphiti MCP Server 启动脚本
# 支持 SiliconFlow API + OpenAI 接口

set -e  # 遇到错误立即退出

source ../.venv/bin/activate

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 配置变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEO4J_CONTAINER_NAME="graphiti-neo4j"

# 加载环境变量文件
if [ -f "$SCRIPT_DIR/.env" ]; then
    log_info "加载 .env 文件..."
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
else
    log_error "未找到 .env 文件，请在 mcp_server 目录下创建 .env 文件"
    exit 1
fi

# 验证必要的环境变量
if [ -z "$OPENAI_API_KEY" ] || [ -z "$EMBEDDING_API_KEY" ]; then
    log_error "缺少必要的 API 密钥，请检查 .env 文件"
    exit 1
fi

# API配置（如果.env中没有设置，使用默认值）
OPENAI_BASE_URL="${OPENAI_BASE_URL:-https://openrouter.ai/api/v1}"
EMBEDDING_BASE_URL="${EMBEDDING_BASE_URL:-https://api.siliconflow.cn/v1}"

SEMAPHORE_LIMIT=1

# 默认配置
DEFAULT_MODEL="moonshotai/kimi-k2:free"
DEFAULT_SMALL_MODEL="moonshotai/kimi-k2:free"
DEFAULT_EMBEDDER_MODEL="Qwen/Qwen3-Embedding-8B"
DEFAULT_NEO4J_PASSWORD="password"

echo "======================================"
echo "🚀 Graphiti MCP Server 启动脚本"
echo "📍 目录: $SCRIPT_DIR"
echo "======================================"

# 步骤1: 检查Docker是否运行
log_step "检查 Docker 状态..."
if ! docker info > /dev/null 2>&1; then
    log_error "Docker 未运行，请先启动 Docker"
    exit 1
fi
log_info "Docker 状态正常"

# 步骤2: 启动 Neo4j
log_step "启动 Neo4j 数据库..."
if docker ps --format "table {{.Names}}" | grep -q "^${NEO4J_CONTAINER_NAME}$"; then
    log_info "Neo4j 容器已运行"
elif docker ps -a --format "table {{.Names}}" | grep -q "^${NEO4J_CONTAINER_NAME}$"; then
    log_warn "Neo4j 容器已存在但未运行，启动中..."
    docker start $NEO4J_CONTAINER_NAME
else
    log_warn "Neo4j 容器不存在，创建并启动..."
    docker run -d \
        --name $NEO4J_CONTAINER_NAME \
        --publish=7474:7474 --publish=7687:7687 \
        --env NEO4J_AUTH=neo4j/$DEFAULT_NEO4J_PASSWORD \
        --env NEO4J_server_memory_heap_initial__size=512m \
        --env NEO4J_server_memory_heap_max__size=1G \
        neo4j:5.26.0
fi

# 步骤3: 验证 Neo4j 状态
log_step "验证 Neo4j 状态..."
if curl -f http://localhost:7474 > /dev/null 2>&1; then
    log_info "Neo4j 已就绪 - Web界面: http://localhost:7474"
    log_info "认证信息: neo4j/$DEFAULT_NEO4J_PASSWORD"
else
    log_warn "Neo4j 可能还在启动中，稍等片刻..."
    MAX_WAIT=30
    WAIT_COUNT=0
    while ! curl -f http://localhost:7474 > /dev/null 2>&1; do
        if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
            log_error "Neo4j 启动验证超时，但将继续启动MCP服务器"
            break
        fi
        echo -n "."
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
    done
    echo
fi

# 步骤4: 检查虚拟环境
log_step "检查 Python 虚拟环境..."
if [ ! -d "$SCRIPT_DIR/../.venv" ]; then
    log_error "未找到虚拟环境，请确保已创建 .venv"
    exit 1
fi
log_info "虚拟环境路径: $SCRIPT_DIR/../.venv"

# 步骤5: 检查必要的Python包
log_step "检查 Python 依赖..."
cd $SCRIPT_DIR

# 检查包的映射：包名 -> 导入名
declare -A PACKAGE_MAP=(
    ["openai"]="openai"
    ["mcp"]="mcp"
    ["graphiti-core"]="graphiti_core"
    ["azure-identity"]="azure.identity"
)

REQUIRED_PACKAGES=("openai" "mcp" "graphiti-core" "azure-identity")
MISSING_PACKAGES=()

for package in "${REQUIRED_PACKAGES[@]}"; do
    import_name="${PACKAGE_MAP[$package]}"
    if ! python -c "import $import_name" 2>/dev/null; then
        MISSING_PACKAGES+=("$package")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    log_error "缺少以下必要包: ${MISSING_PACKAGES[*]}"
    log_warn "请运行: pip install ${MISSING_PACKAGES[*]}"
    exit 1
fi

log_info "所有必要依赖已安装"

# 步骤6: 设置环境变量
log_step "设置环境变量..."
export OPENAI_API_KEY="$OPENAI_API_KEY"
export OPENAI_BASE_URL="$OPENAI_BASE_URL"
# 为embedding设置独立的API key和base_url，使用SiliconFlow API
export EMBEDDING_API_KEY="${EMBEDDING_API_KEY}"
export EMBEDDING_BASE_URL="${EMBEDDING_BASE_URL}"
export EMBEDDER_MODEL_NAME="${EMBEDDER_MODEL_NAME:-$DEFAULT_EMBEDDER_MODEL}"
export MODEL_NAME="${MODEL_NAME:-$DEFAULT_MODEL}"
export SMALL_MODEL_NAME="${SMALL_MODEL_NAME:-$DEFAULT_SMALL_MODEL}"
export LLM_TEMPERATURE="${LLM_TEMPERATURE:-0.1}"
export NEO4J_URI="${NEO4J_URI:-bolt://localhost:7687}"
export NEO4J_USER="${NEO4J_USER:-neo4j}"
export NEO4J_PASSWORD="${NEO4J_PASSWORD:-$DEFAULT_NEO4J_PASSWORD}"
export SEMAPHORE_LIMIT="${SEMAPHORE_LIMIT:-10}"
export GRAPHITI_TELEMETRY_ENABLED="${GRAPHITI_TELEMETRY_ENABLED:-false}"
export MCP_SERVER_PORT="${MCP_SERVER_PORT:-18123}"

log_info "环境变量配置:"
echo "  - 🤖 LLM: $MODEL_NAME (小模型: $SMALL_MODEL_NAME)"
echo "  - 🌐 LLM Base URL: $OPENAI_BASE_URL"
echo "  - 🔤 Embedding: $EMBEDDER_MODEL_NAME"
echo "  - 🔤 Embedding Base URL: $EMBEDDING_BASE_URL"
echo "  - 🗄️  数据库: $NEO4J_URI"
echo "  - 🚪 MCP 端口: $MCP_SERVER_PORT"
echo "  - 📊 并发限制: $SEMAPHORE_LIMIT"

# 步骤7: 启动服务器
log_step "启动 Graphiti MCP 服务器..."
echo "======================================"
log_info "服务器启动中..."
log_info "SSE 端点: http://localhost:18123/sse"
log_info "按 Ctrl+C 停止服务器"
echo "======================================"

# 启动服务器，根据参数选择传输方式
TRANSPORT="${1:-sse}"
GROUP_ID="${2:-default}"

if [ "$TRANSPORT" = "stdio" ]; then
    log_info "使用 STDIO 传输模式"
    python graphiti_mcp_server.py --transport stdio --group-id "$GROUP_ID"
else
    log_info "使用 SSE 传输模式"
    python graphiti_mcp_server.py --transport sse --group-id "$GROUP_ID"
fi