#!/bin/bash
set -e

IMAGE_NAME="nexus-node:latest"
BUILD_DIR="/root/nexus-docker"
LOG_DIR="/var/log/nexus"
DEFAULT_MEM_LIMIT="6g"  # 全局内存限制变量

# ... [省略其他函数定义，保持原有实现] ...

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

    # 检测系统资源
    echo "🔍 检测系统资源..."
    free_mem=$(free -m | awk '/Mem/{print $4}')
    cpu_cores=$(nproc)
    echo " - 可用内存: ${free_mem}MB (最少建议2000MB)"
    echo " - CPU核心: $cpu_cores"
    
    # 优化轮换脚本（全面加固）
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

log "🚀 开始ID轮换..."
resource_check || exit 1

# 检查配置状态文件
[[ ! -f "$CONFIG" ]] && log_failure "配置文件不存在" && exit 1
[[ ! -f "$STATE" ]] && log_failure "状态文件不存在" && exit 1

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
    
    [[ $REAL_COUNT -lt 2 ]] && {
        log_failure "$INSTANCE: 有效ID少于2个 (需添加)"
        continue
    }
    
    NEXT_INDEX=$(get_next_index "$CURRENT_INDEX" "$REAL_COUNT")
    NEW_ID="${REAL_IDS[$NEXT_INDEX]}"
    log "🔄 准备切换为ID[${NEXT_INDEX}]: ${NEW_ID:0:6}****"
    
    # 获取原始内存限制
    ORIGINAL_MEM=$(fetch_original_mem_limit "$INSTANCE")
    log " - 内存限制: $ORIGINAL_MEM"
    
    # 停止现有容器
    log " - 停止容器..."
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
    touch "$LOG_FILE" && chmod 644 "$LOG_FILE"
    
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
    start_time=$(date +%s)
    if eval $DOCKER_CMD; then
        log "   - 容器已启动"
        
        # 状态验证
        log "   - 验证容器状态..."
        sleep 5
        if docker ps --filter "name=$INSTANCE" | grep -q 'Up'; then
            log "   - 状态验证成功"
            
            # 更新状态
            log "   - 更新状态文件..."
            if jq ".\"$INSTANCE\" = $NEXT_INDEX" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; then
                log "✅ $INSTANCE: 轮换成功! 用时: $(($(date +%s)-start_time))秒"
            else
                log_failure "   - 更新状态文件失败!"
            fi
        else
            log_failure "   - 容器启动失败"
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

    # 添加系统监控脚本
    cat > /usr/local/bin/nexus-monitor <<'EOM'
#!/bin/bash
# 监控自动轮换脚本的健康状态
LOG_FILE="/var/log/nexus/nexus-rotate.log"
FAILURE_FILE="/var/log/nexus/rotation-failure.log"
FAILURE_THRESHOLD=3  # 连续失败次数阈值

function send_alert() {
    echo "⚠️ [$HOSTNAME] Nexus轮换系统报警: $1" > .alert_msg
    # 实际环境中替换为您的报警发送逻辑
    # 例如: telegram-send "$(cat .alert_msg)" || curl -X POST...
    echo "🔔 发送报警: $1"
}

# 检查最近的轮换记录
if [[ ! -f "$LOG_FILE" ]]; then
    send_alert "轮换日志不存在"
    exit 1
fi

# 检查故障文件
if [[ -s "$FAILURE_FILE" ]]; then
    failures=$(tail -n 3 "$FAILURE_FILE")
    send_alert "发现错误:\n$failures"
    # 清空故障文件
    > "$FAILURE_FILE"
fi

# 检查最近成功的轮换
last_success=$(grep -l "本次轮换完成" "$LOG_FILE" | xargs ls -lt | head -1)
if [[ -z "$last_success" ]]; then
    send_alert "未找到成功的轮换记录"
    exit 1
fi

# 检查日志更新时间
log_age=$(($(date +%s) - $(date -r "$LOG_FILE" +%s)))
if [[ $log_age -gt 10800 ]]; then  # 3小时
    send_alert "轮换日志已超过3小时未更新"
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
    fi

    echo ""
    echo "✅ ID自动轮换系统部署完成！"
    echo "================================"
    echo "1. 手动测试命令:"
    echo "   /root/nexus-rotate.sh"
    echo "   tail -f $ROTATE_LOG"
    echo ""
    echo "2. 配置监控:"
    echo "   - 自动监控: cron每30分钟检查"
    echo "   - 故障记录: $FAILURE_FILE"
    echo ""
    echo "3. 配置文件:"
    echo "   - 轮换配置: $config_file"
    echo "   - 状态文件: $state_file"
    echo ""
    echo "4. 诊断工具:"
    echo "   - 容器状态: docker ps -a | grep nexus-node"
    echo "   - 系统资源: free -h && df -h /"
    echo ""
    echo "5. 报警设置:"
    echo "   编辑 /usr/local/bin/nexus-monitor 配置实际报警方式"
    echo "================================"
    return 0
}

# ... [省略菜单和其他函数定义，保持原有实现] ...

# 启动菜单
show_menu
