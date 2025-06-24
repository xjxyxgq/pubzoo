#!/bin/bash

# ======== 可选参数 ========
TARGET_CPU_PERCENT=${1:-30}     # 目标 CPU 占用率（百分比），默认 30%
DURATION=${2:-300}               # 压测持续时间（秒），默认 300 秒
THREADS=${3:-auto}              # 压力线程数（默认自动推荐）
NICE_LEVEL=${4:-19}             # nice 优先级（-20 到 19，数值越高优先级越低），默认 19
DISABLE_CGROUP=${5:-false}      # 是否禁用 cgroup（调试用），默认 false
CUSTOM_PERIOD_MS=${6:-auto}     # 自定义调度周期（毫秒），auto=架构自适应

GROUP_NAME="cpu_limit_smart"

# 调度周期配置
if [[ "$CUSTOM_PERIOD_MS" != "auto" ]]; then
    # 用户自定义周期
    PERIOD_US=$(( CUSTOM_PERIOD_MS * 1000 ))
    echo "[*] 使用自定义调度周期: ${CUSTOM_PERIOD_MS}ms (${PERIOD_US}μs)"
elif [[ "$ARCH" =~ ^(aarch64|arm64|armv7l|armv8)$ ]]; then
    # ARM 架构调度周期优化
    PERIOD_US=1000000           # ARM使用1000ms周期，避免调度粒度问题
    echo "[*] ARM 架构检测：使用扩大的调度周期 (1000ms) 以适应低功耗调度器"
    echo "    └─ 这解决了ARM系统调度粒度过大导致的quota无法分配问题"
else
    # x86使用标准100ms周期
    PERIOD_US=100000
    echo "[*] x86 架构：使用标准调度周期 (100ms)"
fi

# ======== 环境检查 ========
echo "=========================================="
echo "[*] CPU 负载压测工具 - 双重隔离策略"
echo "=========================================="

# 检测系统架构
ARCH=$(uname -m)
echo "[*] 系统架构: $ARCH"

# 详细系统信息诊断
echo "[*] 系统详情诊断:"
echo "    ├─ 内核版本: $(uname -r)"
echo "    ├─ 发行版: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo "Unknown")"
echo "    ├─ CPU 型号: $(cat /proc/cpuinfo 2>/dev/null | grep 'model name' | head -1 | cut -d':' -f2 | xargs || echo "Unknown")"
echo "    └─ CPU 拓扑: $(lscpu 2>/dev/null | grep 'Thread(s) per core' | cut -d':' -f2 | xargs || echo "Unknown")"

# 检查 stress-ng
if ! command -v stress-ng &> /dev/null; then
    echo "✗ 请先安装 stress-ng"
    echo "  Ubuntu/Debian: sudo apt install stress-ng"
    echo "  CentOS/RHEL: sudo yum install stress-ng"
    echo "  macOS: brew install stress-ng"
    exit 1
fi

# 显示 stress-ng 版本信息
STRESS_VERSION=$(stress-ng --version 2>/dev/null | head -1 || echo "Unknown")
echo "[*] stress-ng 版本: $STRESS_VERSION"

# cgroup 功能检查
echo "[*] cgroup 功能诊断:"
if [[ -f /proc/cgroups ]]; then
    echo "    ├─ 可用控制器:"
    cat /proc/cgroups | grep -E "(cpu|cpuset|memory)" | while read line; do
        echo "        └─ $line"
    done
else
    echo "    ├─ /proc/cgroups 不存在"
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
CGROUP_ENABLED=true
if [[ "$DISABLE_CGROUP" == "true" ]]; then
    echo "[*] cgroup 功能已禁用（调试模式）"
    CGROUP_ENABLED=false
elif [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    CGROUP_TYPE="v2"
    CGROUP_ROOT="/sys/fs/cgroup"
    echo "[*] 检测到 cgroup $CGROUP_TYPE"
elif [[ -d /sys/fs/cgroup/cpu ]]; then
    CGROUP_TYPE="v1"
    CGROUP_ROOT="/sys/fs/cgroup/cpu"
    echo "[*] 检测到 cgroup $CGROUP_TYPE"
else
    echo "[!] 警告: 未检测到可用的 cgroup 系统，将仅使用 nice/ionice"
    CGROUP_ENABLED=false
fi

# ======== 自动检测核心数和推荐线程数 ========
CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "1")

