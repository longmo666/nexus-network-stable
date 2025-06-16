#!/bin/bash
set -e

IMAGE_NAME="nexus-node:latest"
BUILD_DIR="/root/nexus-docker"
LOG_DIR="/var/log/nexus"

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

    cat > Dockerfile <<'EOF'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    screen \
    cron \
    bash \
    jq \
    logrotate \
    && rm -rf /var/lib/apt/lists/*

# 修正的下载指令 - 使用正确的文件名并添加-L选项
RUN curl -sSL -L -o /tmp/nexus-network.tar.gz \
    "https://github.com/nexus-xyz/nexus-cli/releases/download/v0.8.3/nexus-network_0.8.3_Linux_x86_64.tar.gz" \
    && tar -xzf /tmp/nexus-network.tar.gz -C /usr/local/bin/ \
    && chmod +x /usr/local/bin/nexus-network \
    && rm /tmp/nexus-network.tar.gz

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

[ -n "$NEXUS_LOG"] && LOG_FILE="$NEXUS_LOG"
[ -n "$SCREEN_NAME"] || SCREEN_NAME="nexus"

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

    for i in $(seq 1 "$INSTANCE_COUNT"); do
        read -rp "请输入第 $i 个实例的 node-id: " NODE_ID
        [[ -z "$NODE_ID" ]] && echo "❌ node-id 不能为空" && continue
        
        CONTAINER_NAME="nexus-node-$i"
        LOG_FILE="$LOG_DIR/nexus-$i.log"
        SCREEN_NAME="nexus-$i"

        docker rm -f "$CONTAINER_NAME" &>/dev/null || true

        prepare_log_file "$LOG_FILE" || continue

        if ! docker run -d \
            --name "$CONTAINER_NAME" \
            -e NODE_ID="$NODE_ID" \
            -e NEXUS_LOG="$LOG_FILE" \
            -e SCREEN_NAME="$SCREEN_NAME" \
            -v "$LOG_FILE":"$LOG_FILE" \
            -v "$LOG_DIR":"$LOG_DIR" \
            "$IMAGE_NAME"; then
            echo "❌ 启动容器 $CONTAINER_NAME 失败"
            continue
        fi

        echo "✅ 启动成功：$CONTAINER_NAME"
        echo "日志文件路径: $LOG_FILE"
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

    docker rm -f "$CONTAINER_NAME" &>/dev/null
    if ! docker run -d \
        --name "$CONTAINER_NAME" \
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
}

function change_node_id() {
    read -rp "请输入要更换的实例编号: " idx
    read -rp "请输入新的 node-id: " NEW_ID
    [[ -z "$NEW_ID" ]] && echo "❌ node-id 不能为空" && return 1

    CONTAINER_NAME="nexus-node-$idx"
    LOG_FILE="$LOG_DIR/nexus-$idx.log"
    SCREEN_NAME="nexus-$idx"

    prepare_log_file "$LOG_FILE" || return 1

    docker rm -f "$CONTAINER_NAME" &>/dev/null
    if ! docker run -d \
        --name "$CONTAINER_NAME" \
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

    init_log_dir || return 1
    prepare_log_file "$LOG_FILE" || return 1

    if ! docker run -d \
        --name "$CONTAINER_NAME" \
        -e NODE_ID="$NODE_ID" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -v "$LOG_FILE":"$LOG_FILE" \
        -v "$LOG_DIR":"$LOG_DIR" \
        "$IMAGE_NAME"; then
        echo "❌ 启动容器 $CONTAINER_NAME 失败"
        return 1
    fi

    echo "✅ 添加实例成功：$CONTAINER_NAME"
    echo "日志文件路径: $LOG_FILE"
}

function view_logs() {
    read -rp "请输入实例编号: " idx
    LOG_FILE="$LOG_DIR/nexus-$idx.log"
    [[ ! -f "$LOG_FILE" ]] && echo "❌ 日志不存在" && return 1
    tail -f "$LOG_FILE"
}

function show_running_ids() {
    echo "📋 当前正在运行的实例及 ID："
    docker ps --format '{{.Names}}' | grep '^nexus-node-' | while read -r name; do
        ID=$(docker exec "$name" bash -c 'cat /root/.nexus/node-id 2>/dev/null || echo "未获取到"')
        echo "$name: $ID"
    done
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
                echo "❌ 没有运行中的实例，无法初始化状态文件"
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

    # 写入轮换脚本
    cat > /root/nexus-rotate.sh <<'EOS'
#!/bin/bash
set -e

CONFIG="/root/nexus-id-config.json"
STATE="/root/nexus-id-state.json"
LOG_DIR="/var/log/nexus"
ROTATE_LOG="$LOG_DIR/nexus-rotate.log"

# 确保日志目录存在
mkdir -p "$LOG_DIR"
touch "$ROTATE_LOG"
chmod 644 "$ROTATE_LOG"

function log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$ROTATE_LOG"
}

if [[ ! -f "$CONFIG" ]]; then
    log "❌ 配置文件 $CONFIG 不存在"
    exit 1
fi

if [[ ! -f "$STATE" ]]; then
    log "⚠️ 状态文件 $STATE 不存在，尝试从配置重建"
    
    # 尝试重建状态文件
    running_instances=$(docker ps --format '{{.Names}}' | grep '^nexus-node-')
    
    if [[ -z "$running_instances" ]]; then
        log "❌ 没有运行中的实例，无法重建状态文件"
        exit 1
    fi
    
    echo "{" > "$STATE"
    first=true
    while read -r name; do
        if [[ "$first" == "true" ]]; then
            first=false
            echo -n "  \"$name\": 0" >> "$STATE"
        else
            echo -n ",\n  \"$name\": 0" >> "$STATE"
        fi
    done <<< "$running_instances"
    echo -e "\n}" >> "$STATE"
    log "✅ 状态文件已重建"
fi

function get_next_index() {
    local current=$1
    local max=$2
    echo $(((current + 1) % max))
}

log "🔄 开始轮换ID..."

jq -r 'keys[]' "$CONFIG" | while read -r INSTANCE; do
    IDS=($(jq -r ".\"$INSTANCE\"[]" "$CONFIG"))
    [[ ${#IDS[@]} -eq 0 ]] && log "⚠️ $INSTANCE: ID列表为空" && continue
    
    # 过滤占位符ID
    REAL_IDS=()
    for id in "${IDS[@]}"; do
        [[ "$id" != "在此添加更多ID" ]] && REAL_IDS+=("$id")
    done
    REAL_COUNT=${#REAL_IDS[@]}
    
    [[ $REAL_COUNT -lt 2 ]] && log "⚠️ $INSTANCE: 有效ID少于2个 (需添加)" && continue
    
    CURRENT_INDEX=$(jq -r ".\"$INSTANCE\"" "$STATE" 2>/dev/null || echo "0")
    NEXT_INDEX=$(get_next_index "$CURRENT_INDEX" "$REAL_COUNT")
    NEW_ID="${REAL_IDS[$NEXT_INDEX]}"
    
    log "🔄 $INSTANCE: 使用新ID[$NEXT_INDEX] ${NEW_ID:0:6}****"
    
    # 停止现有容器
    if docker rm -f "$INSTANCE" &>/dev/null; then
        log " - 旧容器已停止"
    else
        log "⚠️ 停止容器失败 (可能不存在)"
    fi
    
    # 准备日志
    INSTANCE_NUM="${INSTANCE##*-}"
    LOG_FILE="$LOG_DIR/nexus-$INSTANCE_NUM.log"
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" && chmod 644 "$LOG_FILE"
    
    # 启动新容器
    if docker run -d \
        --name "$INSTANCE" \
        -e NODE_ID="$NEW_ID" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="${INSTANCE//nexus-node-/nexus-}" \
        -v "$LOG_FILE":"$LOG_FILE" \
        -v "$LOG_DIR":"$LOG_DIR" \
        nexus-node:latest; then
        log "✅ 容器启动成功"
    else
        log "❌ 容器启动失败"
        continue
    fi
    
    # 更新状态
    jq ".\"$INSTANCE\" = $NEXT_INDEX" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    if [[ $? -ne 0 ]]; then
        log "⚠️ 更新状态文件失败"
    fi
done

log "✅ 本次轮换完成"
EOS

    chmod +x /root/nexus-rotate.sh

    # 配置cron定时任务
    if ! crontab -l | grep -q "nexus-rotate"; then
        (
            crontab -l 2>/dev/null
            echo "0 */2 * * * /root/nexus-rotate.sh >> /var/log/nexus/nexus-rotate.log 2>&1"
        ) | crontab -
        echo "⏰ 定时任务已添加"
    else
        echo "ℹ️ 定时任务已存在"
    fi

    echo "✅ 自动轮换系统部署完成！"
    echo "执行以下命令立即测试:"
    echo "  /root/nexus-rotate.sh"
    echo "  tail -f /var/log/nexus/nexus-rotate.log"
    echo ""
    echo "配置文件位置:"
    echo "  $config_file"
    echo "状态文件位置:"
    echo "  $state_file"
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
        echo "======================================"
        read -rp "请选择操作 (1-9): " choice
        
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
            *) echo "无效选项，请输入 1-9" ;;
        esac
        
        read -n 1 -s -r -p "按任意键继续..."
        clear
    done
}

# 启动菜单
show_menu
