#!/bin/bash
set -e

IMAGE_NAME="nexus-node:latest"
BUILD_DIR="/root/nexus-docker"
LOG_DIR="/var/log/nexus"
DEFAULT_MEM_LIMIT="6g"  # 全局内存限制变量

function ensure_jq_installed() {
    if ! command -v jq &>/dev/null; then
        echo "jq 工具未安装，正在安装..."
        if ! apt-get update; then
            echo "❌ 更新包列表失败"
            return 1
        fi
        
        if ! apt-get install -y jq; then
            echo "❌ jq 安装失败！自动状态管理需要此工具"
            return 1
        fi
        
        if ! command -v jq &>/dev/null; then
            echo "❌ jq 安装后仍不可用"
            return 1
        fi
        echo "✅ jq 已成功安装"
    fi
    return 0
}

function check_docker() {
    if ! command -v docker &>/dev/null; then
        echo "Docker 未安装，正在安装..."
        apt-get update
        apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io
        systemctl enable docker
        systemctl start docker
    fi
}

function init_log_dir() {
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    if [ ! -w "$LOG_DIR" ]; then
        echo "❌ 无法写入日志目录 $LOG_DIR，请检查权限"
        return 1
    fi
}

function prepare_build_files() {
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \\
    curl \\
    screen \\
    cron \\
    bash \\
    jq \\
    logrotate \\
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://cli.nexus.xyz/ | bash && \\
    cp /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network && \\
    chmod +x /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 添加日志轮转配置
COPY nexus-logrotate /etc/logrotate.d/nexus

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<'EOF'
#!/bin/bash
set -e

PROVER_ID_FILE="/root/.nexus/node-id"
LOG_FILE="/var/log/nexus/nexus.log"

mkdir -p "$(dirname "$PROVER_ID_FILE")" "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" && chmod 644 "$LOG_FILE"

echo "$NODE_ID" > "$PROVER_ID_FILE"
echo "使用的 node-id: $NODE_ID"

[ -n "$NEXUS_LOG" ] && LOG_FILE="$NEXUS_LOG"
[ -n "$SCREEN_NAME" ] || SCREEN_NAME="nexus"

if ! command -v nexus-network &>/dev/null; then
    echo "nexus-network 未安装"
    exit 1
fi

screen -S "$SCREEN_NAME" -X quit &>/dev/null || true

echo "启动 nexus-network... (容器ID: $(hostname))"
screen -dmS "$SCREEN_NAME" bash -c "nexus-network start --node-id $NODE_ID &>> $LOG_FILE"

sleep 3

if screen -list | grep -q "$SCREEN_NAME"; then
    echo "实例 [$SCREEN_NAME] 已启动，日志文件：$LOG_FILE"
else
    echo "启动失败：$SCREEN_NAME"
    cat "$LOG_FILE"
    exit 1
fi

tail -f "$LOG_FILE"
EOF

    cat > nexus-logrotate <<'EOF'
/var/log/nexus/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF
}

function build_image() {
    cd "$BUILD_DIR"
    if ! docker build -t "$IMAGE_NAME" .; then
        echo "❌ 镜像构建失败"
        return 1
    fi
}

function prepare_log_file() {
    local log_file="$1"
    
    [[ -d "$log_file" ]] && rm -rf "$log_file"
    
    if ! touch "$log_file" && chmod 644 "$log_file"; then
        echo "❌ 无法创建日志文件 $log_file，请检查权限"
        return 1
    fi
}

