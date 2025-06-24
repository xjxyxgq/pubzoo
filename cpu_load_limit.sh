#!/bin/bash

# ======== 可选参数 ========
TARGET_CPU_PERCENT=${1:-20}     # 目标 CPU 占用率（百分比），默认 20%
DURATION=${2:-60}               # 压测持续时间（秒），默认 60 秒
THREADS=${3:-auto}              # 压力线程数（默认自动推荐）

GROUP_NAME="cpu_limit_smart"
PERIOD_US=100000                # 默认调度周期

# ======== 环境检查 ========
if ! command -v stress-ng &> /dev/null; then
    echo "✗ 请先安装 stress-ng"
    exit 1
fi

CGROUP_TYPE=$(stat -fc %T /sys/fs/cgroup)
echo "[*] 检测到 cgroup 类型: $CGROUP_TYPE"

# ======== 自动检测核心数和推荐线程数 ========
CPU_CORES=$(nproc)

if [[ "$THREADS" == "auto" ]]; then
    RECOMMENDED_THREADS=$(( CPU_CORES * TARGET_CPU_PERCENT / 100 ))
    THREADS=$(( RECOMMENDED_THREADS > 0 ? RECOMMENDED_THREADS : 1 ))
fi

echo "[*] 系统逻辑核心数: $CPU_CORES"
echo "[*] 使用线程数: $THREADS"
echo "[*] 目标 CPU 使用率: ${TARGET_CPU_PERCENT}%"
echo "[*] 压测时长: ${DURATION}s"

# ======== cgroup v2 实现 ========
if [[ "$CGROUP_TYPE" == "cgroup2fs" ]]; then
    echo "[*] 使用 cgroup v2 模式"

    CGROUP_PATH="/sys/fs/cgroup/${GROUP_NAME}"
    sudo mkdir -p "$CGROUP_PATH"

    QUOTA_US=$(( TARGET_CPU_PERCENT * 1000 ))  # cpu.max 以微秒为单位
    echo "$QUOTA_US $PERIOD_US" | sudo tee "$CGROUP_PATH/cpu.max" > /dev/null

    echo $$ | sudo tee "$CGROUP_PATH/cgroup.procs" > /dev/null

    stress-ng --cpu "$THREADS" --cpu-method matrixprod --timeout "${DURATION}s" &
    STRESS_PID=$!
    echo "$STRESS_PID" | sudo tee "$CGROUP_PATH/cgroup.procs" > /dev/null

    wait "$STRESS_PID"
    echo "[✓] 压测完成"
    sudo rmdir "$CGROUP_PATH"

# ======== cgroup v1 实现 ========
elif [[ -d "/sys/fs/cgroup/cpu" ]]; then
    echo "[*] 使用 cgroup v1 模式"

    CGROUP_PATH="/sys/fs/cgroup/cpu/${GROUP_NAME}"
    QUOTA_US=$(( TARGET_CPU_PERCENT * PERIOD_US / 100 ))

    sudo mkdir -p "$CGROUP_PATH"
    echo "$PERIOD_US" | sudo tee "$CGROUP_PATH/cpu.cfs_period_us" > /dev/null
    echo "$QUOTA_US"  | sudo tee "$CGROUP_PATH/cpu.cfs_quota_us" > /dev/null

    stress-ng --cpu "$THREADS" --cpu-method matrixprod --timeout "${DURATION}s" &
    STRESS_PID=$!
    echo "$STRESS_PID" | sudo tee "$CGROUP_PATH/tasks" > /dev/null

    wait "$STRESS_PID"
    echo "[✓] 压测完成"
    sudo rmdir "$CGROUP_PATH"

else
    echo "✗ 不支持的 cgroup 类型：$CGROUP_TYPE"
    exit 1
fi
