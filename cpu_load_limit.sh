#!/bin/bash

# ======== 可选参数 ========
TARGET_CPU_PERCENT=${1:-20}     # 目标 CPU 占用率（百分比），默认 20%
DURATION=${2:-60}               # 压测持续时间（秒），默认 60 秒
THREADS=${3:-auto}              # 压力线程数（默认自动推荐）
NICE_LEVEL=${4:-19}             # nice 优先级（-20 到 19，数值越高优先级越低），默认 19

GROUP_NAME="cpu_limit_smart"
PERIOD_US=100000                # 默认调度周期（100ms）

# ======== 环境检查 ========
echo "=========================================="
echo "[*] CPU 负载压测工具 - 双重隔离策略"
echo "=========================================="

# 检查 stress-ng
if ! command -v stress-ng &> /dev/null; then
    echo "✗ 请先安装 stress-ng"
    echo "  Ubuntu/Debian: sudo apt install stress-ng"
    echo "  CentOS/RHEL: sudo yum install stress-ng"
    echo "  macOS: brew install stress-ng"
    exit 1
fi

# 检查 sudo 权限
if ! sudo -n true 2>/dev/null; then
    echo "✗ 需要 sudo 权限来配置 cgroup"
    echo "  请运行: sudo $0 $@"
    exit 1
fi

# 检查 ionice 是否可用（Linux 系统）
IONICE_AVAILABLE=false
if command -v ionice &> /dev/null && [[ "$(uname)" == "Linux" ]]; then
    IONICE_AVAILABLE=true
fi

# 检测 cgroup 类型
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    CGROUP_TYPE="v2"
    CGROUP_ROOT="/sys/fs/cgroup"
elif [[ -d /sys/fs/cgroup/cpu ]]; then
    CGROUP_TYPE="v1"
    CGROUP_ROOT="/sys/fs/cgroup/cpu"
else
    echo "✗ 未检测到可用的 cgroup 系统"
    exit 1
fi

echo "[*] 检测到 cgroup $CGROUP_TYPE"

# ======== 自动检测核心数和推荐线程数 ========
CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "1")

if [[ "$THREADS" == "auto" ]]; then
    # 根据目标 CPU 使用率智能计算线程数
    RECOMMENDED_THREADS=$(( CPU_CORES * TARGET_CPU_PERCENT / 100 ))
    THREADS=$(( RECOMMENDED_THREADS > 0 ? RECOMMENDED_THREADS : 1 ))
    
    # 确保线程数不超过核心数的 1.5 倍（避免过度竞争）
    MAX_THREADS=$(( CPU_CORES * 3 / 2 ))
    if [[ $THREADS -gt $MAX_THREADS ]]; then
        THREADS=$MAX_THREADS
    fi
fi

echo "[*] 系统逻辑核心数: $CPU_CORES"
echo "[*] 使用线程数: $THREADS"
echo "[*] 目标 CPU 使用率: ${TARGET_CPU_PERCENT}%"
echo "[*] 压测时长: ${DURATION}s"
echo "[*] 隔离策略: cgroup ($CGROUP_TYPE) 硬限制 + nice/ionice 软优先级"
echo "[*] Nice 优先级: $NICE_LEVEL"
if [[ "$IONICE_AVAILABLE" == "true" ]]; then
    echo "[*] I/O 调度: Idle 类别"
fi

# ======== 清理函数 ========
cleanup() {
    echo ""
    echo "[*] 正在清理资源..."
    
    # 停止 stress-ng 进程
    if [[ -n "$STRESS_PID" ]]; then
        kill $STRESS_PID 2>/dev/null || true
        wait $STRESS_PID 2>/dev/null || true
    fi
    
    # 停止监控进程
    if [[ -n "$MONITOR_PID" ]]; then
        kill $MONITOR_PID 2>/dev/null || true
    fi
    
    # 清理 cgroup
    if [[ -n "$CGROUP_PATH" && -d "$CGROUP_PATH" ]]; then
        echo "[*] 清理 cgroup: $CGROUP_PATH"
        sudo rmdir "$CGROUP_PATH" 2>/dev/null || true
    fi
    
    echo "[✓] 清理完成"
}

# 设置信号处理
trap cleanup EXIT INT TERM

# ======== 配置 cgroup ========
CGROUP_PATH="$CGROUP_ROOT/$GROUP_NAME"

echo "[*] 创建 cgroup: $CGROUP_PATH"
sudo mkdir -p "$CGROUP_PATH"

if [[ "$CGROUP_TYPE" == "v2" ]]; then
    # cgroup v2 配置
    QUOTA_US=$(( TARGET_CPU_PERCENT * PERIOD_US / 100 ))
    echo "[*] 配置 cgroup v2 CPU 限制: ${QUOTA_US}μs / ${PERIOD_US}μs (${TARGET_CPU_PERCENT}%)"
    echo "$QUOTA_US $PERIOD_US" | sudo tee "$CGROUP_PATH/cpu.max" > /dev/null
    