function start_instances() {
    read -rp "请输入要创建的实例数量: " INSTANCE_COUNT
    if ! [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || [[ $INSTANCE_COUNT -lt 1 ]]; then
        echo "❌ 无效数量。请输入正整数。"
        return 1
    fi

    init_log_dir || return 1

    # 询问内存限制
    read -rp "请输入每个容器内存限制(如6g/8g/空表示不限): " MEM_LIMIT
    [[ -z "$MEM_LIMIT" ]] && MEM_LIMIT="no-limit" || MEM_LIMIT="$MEM_LIMIT"

    for i in $(seq 1 "$INSTANCE_COUNT"); do
        read -rp "请输入第 $i 个实例的 node-id: " NODE_ID
        [[ -z "$NODE_ID" ]] && echo "❌ node-id 不能为空" && continue
        
        CONTAINER_NAME="nexus-node-$i"
        LOG_FILE="$LOG_DIR/nexus-$i.log"
        SCREEN_NAME="nexus-$i"

        docker rm -f "$CONTAINER_NAME" &>/dev/null || true

        prepare_log_file "$LOG_FILE" || continue

        # 构建docker启动命令
        DOCKER_CMD="docker run -d --name $CONTAINER_NAME"
        [ "$MEM_LIMIT" != "no-limit" ] && \
            DOCKER_CMD+=" --memory $MEM_LIMIT --memory-swap $MEM_LIMIT --oom-kill-disable=false"
        
        DOCKER_CMD+=" -e NODE_ID='$NODE_ID'"
        DOCKER_CMD+=" -e NEXUS_LOG='$LOG_FILE'"
        DOCKER_CMD+=" -e SCREEN_NAME='$SCREEN_NAME'"
        DOCKER_CMD+=" -v '$LOG_FILE:$LOG_FILE'"
        DOCKER_CMD+=" -v '$LOG_DIR:$LOG_DIR'"
        DOCKER_CMD+=" $IMAGE_NAME"

        # 执行启动命令
        if ! eval $DOCKER_CMD; then
            echo "❌ 启动容器 $CONTAINER_NAME 失败"
            continue
        fi

        # 状态诊断
        echo "⌛ 等待容器启动(10秒)..."
        sleep 10
        if docker ps --filter "name=$CONTAINER_NAME" --format '{{.Status}}' | grep -q 'Up'; then
            echo "✅ 容器状态: 运行正常"
            docker inspect --format '{{json .HostConfig.Memory }}' "$CONTAINER_NAME" | \
                jq -r 'if . == 0 then "内存限制: 无限制" else "内存限制: " + (.|tostring) + " bytes" end'
        else
            echo "⚠️ 容器状态异常! 执行诊断:"
            docker logs --tail 20 $CONTAINER_NAME
        fi
    done
}

function stop_all_instances() {
    echo "🛑 停止所有 Nexus 实例..."
    docker ps -a --format '{{.Names}}' | grep '^nexus-node-' | while read -r name; do
        docker rm -f "$name" &>/dev/null && echo "停止 $name"
    done
}

function restart_instance() {
    read -rp "请输入实例编号（如 2 表示 nexus-node-2）: " idx
    CONTAINER_NAME="nexus-node-$idx"
    
    if ! docker inspect "$CONTAINER_NAME" &>/dev/null; then
        echo "❌ 实例 $CONTAINER_NAME 不存在"
        return 1
    fi

    LOG_FILE="$LOG_DIR/nexus-$idx.log"
    SCREEN_NAME="nexus-$idx"

    NODE_ID=$(docker inspect --format '{{index .Config.Env | join "\n"}}' "$CONTAINER_NAME" | awk -F= '/NODE_ID/{print $2}')
    [[ -z "$NODE_ID" ]] && echo "❌ 未找到node-id" && return 1

    prepare_log_file "$LOG_FILE" || return 1

    # 获取原内存限制设置
    current_mem_limit=$(docker inspect --format '{{.HostConfig.Memory}}' "$CONTAINER_NAME")
    MEM_FLAGS=""
    if [ "$current_mem_limit" -gt 0 ]; then
        MEM_FLAGS="--memory=${current_mem_limit} --memory-swap=${current_mem_limit} --oom-kill-disable=false"
    fi

    docker rm -f "$CONTAINER_NAME" &>/dev/null
    if ! docker run -d \
        --name "$CONTAINER_NAME" \
        $MEM_FLAGS \
        -e NODE_ID="$NODE_ID" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -v "$LOG_FILE":"$LOG_FILE" \
        -v "$LOG_DIR":"$LOG_DIR" \
        "$IMAGE_NAME"; then
        echo "❌ 重启容器 $CONTAINER_NAME 失败"
        return 1
    fi

    echo "✅ 已重启：$CONTAINER_NAME"
    echo "🔄 监控状态..."
    sleep 10
    if docker ps --filter "name=$CONTAINER_NAME" | grep -q 'Up'; then
        echo "✅ 状态: 运行中"
    else
        echo "❌ 启动失败! 查看日志:"
        docker logs --tail 20 $CONTAINER_NAME
    fi
}

function change_node_id() {
    read -rp "请输入要更换的实例编号: " idx
    read -rp "请输入新的 node-id: " NEW_ID
    [[ -z "$NEW_ID" ]] && echo "❌ node-id 不能为空" && return 1

    CONTAINER_NAME="nexus-node-$idx"
    LOG_FILE="$LOG_DIR/nexus-$idx.log"
    SCREEN_NAME="nexus-$idx"

    prepare_log_file "$LOG_FILE" || return 1

    # 获取原内存限制设置
    current_m极limit=$(docker inspect --format '{{.HostConfig.Memory}}' "$CONTAINER_NAME")
    MEM_FLAGS=""
    if [ "$current_mem_limit" -gt 0 ]; then
        MEM_FLAGS="--memory=${current_mem_limit} --memory-swap=${current_mem_limit} --oom-kill-disable=false"
    fi

    docker rm -f "$CONTAINER_NAME" &>/dev/null
    if ! docker run -d \
        --name "$极CONTAINER_NAME" \
        $MEM_FLAGS \
        -e NODE_ID="$NEW_ID" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -v "$LOG_FILE":"$LOG_FILE" \
        -v "$LOG_DIR":"$LOG_DIR" \
        "$IMAGE_NAME"; then
        echo "❌ 启动容器 $CONTAINER_NAME 失败"
        return 1
    fi

    echo "✅ 实例 $CONTAINER_NAME 已使用新 ID 启动"
    echo "🔄 监控状态..."
    sleep 10
    if docker ps --filter "name=$CONTAINER_NAME" | grep -q 'Up'; then
        echo "✅ 状态: 运行中"
    else
        echo "❌ 启动失败! 查看日志:"
        docker logs --tail 20 $CONTAINER_NAME
    fi
}

function add_one_instance() {
    NEXT_NUM=1
    while docker ps -a --format '{{.Names}}' | grep -qw "nexus-node-$NEXT_NUM"; do
        ((NEXT_NUM++))
    done

    read -rp "请输入新实例的 node-id: " NODE_ID
    [[ -z "$NODE_ID" ]] && echo "❌ node-id 不能为空" && return 1
    
    CONTAINER_NAME="nexus-node-$NEXT_NUM"
    LOG_FILE="$LOG_DIR/nexus-$NEXT_NUM.log"
    SCREEN_NAME="nexus-$NEXT_NUM"

    # 询问内存限制
    read -rp "请输入内存限制(如6g/8g/空表示不限): " MEM_LIMIT
    [[ -z "$MEM_LIMIT" ]] && MEM_LIMIT="no-limit" || MEM_LIMIT="$MEM_LIMIT"

    init_log_dir || return 1
    prepare_log_file "$LOG_FILE" || return 1

    # 构建docker启动命令
    DOCKER_CMD="docker run -d --name $CONTAINER_NAME"
    [ "$MEM_LIMIT" != "no-limit" ] && \
        DOCKER_CMD+=" --memory $MEM_LIMIT --memory-swap $MEM_LIMIT --oom-kill-disable=false"
    
    DOCKER_CMD+=" -e NODE_ID='$NODE_ID'"
    DOCKER_CMD+=" -e NEXUS_LOG='$LOG_FILE'"
    DOCKER_CMD+=" -e SCREEN_NAME='$SCREEN_NAME'"
    DOCKER_CMD+=" -v '$LOG_FILE:$LOG_FILE'"
    DOCKER_CMD+=" -v '$LOG_DIR:$LOG_DIR'"
    DOCKER_CMD+=" $IMAGE_NAME"

    if ! eval $DOCKER_CMD; then
        echo "❌ 启动容器 $CONTAINER_NAME 失败"
        return 1
    fi

    echo "✅ 添加实例成功：$CONTAINER_NAME"
    echo "日志文件路径: $LOG_FILE"
    
    # 状态诊断
    echo "⌛ 等待容器启动..."
    sleep 10
    if docker ps --filter "name=$CONTAINER_NAME" | grep -q 'Up'; then
        echo "✅ 状态: 运行中"
    else
        echo "❌ 启动失败! 查看日志:"
        docker logs --tail 20 $CONTAINER_NAME
    fi
}

function view_logs() {
    read -rp "请输入实例编号: " idx
    LOG_FILE="$LOG_DIR/nexus-$idx.log"
    [[ ! -f "$LOG_FILE" ]] && echo "❌ 日志不存在" && return 1
    tail -f "$LOG_FILE"
}

function show_running_ids() {
    echo "📋 当前正在运行的实例及 ID："
    docker ps --format '{{.Names}}' | grep '^nexus-node-' | while read -极r name; do
        ID=$(docker exec "$name" bash -c 'cat /root/.nexus/node-id 2>/dev/null || echo "未获取到"')
        mem_usage=$(docker stats --no-stream --format "{{.MemUsage}}" "$name" | cut -d '/' -f1 | tr -d ' ')
        mem_limit=$(docker inspect --format '{{.HostConfig.Memory}}' "$name")
        if [ "$mem_limit" -eq 0 ]; then
            mem_status="内存: $mem_usage (无限制)"
        else
            mem_status="内存: $mem_usage/$mem_limit"
        fi
        echo "$name: $ID | $mem_status"
    done
}

function check_container_resources() {
    echo "📊 容器资源监控(持续刷新, Ctrl+C退出)"
    watch -n 5 "docker stats --no-stream --format \
        'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' \
        \$(docker ps -q --filter 'name=nexus-node')"
}

function auto_generate_rotation_config() {
    local config_file="$1"
    local state_file="$2"
    
    echo "🔍 正在检测现有实例..."
    declare -A current_ids
    running_instances=$(docker ps --format '{{.Names}}' | grep '^nexus-node-')
    
    [[ -z "$running_instances" ]] && echo "⚠️ 未检测到运行中的实例" && return 1

    echo "✅ 发现运行中实例:"
    while read -r name; do
        id=$(docker exec "$name" cat /root/.nexus/node-id 2>/dev/null)
        if [[ -n "$id" ]]; then
            current_ids["$name"]="$id"
            echo " - $name (ID: $id)"
        else
            echo " - $name: ❌ 无法获取ID"
        fi
    done <<< "$running_instances"
    
    [[ ${#current_ids[@]} -eq 0 ]] && echo "❌ 所有实例均无法获取node-id" && return 1

    # 生成配置模板
    echo "📝 生成初始配置文件..."
    echo -n "{" > "$config_file"
    first=true
    for name in "${!current_ids[@]}"; do
        if ! $first; then
            echo -n "," >> "$config_file"
        else
            first=false
        fi
        echo -n "\n  \"$name\": [\"${current_ids[$name]}\"" >> "$config_file"
        echo -n ", \"在此添加更多ID\"]" >> "$config_file"
    done
    echo -e "\n}" >> "$config_file"
    
    # 生成状态文件
    echo -n "{" > "$state_file"
    first=true
    for name in "${!current_ids[@]}"; do
        if ! $first; then
            echo -n "," >> "$state_file"
        else
            first=false
        fi
        echo -n "\n  \"$name\": 0" >> "$state_file"
    done
    echo -e "\n}" >> "$state_file"

    echo "✅ 配置文件和状态文件已生成，请编辑 ${config_file##*/} 添加更多ID"
    return 0
}

function setup_rotation_schedule() {
    echo "📦 正在部署ID自动轮换系统..."
    
    # 确保jq可用
    if ! ensure_jq_installed; then
        echo "❌ 无法自动部署轮换系统，请手动安装jq后重试"
        echo "安装命令: apt-get update && apt-get install -y jq"
        return 1
    fi
    
    init_log_dir || return 1
    config_file="/root/nexus-id-config.json"
    state_file="/root/nexus-id-state.json"
    
    # 即使配置文件存在，也要检查状态文件
    if [[ -f "$config_file" ]]; then
        echo "ℹ️ 使用现有配置文件: ${config_file##*/}"
        
        # 确保状态文件存在
        if [[ ! -f "$state_file" ]]; then
            echo "ℹ️ 状态文件不存在，正在初始化..."
            running_instances=$(docker ps --format '{{.Names}}' | grep '^nexus-node-')
            
            if [[ -z "$running_instances" ]]; then
                echo "❌ 没有运行中的实例，无法初始化状态极文件"
                return 1
            fi
            
            echo "{" > "$state_file"
            first=true
            while read -r name; do
                if [[ "$first" == "true" ]]; then
                    first=false
                    echo -n "  \"$name\": 0" >> "$state_file"
                else
                    echo -n ",\n  \"$name\": 0" >> "$state_file"
                fi
            done <<< "$running_instances"
            echo -e "\n}" >> "$state_file"
            echo "✅ 状态文件已初始化"
        fi
    else
        if ! auto_generate_rotation_config "$config_file" "$state_file"; then
            echo "❌ 自动生成配置失败，请手动创建文件"
            return 1
        fi
    fi

    # 检测系统资源
    echo "🔍 检测系统资源..."
    free_mem=$(free -m | awk '/Mem/{print $4}')
    cpu_cores=$(nproc)
    echo " - 可用内存: ${free_mem}MB (最少建议2000MB)"
    echo " - CPU核心: $cpu_cores"
    
    # 创建优化后的轮换脚本
    cat > /root/nexus-rotate.sh <<'EOS'
#!/bin/bash
set -euo pipefail

CONFIG="/root/nexus-id-config.json"
STATE="/root/nexus-id-state.json"
LOG_DIR="/var/log/nexus"
ROTATE_LOG="$LOG_DIR/nexus-rotate.log"
FAILURE_FILE="$LOG_DIR/rotation-failure.log"

# 确保日志目录存在
mkdir -p "$LOG_DIR"
touch "$ROTATE_LOG" "$FAILURE_FILE"
chmod 644 "$ROTATE_LOG" "$FAILURE_FILE"

function log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$ROTATE_LOG"
}

function log_failure() {
    log "❌ $1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$FAILURE_FILE"
}

start_time=$(date +%s)
log "🚀 ID轮换系统启动 (v1.2)"

# 资源检查函数
function resource_check() {
    log "🔄 资源检查..."
    
    # 检查内存
    local free_mem=$(free -m | awk '/Mem/{print $4}')
    local min_mem=2000
    if [[ $free_mem -lt $min_mem ]]; then
        log_failure "内存不足! 可用内存: ${free_mem}MB (要求至少${min_mem}MB)"
        return 1
    fi
    
    # 检查Docker服务状态
    if ! systemctl is-active --quiet docker; then
        log_failure "Docker服务未运行!"
        return 1
    fi
    
    if ! docker info &>/dev/null; then
        log_failure "Docker服务无响应!"
        return 1
    fi
    
    # 检查存储空间
    local disk_usage=$(df / --output=pcent | tr -dc '0-9')
    if [[ $disk_usage -gt 85 ]]; then
        log_failure "磁盘空间不足! 使用率: ${disk_usage}%"
        return 1
    fi
    
    # 检查配置有效性
    if ! jq -e '.' "$CONFIG" >/dev/null 2>&1; then
        log_failure "配置文件损坏: $CONFIG"
        return 1
    fi
    
    log "✅ 资源检查通过 (内存: ${free_mem}MB)"
    return 0
}

# 主流程执行前检查资源
resource_check || exit 1

# 检查配置状态文件
[[ ! -f "$CONFIG" ]] && { log_failure "配置文件不存在: $CONFIG"; exit 1; }
[[ ! -f "$STATE" ]] && { log_failure "状态文件不存在: $STATE"; exit 1; }

function get_next_index() {
    local current=$1
    local max=$2
    echo $(((current + 1) % max))
}

function fetch_original_mem_limit() {
    local instance="$1"
    local mem_hex=$(docker inspect --format '{{.HostConfig.Memory}}' "$instance" 2>/dev/null)
    if [[ "$mem_hex" -gt 0 ]]; then
        local mem_mb=$((mem_hex / (1024 * 1024)))
        echo "${mem_mb}m"
    else
        # 找不到记录使用默认6g
        echo "6g"
    fi
}

jq -r 'keys[]' "$CONFIG" | while read -r INSTANCE; do
    log "============================================================"
    log "🛫 开始处理实例: $INSTANCE"
    
    # 获取状态索引
    CURRENT_INDEX=$(jq -r ".\"$INSTANCE\"" "$STATE" 2>/dev/null || echo "0")
    log " - 当前索引: $CURRENT_INDEX"
    
    # 读取实例配置
    log " - 读取配置..."
    IDS=($(jq -r ".\"$INSTANCE\"[]" "$CONFIG"))
    
    # 过滤占位符ID
    REAL_IDS=()
    for id in "${IDS[@]}"; do
        [[ "$id" != "在此添加更多ID" ]] && REAL_IDS+=("$id")
    done
    REAL_COUNT=${#REAL_IDS[@]}
    log " - 有效ID数量: $REAL_COUNT"
    
    if [[ $REAL_COUNT -lt 2 ]]; then
        log_failure "$INSTANCE: 有效ID少于2个 (需添加)"
        continue
    fi
    
    NEXT_INDEX=$(get_next_index "$CURRENT极INDEX" "$REAL_COUNT")
    NEW_ID="${REAL_IDS[$NEXT_INDEX]}"
    log "🔄 准备切换为ID[${NEXT_INDEX}]: ${NEW_ID:0:6}****"
    
    # 获取原始内存限制
    ORIGINAL_MEM=$(fetch_original_mem_limit "$INSTANCE")
    log " - 内存限制: $ORIGINAL_MEM"
    
    # 停止现有容器
    log " - 停止容器: $INSTANCE..."
    if docker rm -f "$INSTANCE" &>/dev/null; then
        log "   - 停止成功"
    else
        log_failure "   - 停止容器失败"
        continue
    fi
    
    # 等待容器完全终止
    sleep 2
    
    # 准备日志文件
    INSTANCE_NUM="${INSTANCE##*-}"
    LOG_FILE="$LOG_DIR/nexus-$INSTANCE_NUM.log"
    mkdir -p "$(dirname "$LOG_FILE")"
    if ! touch "$LOG_FILE" && chmod 644 "$LOG_FILE"; then
        log_failure "   - 创建日志文件失败: $LOG_FILE"
        continue
    fi
    
    # 构建启动命令
    log " - 构建启动命令..."
    DOCKER_CMD="docker run -d --name $INSTANCE"
    DOCKER_CMD+=" --memory $ORIGINAL_MEM --memory-swap $ORIGINAL_MEM --oom-kill-disable=false"
    DOCKER_CMD+=" -e NODE_ID='$NEW_ID'"
    DOCKER_CMD+=" -e NEXUS_LOG='$LOG_FILE'"
    DOCKER_CMD+=" -e SCREEN_NAME='${INSTANCE//nexus-node-/nexus-}'"
    DOCKER_CMD+=" -v '$LOG_FILE:$LOG_FILE'"
    DOCKER_CMD+=" -v '$LOG_DIR:$LOG_DIR'"
    DOCKER_CMD+=" $IMAGE_NAME"
    
    log " - 启动容器..."
    start_time_c=$(date +%s)
    if eval $DOCKER_CMD; then
        log "   - 容器启动成功"
        
        # 状态验证
        log "   - 验证容器状态..."
        sleep 5
        if docker ps --filter "name=$INSTANCE" | grep -q 'Up'; then
            log "   - 状态验证成功"
            
            # 更新状态
            log "   - 更新状态文件..."
            if jq ".\"$INSTANCE\" = $NEXT_INDEX" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; then
                log "✅ $INSTANCE: 轮换成功! 用时: $(($(date +%s)-start_time_c))秒"
            else
                log_failure "   - 更新状态文件失败!"
            fi
        else
            log_failure "   - 容器启动后状态异常"
            log "   - 故障诊断:"
            docker logs --tail 20 "$INSTANCE" 2>&1 | sed 's/^/   | /' | tee -a "$ROTATE_LOG"
            log "   - 容器已被清理"
            docker rm -f "$INSTANCE" &>/dev/null || true
        fi
    else
        log_failure "   - 容器启动失败 (退出码: $?)"
    fi
    
    # 间隔几秒防止资源冲突
    sleep 3
done

log "🏁 本次轮换完成! 总计时间: $(($(date +%s)-start_time))秒"
log "故障详情请查看: $FAILURE_FILE"
exit 0
EOS

    chmod +x /root/nexus-rotate.sh

    # 配置cron定时任务
    if ! crontab -l | grep -q "nexus-rotate"; then
        (
            crontab -l 2>/dev/null
            echo "0 */2 * * * /root/nexus-rotate.sh >> /var/log/nexus/nexus-rotate.log 2>&1"
            echo "@reboot sleep 120 && /root/nexus-rotate.sh >> /var/log/nexus/nexus-rotate.log 2>&1"
        ) | crontab -
        echo "⏰ 定时任务已添加 (每2小时+系统启动)"
    else
        echo "ℹ️ 定时任务已存在"
    fi

    # 添加监控脚本
    cat > /usr/local/bin/nexus-monitor <<'EOM'
#!/bin/bash
# 监控自动轮换脚本的健康状态
LOG_FILE="/var/log/nexus/nexus-rotate.log"
FAILURE_FILE="/var/log/nexus/rotation-failure.log"
THRESHOLD_MINUTES=150  # 超过150分钟没轮换发出报警

function send_alert() {
    local msg="[$HOSTNAME] Nexus轮换系统报警: $1"
    echo "$msg"
    # 实际环境中应替换为您的报警发送逻辑
    # 例如: telegram-send "$msg" || curl -X POST...
}

# 检查最近的轮换记录
if [[ ! -f "$LOG_FILE" ]]; then
    send_alert "轮换日志文件不存在"
    exit 1
fi

# 检查故障文件
if [[ -s "$FAILURE_FILE" ]]; then
    failures=$(tail -n 3 "$FAILURE_FILE")
    send_alert "发现轮换错误:\n$failures"
fi

# 检查最近成功的轮换
last_success_entry=$(grep "本次轮换完成" "$LOG_FILE" | tail -1)
if [[ -z "$last_success_entry" ]]; then
    send_alert "未找到成功的轮换记录"
    exit 1
fi

# 获取上次轮换时间
last_success_time=$(echo "$last_success_entry" | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}")
last_success_timestamp=$(date -d "$last_success_time" +%s)

# 检查时间差
now_timestamp=$(date +%s)
minutes_since=$(( (now_timestamp - last_success_timestamp) / 60 ))

if [[ $minutes_since -gt $THRESHOLD_MINUTES ]]; then
    send_alert "轮换系统异常! 上次轮换: $minutes_since 分钟前"
fi

exit 0
EOM

    chmod +x /usr/local/bin/nexus-monitor
    
    # 添加监控计划任务
    if ! crontab -l | grep -q "nexus-monitor"; then
        (
            crontab -l 2>/dev/null
            echo "*/30 * * * * /usr/local/bin/nexus-monitor >> /var/log/nexus/nexus-monitor.log 2>&1"
        ) | crontab -
        echo "👁️ 添加监控计划任务 (每30分钟)"
    fi

    echo ""
    echo "✅ ID自动轮换系统部署完成！"
    echo "================================="
    echo "1. 手动测试轮换:"
    echo "   /root/nexus-rotate.sh"
    echo "   tail -f /var/log/nexus/nexus-rotate.log"
    echo ""
    echo "2. 重要文件位置:"
    echo "   - 轮换配置: $config_file"
    echo "   - 状态文件: $state_file"
    echo "   - 轮换日志: /var/log/nexus/nexus-rotate.log"
    echo "   - 错误日志: /var/log/nexus/rotation-failure.log"
    echo ""
    echo "3. 定期监控:"
    echo "   - 监控脚本: /usr/local/bin/nexus-monitor"
    echo "   - 监控日志: /var/log/nexus/nexus-monitor.log"
    echo ""
    echo "4. 自定义报警:"
    echo "   编辑 /usr/local/bin/nexus-monitor 添加实际报警发送逻辑"
    echo "================================="
    return 0
}

function show_menu() {
    while true; do
        echo ""
        echo "=========== Nexus 节点管理 ==========="
        echo "1. 构建并启动新实例"
        echo "2. 停止所有实例"
        echo "3. 重启指定实例"
        echo "4. 查看运行中的实例及 ID"
        echo "5. 退出"
        echo "6. 更换某个实例的 node-id（并自动重启）"
        echo "7. 添加一个新实例"
        echo "8. 查看指定实例日志"
        echo "9. 部署ID自动轮换系统（每2小时）"
        echo "10. 监控容器资源使用情况"
        echo "======================================"
        read -rp "请选择操作 (1-10): " choice
        
        case "$choice" in
            1) 
                check_docker
                prepare_build_files
                build_image && start_instances
                ;;
            2) stop_all_instances ;;
            3) restart_instance ;;
            4) show_running_ids ;;
            5) echo "退出"; exit 0 ;;
            6) change_node_id ;;
            7) add_one_instance ;;
            8) view_logs ;;
            9) setup_rotation_schedule ;;
            10) check_container_resources ;;
            *) echo "无效选项，请输入 1-10" ;;
        esac
        
        read -n 1 -s -r -p "按任意键继续..."
        clear
    done
}

# 启动菜单
show_menu
