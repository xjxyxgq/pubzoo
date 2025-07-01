#!/bin/bash

# GFS目录增量统计和容量预测脚本
# 用法: ./gfs_usage_monitor.sh <gfs_mount_point>

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置区域 - 需要监控的活跃目录列表
# 请根据实际情况修改这些目录路径（相对于GFS挂载点的路径）
ACTIVE_DIRS=(
    "project_data"
    "logs"
    "backups"
    "temp_files"
    "user_uploads"
)

# 函数：显示使用方法
show_usage() {
    echo "用法: $0 <gfs_mount_point>"
    echo "示例: $0 /mnt/gfs"
    echo ""
    echo "请确保在脚本中配置了正确的活跃目录列表"
    exit 1
}

# 函数：检查目录是否存在
check_directory() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo -e "${RED}错误: 目录 $dir 不存在${NC}"
        return 1
    fi
    return 0
}

# 函数：将字节转换为人类可读格式
bytes_to_human() {
    local bytes=$1
    if [ $bytes -eq 0 ]; then
        echo "0B"
        return
    fi
    
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    local size=$bytes
    
    while [ $size -gt 1024 ] && [ $unit -lt 4 ]; do
        size=$((size / 1024))
        unit=$((unit + 1))
    done
    
    echo "${size}${units[$unit]}"
}

# 函数：将人类可读格式转换为字节
human_to_bytes() {
    local size_str="$1"
    local size=$(echo "$size_str" | grep -o '[0-9.]*')
    local unit=$(echo "$size_str" | grep -o '[A-Z]*$')
    
    case "$unit" in
        "K"|"KB") echo $(echo "$size * 1024" | bc -l | cut -d. -f1) ;;
        "M"|"MB") echo $(echo "$size * 1024 * 1024" | bc -l | cut -d. -f1) ;;
        "G"|"GB") echo $(echo "$size * 1024 * 1024 * 1024" | bc -l | cut -d. -f1) ;;
        "T"|"TB") echo $(echo "$size * 1024 * 1024 * 1024 * 1024" | bc -l | cut -d. -f1) ;;
        *) echo $(echo "$size" | cut -d. -f1) ;;
    esac
}

# 函数：获取目录大小（字节）
get_dir_size_bytes() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sb "$dir" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

# 函数：获取指定时间范围内修改文件的总大小
get_modified_size() {
    local dir="$1"
    local days="$2"
    
    if [ ! -d "$dir" ]; then
        echo "0"
        return
    fi
    
    # 查找指定天数内修改的文件并统计大小
    local total_size=0
    while IFS= read -r -d '' file; do
        if [ -f "$file" ]; then
            local file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
            total_size=$((total_size + file_size))
        fi
    done < <(find "$dir" -type f -mtime -"$days" -print0 2>/dev/null)
    
    echo "$total_size"
}

# 函数：生成目录维度报告
generate_directory_report() {
    local gfs_path="$1"
    
    echo -e "${BLUE}=== 目录维度报告 ===${NC}"
    echo ""
    printf "%-30s %-12s %-12s %-12s\n" "目录名称" "当前容量" "日增量" "月增量"
    printf "%-30s %-12s %-12s %-12s\n" "$(printf '%0.1s' -{1..30})" "$(printf '%0.1s' -{1..12})" "$(printf '%0.1s' -{1..12})" "$(printf '%0.1s' -{1..12})"
    
    local total_current=0
    local total_daily=0
    local total_monthly=0
    
    for dir_name in "${ACTIVE_DIRS[@]}"; do
        local full_path="$gfs_path/$dir_name"
        
        if [ -d "$full_path" ]; then
            echo -e "${GREEN}正在处理目录: $dir_name${NC}" >&2
            
            # 获取当前容量
            local current_bytes=$(get_dir_size_bytes "$full_path")
            local current_human=$(bytes_to_human $current_bytes)
            
            # 获取日增量（过去1天）
            local daily_bytes=$(get_modified_size "$full_path" 1)
            local daily_human=$(bytes_to_human $daily_bytes)
            
            # 获取月增量（过去30天）
            local monthly_bytes=$(get_modified_size "$full_path" 30)
            local monthly_human=$(bytes_to_human $monthly_bytes)
            
            printf "%-30s %-12s %-12s %-12s\n" "$dir_name" "$current_human" "$daily_human" "$monthly_human"
            
            total_current=$((total_current + current_bytes))
            total_daily=$((total_daily + daily_bytes))
            total_monthly=$((total_monthly + monthly_bytes))
        else
            printf "%-30s %-12s %-12s %-12s\n" "$dir_name" "目录不存在" "-" "-"
        fi
    done
    
    echo ""
    printf "%-30s %-12s %-12s %-12s\n" "$(printf '%0.1s' -{1..30})" "$(printf '%0.1s' -{1..12})" "$(printf '%0.1s' -{1..12})" "$(printf '%0.1s' -{1..12})"
    printf "%-30s %-12s %-12s %-12s\n" "总计" "$(bytes_to_human $total_current)" "$(bytes_to_human $total_daily)" "$(bytes_to_human $total_monthly)"
    
    # 返回总计数据供后续使用
    echo "$total_current:$total_daily:$total_monthly"
}