elif [[ "$CGROUP_TYPE" == "v1" ]]; then
    # cgroup v1 配置
    QUOTA_US=$(( TARGET_CPU_PERCENT * PERIOD_US / 100 ))
    echo "[*] 配置 cgroup v1 CPU 限制: ${QUOTA_US}μs / ${PERIOD_US}μs (${TARGET_CPU_PERCENT}%)"
    echo "$PERIOD_US" | sudo tee "$CGROUP_PATH/cpu.cfs_period_us" > /dev/null
    echo "$QUOTA_US"  | sudo tee "$CGROUP_PATH/cpu.cfs_quota_us" > /dev/null
fi

# ======== 构建 stress-ng 命令 ========
STRESS_CMD="stress-ng --cpu $THREADS --cpu-method matrixprod --timeout ${DURATION}s --metrics-brief"

# 添加 nice 和 ionice
PRIORITY_CMD="nice -n $NICE_LEVEL"
if [[ "$IONICE_AVAILABLE" == "true" ]]; then
    PRIORITY_CMD="$PRIORITY_CMD ionice -c 3"  # Idle I/O 调度类别
fi

FINAL_CMD="$PRIORITY_CMD $STRESS_CMD"

echo "=========================================="
echo "[*] 执行命令: $FINAL_CMD"
echo "[*] 开始压测..."
echo "=========================================="

# ======== 启动 stress-ng ========
eval "$FINAL_CMD" &
STRESS_PID=$!

# ======== 将进程加入 cgroup ========
sleep 0.5  # 等待进程完全启动

if [[ "$CGROUP_TYPE" == "v2" ]]; then
    echo "$STRESS_PID" | sudo tee "$CGROUP_PATH/cgroup.procs" > /dev/null
elif [[ "$CGROUP_TYPE" == "v1" ]]; then
    echo "$STRESS_PID" | sudo tee "$CGROUP_PATH/tasks" > /dev/null
fi

echo "[✓] stress-ng 进程 ($STRESS_PID) 已加入 cgroup"

# ======== 实时监控函数 ========
monitor_cpu() {
    local count=0
    local max_samples=20
    
    echo "[*] 开始监控 CPU 使用情况..."
    
    while kill -0 $STRESS_PID 2>/dev/null && [[ $count -lt $max_samples ]]; do
        if command -v top &> /dev/null; then
            # 获取 stress-ng 进程的 CPU 使用率
            if [[ "$(uname)" == "Darwin" ]]; then
                # macOS
                CPU_USAGE=$(top -pid $STRESS_PID -l 1 -stats pid,cpu 2>/dev/null | tail -1 | awk '{print $2}' | sed 's/%//')
            else
                # Linux
                CPU_USAGE=$(top -p $STRESS_PID -n 1 -b 2>/dev/null | tail -1 | awk '{print $9}')
            fi
            
            if [[ -n "$CPU_USAGE" && "$CPU_USAGE" != "CPU" && "$CPU_USAGE" != "0.0" ]]; then
                echo "[$(date '+%H:%M:%S')] stress-ng CPU: ${CPU_USAGE}% | 目标限制: ${TARGET_CPU_PERCENT}%"
            fi
        fi
        
        sleep 3
        ((count++))
    done
}

# 启动监控（后台运行）
monitor_cpu &
MONITOR_PID=$!

# ======== 等待压测完成 ========
wait $STRESS_PID
STRESS_EXIT_CODE=$?

echo "=========================================="
if [[ $STRESS_EXIT_CODE -eq 0 ]]; then
    echo "[✓] 压测成功完成"
else
    echo "[✗] 压测异常退出，退出码: $STRESS_EXIT_CODE"
fi

# ======== 显示统计信息 ========
if [[ "$CGROUP_TYPE" == "v1" && -f "$CGROUP_PATH/cpuacct.usage" ]]; then
    TOTAL_CPU_TIME=$(cat "$CGROUP_PATH/cpuacct.usage" 2>/dev/null)
    if [[ -n "$TOTAL_CPU_TIME" ]]; then
        TOTAL_CPU_TIME_SEC=$(( TOTAL_CPU_TIME / 1000000000 ))
        echo "[*] cgroup 统计: 总 CPU 时间 ${TOTAL_CPU_TIME_SEC}s"
    fi
fi

echo "=========================================="

# ======== 使用说明 ========
cat << 'EOF'

双重隔离策略说明：
├── cgroup 硬限制: 内核级 CPU 配额控制，绝对不会超过设定值
├── nice 软优先级: 进程调度优先级，主动让出 CPU 时间片
└── ionice I/O优先级: 降低磁盘访问优先级（Linux）

使用方法：
  sudo ./cpu_load_limit.sh [CPU%] [时长s] [线程数] [nice值]
  
参数说明：
  - CPU%: 1-100，cgroup 硬限制上限
  - 时长: 压测持续时间（秒）
  - 线程数: 'auto' 或具体数字
  - nice值: -20到19，19为最低优先级
  
示例：
  sudo ./cpu_load_limit.sh 30 120 auto 19   # 30%限制，120秒，最低优先级
  sudo ./cpu_load_limit.sh 50 60 4 15       # 50%限制，60秒，4线程

EOF