if [[ "$THREADS" == "auto" ]]; then
    # 通用线程数计算策略
    RECOMMENDED_THREADS=$(( CPU_CORES * TARGET_CPU_PERCENT / 100 ))
    THREADS=$(( RECOMMENDED_THREADS > 0 ? RECOMMENDED_THREADS : 1 ))
    
    # 确保线程数不超过核心数的 1.5 倍（避免过度竞争）
    MAX_THREADS=$(( CPU_CORES * 3 / 2 ))
    if [[ $THREADS -gt $MAX_THREADS ]]; then
        THREADS=$MAX_THREADS
    fi
    
    echo "[*] 自动计算线程数：${THREADS}个 (基于${CPU_CORES}核心，目标${TARGET_CPU_PERCENT}%)"
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
if [[ "$CGROUP_ENABLED" == "true" ]]; then
    CGROUP_PATH="$CGROUP_ROOT/$GROUP_NAME"
    
    echo "[*] 创建 cgroup: $CGROUP_PATH"
    sudo mkdir -p "$CGROUP_PATH"
else
    echo "[*] 跳过 cgroup 配置，仅使用 nice/ionice 限制"
fi

if [[ "$CGROUP_ENABLED" == "true" ]]; then
    if [[ "$CGROUP_TYPE" == "v2" ]]; then
        # cgroup v2 配置
        QUOTA_US=$(( TARGET_CPU_PERCENT * PERIOD_US / 100 ))
        echo "[*] 配置 cgroup v2 CPU 限制: ${QUOTA_US}μs / ${PERIOD_US}μs (${TARGET_CPU_PERCENT}%)"
        echo "$QUOTA_US $PERIOD_US" | sudo tee "$CGROUP_PATH/cpu.max" > /dev/null
        
        # 验证配置是否生效
        ACTUAL_CONFIG=$(cat "$CGROUP_PATH/cpu.max" 2>/dev/null)
        echo "[*] 实际 cgroup v2 配置: $ACTUAL_CONFIG"
        
        # 检查是否启用了CPU控制器
        if [[ -f "$CGROUP_ROOT/cgroup.subtree_control" ]]; then
            CONTROLLERS=$(cat "$CGROUP_ROOT/cgroup.subtree_control" 2>/dev/null)
            echo "[*] 根cgroup控制器: $CONTROLLERS"
            if [[ "$CONTROLLERS" != *"cpu"* ]]; then
                echo "cpu" | sudo tee "$CGROUP_ROOT/cgroup.subtree_control" > /dev/null 2>&1 || true
                echo "[*] 尝试启用CPU控制器"
            fi
        fi
        
    elif [[ "$CGROUP_TYPE" == "v1" ]]; then
                # cgroup v1 配置
        QUOTA_US=$(( TARGET_CPU_PERCENT * PERIOD_US / 100 ))
        echo "[*] 配置 cgroup v1 CPU 限制: ${QUOTA_US}μs / ${PERIOD_US}μs (${TARGET_CPU_PERCENT}%)"
        echo "$PERIOD_US" | sudo tee "$CGROUP_PATH/cpu.cfs_period_us" > /dev/null
        echo "$QUOTA_US"  | sudo tee "$CGROUP_PATH/cpu.cfs_quota_us" > /dev/null
        
        # 验证配置是否生效
        ACTUAL_PERIOD=$(cat "$CGROUP_PATH/cpu.cfs_period_us" 2>/dev/null)
        ACTUAL_QUOTA=$(cat "$CGROUP_PATH/cpu.cfs_quota_us" 2>/dev/null)
        echo "[*] 实际 cgroup v1 配置: quota=${ACTUAL_QUOTA}μs, period=${ACTUAL_PERIOD}μs"
        
        # 计算实际百分比进行验证
        if [[ -n "$ACTUAL_QUOTA" && -n "$ACTUAL_PERIOD" && "$ACTUAL_PERIOD" -gt 0 ]]; then
            ACTUAL_PERCENT=$(( ACTUAL_QUOTA * 100 / ACTUAL_PERIOD ))
            echo "[*] 实际限制百分比: ${ACTUAL_PERCENT}%"
            
            if [[ "$ACTUAL_PERCENT" -ne "$TARGET_CPU_PERCENT" ]]; then
                echo "[!] 警告: 实际配置与目标不符！"
            fi
        fi
    fi