# 函数：生成TOP10目录报告
generate_top10_dirs() {
    local gfs_path="$1"
    
    echo -e "${YELLOW}TOP10 最大目录:${NC}"
    echo ""
    
    # 获取所有子目录并按大小排序
    local temp_file=$(mktemp)
    
    for dir_name in "${ACTIVE_DIRS[@]}"; do
        local full_path="$gfs_path/$dir_name"
        if [ -d "$full_path" ]; then
            local size_bytes=$(get_dir_size_bytes "$full_path")
            echo "$size_bytes:$dir_name" >> "$temp_file"
        fi
    done
    
    # 排序并显示TOP10
    sort -nr "$temp_file" | head -10 | while IFS=: read -r size_bytes dir_name; do
        local size_human=$(bytes_to_human $size_bytes)
        printf "%-30s %s\n" "$dir_name" "$size_human"
    done
    
    rm -f "$temp_file"
}

# 函数：生成总容量维度报告
generate_total_report() {
    local gfs_path="$1"
    local totals="$2"
    
    echo ""
    echo -e "${BLUE}=== 总容量维度报告 ===${NC}"
    echo ""
    
    # 显示TOP10目录
    generate_top10_dirs "$gfs_path"
    echo ""
    
    # 解析总计数据
    IFS=':' read -r total_current total_daily total_monthly <<< "$totals"
    
    # 获取文件系统信息
    local fs_info=$(df -B1 "$gfs_path" | tail -1)
    local fs_total=$(echo "$fs_info" | awk '{print $2}')
    local fs_used=$(echo "$fs_info" | awk '{print $3}')
    local fs_available=$(echo "$fs_info" | awk '{print $4}')
    
    echo -e "${YELLOW}文件系统容量信息:${NC}"
    printf "%-15s %s\n" "总容量:" "$(bytes_to_human $fs_total)"
    printf "%-15s %s\n" "已使用:" "$(bytes_to_human $fs_used)"
    printf "%-15s %s\n" "可用空间:" "$(bytes_to_human $fs_available)"
    echo ""
    
    echo -e "${YELLOW}监控目录增量信息:${NC}"
    printf "%-15s %s\n" "监控总容量:" "$(bytes_to_human $total_current)"
    printf "%-15s %s\n" "总日增量:" "$(bytes_to_human $total_daily)"
    printf "%-15s %s\n" "总月增量:" "$(bytes_to_human $total_monthly)"
    echo ""
    
    # 计算预计可用时长
    echo -e "${YELLOW}容量预测:${NC}"
    if [ $total_daily -gt 0 ]; then
        local days_remaining=$((fs_available / total_daily))
        printf "%-15s %d 天\n" "按日增量预计:" "$days_remaining"
        
        local years=$((days_remaining / 365))
        local remaining_days=$((days_remaining % 365))
        if [ $years -gt 0 ]; then
            printf "%-15s %d 年 %d 天\n" "" "$years" "$remaining_days"
        fi
    else
        printf "%-15s %s\n" "按日增量预计:" "无增量或负增长"
    fi
    
    if [ $total_monthly -gt 0 ]; then
        local monthly_avg=$((total_monthly / 30))
        local days_remaining_monthly=$((fs_available / monthly_avg))
        printf "%-15s %d 天\n" "按月均增量预计:" "$days_remaining_monthly"
    else
        printf "%-15s %s\n" "按月均增量预计:" "无增量或负增长"
    fi
}

# 主函数
main() {
    echo -e "${GREEN}GFS目录增量统计和容量预测工具${NC}"
    echo "=================================================="
    echo ""
    
    # 检查参数
    if [ $# -ne 1 ]; then
        show_usage
    fi
    
    local gfs_path="$1"
    
    # 检查GFS挂载点是否存在
    if ! check_directory "$gfs_path"; then
        exit 1
    fi
    
    # 检查必要的命令是否存在
    for cmd in du find df stat bc; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}错误: 命令 '$cmd' 未找到，请确保已安装${NC}"
            exit 1
        fi
    done
    
    echo -e "${GREEN}开始分析GFS目录: $gfs_path${NC}"
    echo "监控的活跃目录列表:"
    printf "%s\n" "${ACTIVE_DIRS[@]}" | sed 's/^/  - /'
    echo ""
    
    # 生成目录维度报告
    local totals=$(generate_directory_report "$gfs_path" 2>/dev/null)
    
    # 生成总容量维度报告
    generate_total_report "$gfs_path" "$totals"
    
    echo ""
    echo -e "${GREEN}分析完成！${NC}"
}

# 运行主函数
main "$@" 