fi

# ======== 选择合适的 stress-ng 方法 ========
# ARM 架构优化的 CPU 方法选择
if [[ "$ARCH" =~ ^(aarch64|arm64|armv7l|armv8)$ ]]; then
    # ARM 架构：使用更适合的 CPU 方法
    echo "[*] 测试 ARM 架构兼容的 CPU 方法..."
    
    # 测试可用的方法
    AVAILABLE_METHODS=()
    for method in "ackermann" "correlate" "euler" "fft" "matrixprod" "prime"; do
        if timeout 2s stress-ng --cpu 1 --cpu-method "$method" --timeout 1s --quiet >/dev/null 2>&1; then
            AVAILABLE_METHODS+=("$method")
            echo "  ✓ $method"
        else
            echo "  ✗ $method (不兼容)"
        fi
    done
    
    if [[ ${#AVAILABLE_METHODS[@]} -gt 0 ]]; then
        # 使用第一个可用的方法
        SELECTED_METHOD="${AVAILABLE_METHODS[0]}"
        echo "[*] 选择的 CPU 方法: $SELECTED_METHOD"
    else
        # 回退到默认方法
        SELECTED_METHOD="all"
        echo "[*] 使用默认 CPU 方法: all"
    fi
else
    # x86 架构使用原方法
    SELECTED_METHOD="matrixprod"
    echo "[*] x86 架构使用 CPU 方法: $SELECTED_METHOD"
fi

# ======== 构建 stress-ng 命令 ========
STRESS_CMD="stress-ng --cpu $THREADS --cpu-method $SELECTED_METHOD --timeout ${DURATION}s --metrics-brief --verify"

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
# 使用 SIGSTOP 机制避免启动初期资源失控
echo "[*] 启动 stress-ng 进程（暂停状态）..."
eval "$FINAL_CMD" &
STRESS_PID=$!

# 立即暂停进程，防止资源使用失控
kill -STOP $STRESS_PID
echo "[*] stress-ng 进程 ($STRESS_PID) 已暂停，准备加入 cgroup..."

# ======== 将进程加入 cgroup ========
if [[ "$CGROUP_ENABLED" == "true" ]]; then
    echo "[*] 将进程 $STRESS_PID 加入 cgroup..."
    
    if [[ "$CGROUP_TYPE" == "v2" ]]; then
        echo "$STRESS_PID" | sudo tee "$CGROUP_PATH/cgroup.procs" > /dev/null
        
        # 验证进程是否成功加入
        if grep -q "^$STRESS_PID$" "$CGROUP_PATH/cgroup.procs" 2>/dev/null; then
            echo "[✓] 进程成功加入 cgroup v2"
        else
            echo "[✗] 警告: 进程可能未成功加入 cgroup v2"
        fi
        
    elif [[ "$CGROUP_TYPE" == "v1" ]]; then
        echo "$STRESS_PID" | sudo tee "$CGROUP_PATH/tasks" > /dev/null
        
        # 验证进程是否成功加入
        if grep -q "^$STRESS_PID$" "$CGROUP_PATH/tasks" 2>/dev/null; then
            echo "[✓] 进程成功加入 cgroup v1"
        else
            echo "[✗] 警告: 进程可能未成功加入 cgroup v1"
        fi
    fi
    
    echo "[*] 恢复进程执行，开始应用 cgroup 限制..."
else
    echo "[*] 跳过 cgroup 配置，直接恢复进程执行..."
fi

# 恢复进程执行，现在已受 cgroup 限制（如果启用）
kill -CONT $STRESS_PID
if [[ "$CGROUP_ENABLED" == "true" ]]; then
    echo "[✓] stress-ng 开始受限执行 (cgroup + nice/ionice)"
else
    echo "[✓] stress-ng 开始执行 (仅 nice/ionice)"
fi

# 等待一下让进程完全启动
sleep 2

# 验证子进程也被加入cgroup（stress-ng可能会创建子进程）
if [[ "$CGROUP_ENABLED" == "true" ]]; then
    echo "[*] 检查所有相关进程是否在 cgroup 中..."
    
    # 获取所有 stress-ng 相关进程
    ALL_STRESS_PIDS=$(pgrep -f "stress-ng" | tr '\n' ' ')
    echo "[*] 系统中所有 stress-ng 进程: $ALL_STRESS_PIDS"
    
    if [[ "$CGROUP_TYPE" == "v2" ]]; then
        PROCS_IN_CGROUP=$(cat "$CGROUP_PATH/cgroup.procs" 2>/dev/null)
        PROC_COUNT=$(echo "$PROCS_IN_CGROUP" | wc -l)
        echo "[*] cgroup 中的进程数: $PROC_COUNT"
        echo "[*] cgroup 中的进程列表: $PROCS_IN_CGROUP"
        
        # 将所有 stress-ng 进程加入 cgroup
        for pid in $ALL_STRESS_PIDS; do
            if [[ -n "$pid" ]]; then
                echo "$pid" | sudo tee "$CGROUP_PATH/cgroup.procs" > /dev/null 2>&1
                echo "    └─ 添加进程 $pid 到 cgroup"
            fi
        done
        
    elif [[ "$CGROUP_TYPE" == "v1" ]]; then
        PROCS_IN_CGROUP=$(cat "$CGROUP_PATH/tasks" 2>/dev/null)
        PROC_COUNT=$(echo "$PROCS_IN_CGROUP" | wc -l)
        echo "[*] cgroup 中的进程数: $PROC_COUNT"
        echo "[*] cgroup 中的进程列表: $PROCS_IN_CGROUP"
        
        # 将所有 stress-ng 进程加入 cgroup
        for pid in $ALL_STRESS_PIDS; do
            if [[ -n "$pid" ]]; then
                echo "$pid" | sudo tee "$CGROUP_PATH/tasks" > /dev/null 2>&1
                echo "    └─ 添加进程 $pid 到 cgroup"
            fi
        done
    fi
    
    echo "[*] 重新检查 cgroup 进程数..."
    if [[ "$CGROUP_TYPE" == "v2" ]]; then
        FINAL_COUNT=$(cat "$CGROUP_PATH/cgroup.procs" 2>/dev/null | wc -l)
    elif [[ "$CGROUP_TYPE" == "v1" ]]; then
        FINAL_COUNT=$(cat "$CGROUP_PATH/tasks" 2>/dev/null | wc -l)
    fi
    echo "[*] 最终 cgroup 中的进程数: $FINAL_COUNT"
fi

# ======== 改进的实时监控函数 ========
monitor_cpu() {
    echo "[*] 开始监控 CPU 使用情况..."
    local count=0
    local max_samples=$(( DURATION / 5 ))  # 每5秒监控一次
    
    # 确保至少监控20次
    if [[ $max_samples -lt 20 ]]; then
        max_samples=20
    fi
    
    while [[ $count -lt $max_samples ]]; do
        # 检查进程是否还在运行
        if ! kill -0 $STRESS_PID 2>/dev/null; then
            echo "[*] stress-ng 进程已结束，停止监控"
            break
        fi
        
        # 使用多种方法获取 CPU 使用率
        local cpu_usage=""
        local system_load=""
        
        # 方法1：使用 ps 命令（更可靠）
        if command -v ps &> /dev/null; then
            cpu_usage=$(ps -p $STRESS_PID -o %cpu= 2>/dev/null | awk '{print $1}')
        fi
        
        # 方法2：获取系统整体负载
        if [[ -f /proc/loadavg ]]; then
            system_load=$(cat /proc/loadavg | awk '{print $1}')
        fi
        
        # 方法3：使用 top 作为备选
        if [[ -z "$cpu_usage" ]] && command -v top &> /dev/null; then
            if [[ "$(uname)" == "Darwin" ]]; then
                # macOS
                cpu_usage=$(top -pid $STRESS_PID -l 1 -stats pid,cpu 2>/dev/null | tail -1 | awk '{print $2}' | sed 's/%//')
            else
                # Linux
                cpu_usage=$(top -p $STRESS_PID -n 1 -b 2>/dev/null | tail -1 | awk '{print $9}')
            fi
        fi
        
        # 输出监控信息
        local timestamp=$(date '+%H:%M:%S')
        local output="[$timestamp]"
        
        if [[ -n "$cpu_usage" && "$cpu_usage" != "0" && "$cpu_usage" != "0.0" ]]; then
            output="$output stress-ng CPU: ${cpu_usage}%"
        else
            output="$output stress-ng CPU: 检测中..."
        fi
        
        if [[ -n "$system_load" ]]; then
            output="$output | 系统负载: ${system_load}"
        fi
        
        output="$output | 目标限制: ${TARGET_CPU_PERCENT}%"
        
        echo "$output"
        
        # cgroup 使用统计（每10次显示一次）
        if [[ $(( count % 10 )) -eq 0 ]] && [[ "$CGROUP_TYPE" == "v1" ]] && [[ -f "$CGROUP_PATH/cpuacct.usage" ]]; then
            local total_usage=$(cat "$CGROUP_PATH/cpuacct.usage" 2>/dev/null)
            if [[ -n "$total_usage" ]]; then
                local usage_sec=$(( total_usage / 1000000000 ))
                echo "    └─ cgroup 累计 CPU 时间: ${usage_sec}s"
            fi
        fi
        
        sleep 5
        ((count++))
    done
    
    echo "[*] 监控结束"
}

# 启动监控（前台运行，确保实时输出）
monitor_cpu &
MONITOR_PID=$!

# ======== 等待压测完成 ========
wait $STRESS_PID
STRESS_EXIT_CODE=$?

# 停止监控
kill $MONITOR_PID 2>/dev/null || true
wait $MONITOR_PID 2>/dev/null || true

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
        EXPECTED_MAX_TIME=$(( TARGET_CPU_PERCENT * DURATION / 100 ))
        echo "[*] cgroup 统计信息:"
        echo "    ├─ 总 CPU 时间: ${TOTAL_CPU_TIME_SEC}s"
        echo "    ├─ 预期最大时间: ${EXPECTED_MAX_TIME}s (${TARGET_CPU_PERCENT}% × ${DURATION}s)"
        echo "    └─ 限制效果: $( [[ $TOTAL_CPU_TIME_SEC -le $EXPECTED_MAX_TIME ]] && echo "✓ 有效" || echo "✗ 可能超限" )"
    fi
fi

echo "=========================================="

# ======== 使用说明 ========
cat << 'EOF'

双重隔离策略说明：
├── cgroup 硬限制: 内核级 CPU 配额控制，绝对不会超过设定值
├── nice 软优先级: 进程调度优先级，主动让出 CPU 时间片
└── ionice I/O优先级: 降低磁盘访问优先级（Linux）

ARM 架构优化：
├── 自动检测架构并选择合适的 stress-ng 方法
├── 优化线程数计算策略
└── 兼容性测试确保稳定运行

使用方法：
  sudo ./cpu_load_limit.sh [CPU%] [时长s] [线程数] [nice值] [禁用cgroup] [调度周期ms]
  
参数说明：
  - CPU%: 1-100，cgroup 硬限制上限
  - 时长: 压测持续时间（秒）
  - 线程数: 'auto' 或具体数字
  - nice值: -20到19，19为最低优先级
  - 禁用cgroup: true/false，默认false（调试用）
  - 调度周期ms: auto/数字，auto=架构自适应（ARM=1000ms, x86=100ms）
  
示例：
  sudo ./cpu_load_limit.sh 30 120 auto 19              # 30%限制，120秒，最低优先级
  sudo ./cpu_load_limit.sh 50 60 4 15                  # 50%限制，60秒，4线程  
  sudo ./cpu_load_limit.sh 50 60 auto 19 true          # 禁用cgroup，仅使用nice/ionice
  sudo ./cpu_load_limit.sh 30 300 auto 19 false 2000  # 使用2000ms调度周期（适合低功耗ARM）

EOF
