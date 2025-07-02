#!/bin/bash

# GFS目录增量统计和容量预测脚本
# 用法: ./gfs_usage_monitor.sh <gfs_mount_point>

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 调试模式开关（设置为1启用调试输出）
DEBUG_MODE=0

# 配置区域 - 需要监控的活跃目录列表
# 请根据实际情况修改这些目录路径（相对于GFS挂载点的路径）
ACTIVE_DIRS=(
    "pubzoo"
    "cmpool_cursor"
    "backups"
    "temp_files"
    "user_uploads"
)

# 检测操作系统类型
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)

# 函数：显示使用方法
show_usage() {
    echo "用法: $0 [选项] <gfs_mount_point>"
    echo "示例: $0 /mnt/gfs"
    echo "      $0 --debug /mnt/gfs"
    echo "      $0 --test-increment /mnt/gfs"
    echo ""
    echo "选项:"
    echo "  --debug            启用调试模式，显示详细的处理信息"
    echo "  --test-increment   测试增量统计功能"
    echo "  --help            显示此帮助信息"
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
    local bytes="$1"
    
    # 验证输入是否为数字
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0B"
        return
    fi
    
    if [ "$bytes" -eq 0 ]; then
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

# 函数：获取目录大小（字节）
get_dir_size_bytes() {
    local dir="$1"
    if [ -d "$dir" ]; then
        if [ "$OS_TYPE" = "macos" ]; then
            # macOS使用不同的du参数
            du -s "$dir" 2>/dev/null | awk '{print $1 * 512}' # macOS du默认以512字节块为单位
        else
            du -sb "$dir" 2>/dev/null | cut -f1
        fi
    else
        echo "0"
    fi
}

# 函数：获取文件大小（字节）
get_file_size() {
    local file="$1"
    if [ -f "$file" ]; then
        if [ "$OS_TYPE" = "macos" ]; then
            stat -f%z "$file" 2>/dev/null || echo "0"
        else
            stat -c%s "$file" 2>/dev/null || echo "0"
        fi
    else
        echo "0"
    fi
}

# 函数：获取指定时间范围内修改文件的总大小
get_modified_size() {
    local dir="$1"
    local days="$2"
    
    if [ ! -d "$dir" ]; then
        if [ "$DEBUG_MODE" -eq 1 ]; then
            echo "调试: 目录不存在: $dir" >&2
        fi
        echo "0"
        return
    fi
    
    # 使用更精确的时间计算方法
    local total_size=0
    local file_count=0
    
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "调试: 开始检查目录 $dir，时间范围: $days 天" >&2
    fi
    
    # 方法1：使用 -mtime（推荐用于Linux）
    # 方法2：使用 -newer（更精确的时间比较）
    local temp_file=""
    local find_cmd=""
    
    if [ "$OS_TYPE" = "macos" ]; then
        # macOS 使用 -mtime，但添加更精确的时间计算
        if [ "$days" -eq 1 ]; then
            # 对于1天，使用更精确的时间
            find_cmd="find \"$dir\" -type f -mtime -1 -print0 2>/dev/null"
        else
            find_cmd="find \"$dir\" -type f -mtime -$days -print0 2>/dev/null"
        fi
    else
        # Linux 也使用相同的方法，但可以考虑使用 -newer
        if [ "$days" -eq 1 ]; then
            # 创建一个24小时前的临时文件作为时间参考
            temp_file=$(mktemp)
            if [ "$OS_TYPE" = "macos" ]; then
                touch -t "$(date -v-1d '+%Y%m%d%H%M.%S')" "$temp_file" 2>/dev/null || {
                    # 如果上面的命令失败，使用mtime
                    rm -f "$temp_file"
                    find_cmd="find \"$dir\" -type f -mtime -1 -print0 2>/dev/null"
                }
            else
                touch -d "1 day ago" "$temp_file" 2>/dev/null || {
                    # 如果上面的命令失败，使用mtime
                    rm -f "$temp_file"
                    find_cmd="find \"$dir\" -type f -mtime -1 -print0 2>/dev/null"
                }
            fi
            
            if [ -n "$temp_file" ] && [ -f "$temp_file" ]; then
                find_cmd="find \"$dir\" -type f -newer \"$temp_file\" -print0 2>/dev/null"
            fi
        else
            find_cmd="find \"$dir\" -type f -mtime -$days -print0 2>/dev/null"
        fi
    fi
    
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "调试: 使用命令: $find_cmd" >&2
    fi
    
    # 执行查找并统计大小
    while IFS= read -r -d '' file; do
        if [ -f "$file" ]; then
            local file_size=$(get_file_size "$file")
            if [[ "$file_size" =~ ^[0-9]+$ ]] && [ "$file_size" -gt 0 ]; then
                total_size=$((total_size + file_size))
                file_count=$((file_count + 1))
                
                if [ "$DEBUG_MODE" -eq 1 ] && [ "$file_count" -le 5 ]; then
                    echo "调试: 找到文件，大小: $(bytes_to_human $file_size)" >&2
                fi
            fi
        fi
    done < <(eval "$find_cmd")
    
    # 清理临时文件
    if [ -n "$temp_file" ] && [ -f "$temp_file" ]; then
        rm -f "$temp_file"
    fi
    
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "调试: 目录 $dir 在 $days 天内找到 $file_count 个文件，总大小: $(bytes_to_human $total_size)" >&2
    fi
    
    echo "$total_size"
}

# 函数：获取指定时间范围内修改文件的总大小（备用方法）
get_modified_size_alternative() {
    local dir="$1"
    local days="$2"
    
    if [ ! -d "$dir" ]; then
        echo "0"
        return
    fi
    
    # 使用 stat 命令直接检查文件修改时间
    local total_size=0
    local current_time=$(date +%s)
    local threshold_time=$((current_time - days * 24 * 3600))
    
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "调试: 使用备用方法检查目录 $dir" >&2
        echo "调试: 当前时间戳: $current_time，阈值时间戳: $threshold_time" >&2
    fi
    
    find "$dir" -type f -print0 2>/dev/null | while IFS= read -r -d '' file; do
        if [ -f "$file" ]; then
            local file_mtime=""
            if [ "$OS_TYPE" = "macos" ]; then
                file_mtime=$(stat -f %m "$file" 2>/dev/null)
            else
                file_mtime=$(stat -c %Y "$file" 2>/dev/null)
            fi
            
            if [[ "$file_mtime" =~ ^[0-9]+$ ]] && [ "$file_mtime" -gt "$threshold_time" ]; then
                local file_size=$(get_file_size "$file")
                if [[ "$file_size" =~ ^[0-9]+$ ]] && [ "$file_size" -gt 0 ]; then
                    total_size=$((total_size + file_size))
                fi
            fi
        fi
    done
    
    echo "$total_size"
}

# 函数：获取文件系统信息（字节）
get_filesystem_info() {
    local path="$1"
    
    if [ "$OS_TYPE" = "macos" ]; then
        # macOS版本
        local df_output=$(df -k "$path" | tail -1)
        local total_kb=$(echo "$df_output" | awk '{print $2}')
        local used_kb=$(echo "$df_output" | awk '{print $3}')
        local avail_kb=$(echo "$df_output" | awk '{print $4}')
        
        # 转换为字节
        local total_bytes=$((total_kb * 1024))
        local used_bytes=$((used_kb * 1024))
        local avail_bytes=$((avail_kb * 1024))
        
        echo "$total_bytes:$used_bytes:$avail_bytes"
    else
        # Linux版本
        local df_output=$(df -B1 "$path" | tail -1)
        local total_bytes=$(echo "$df_output" | awk '{print $2}')
        local used_bytes=$(echo "$df_output" | awk '{print $3}')
        local avail_bytes=$(echo "$df_output" | awk '{print $4}')
        
        echo "$total_bytes:$used_bytes:$avail_bytes"
    fi
}

# 函数：生成目录维度报告
generate_directory_report() {
    local gfs_path="$1"
    
    echo -e "${BLUE}=== 目录维度报告 ===${NC}" >&2
    echo "" >&2
    printf "%-30s %-12s %-12s %-12s\n" "目录名称" "当前容量" "日增量" "月增量" >&2
    printf "%-30s %-12s %-12s %-12s\n" "$(printf '%0.1s' -{1..30})" "$(printf '%0.1s' -{1..12})" "$(printf '%0.1s' -{1..12})" "$(printf '%0.1s' -{1..12})" >&2
    
    local total_current=0
    local total_daily=0
    local total_monthly=0
    
    for dir_name in "${ACTIVE_DIRS[@]}"; do
        local full_path="$gfs_path/$dir_name"
        
        if [ -d "$full_path" ]; then
            echo -e "${GREEN}正在处理目录: $dir_name${NC}" >&2
            
            # 获取当前容量
            local current_bytes=$(get_dir_size_bytes "$full_path")
            local current_human=$(bytes_to_human "$current_bytes")
            
            # 获取日增量（过去1天）
            local daily_bytes=$(get_modified_size "$full_path" 1)
            local daily_human=$(bytes_to_human "$daily_bytes")
            
            # 获取月增量（过去30天）
            local monthly_bytes=$(get_modified_size "$full_path" 30)
            local monthly_human=$(bytes_to_human "$monthly_bytes")
            
            if [ "$DEBUG_MODE" -eq 1 ]; then
                echo "调试: 目录 $dir_name - 当前容量: $current_bytes, 日增量: $daily_bytes, 月增量: $monthly_bytes" >&2
            fi
            
            printf "%-30s %-12s %-12s %-12s\n" "$dir_name" "$current_human" "$daily_human" "$monthly_human" >&2
            
            # 安全地累加数值
            if [[ "$current_bytes" =~ ^[0-9]+$ ]]; then
                total_current=$((total_current + current_bytes))
                if [ "$DEBUG_MODE" -eq 1 ]; then
                    echo "调试: 累加当前容量: $current_bytes -> 总计: $total_current" >&2
                fi
            fi
            if [[ "$daily_bytes" =~ ^[0-9]+$ ]]; then
                total_daily=$((total_daily + daily_bytes))
                if [ "$DEBUG_MODE" -eq 1 ]; then
                    echo "调试: 累加日增量: $daily_bytes -> 总计: $total_daily" >&2
                fi
            fi
            if [[ "$monthly_bytes" =~ ^[0-9]+$ ]]; then
                total_monthly=$((total_monthly + monthly_bytes))
                if [ "$DEBUG_MODE" -eq 1 ]; then
                    echo "调试: 累加月增量: $monthly_bytes -> 总计: $total_monthly" >&2
                fi
            fi
        else
            printf "%-30s %-12s %-12s %-12s\n" "$dir_name" "目录不存在" "-" "-" >&2
        fi
    done
    
    echo "" >&2
    printf "%-30s %-12s %-12s %-12s\n" "$(printf '%0.1s' -{1..30})" "$(printf '%0.1s' -{1..12})" "$(printf '%0.1s' -{1..12})" "$(printf '%0.1s' -{1..12})" >&2
    printf "%-30s %-12s %-12s %-12s\n" "总计" "$(bytes_to_human $total_current)" "$(bytes_to_human $total_daily)" "$(bytes_to_human $total_monthly)" >&2
    
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "调试: 最终累计数据 - 当前容量: $total_current, 日增量: $total_daily, 月增量: $total_monthly" >&2
        echo "调试: 返回数据字符串: $total_current:$total_daily:$total_monthly" >&2
    fi
    
    # 返回总计数据供后续使用（只输出到stdout）
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
            if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
                echo "$size_bytes:$dir_name" >> "$temp_file"
            fi
        fi
    done
    
    # 排序并显示TOP10
    if [ -s "$temp_file" ]; then
        sort -nr "$temp_file" | head -10 | while IFS=: read -r size_bytes dir_name; do
            local size_human=$(bytes_to_human "$size_bytes")
            printf "%-30s %s\n" "$dir_name" "$size_human"
        done
    else
        echo "没有找到有效的目录数据"
    fi
    
    rm -f "$temp_file"
}

# 函数：生成总容量维度报告
generate_total_report() {
    local gfs_path="$1"
    local totals="$2"
    
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "调试: generate_total_report 接收到的数据: '$totals'" >&2
    fi
    
    echo ""
    echo -e "${BLUE}=== 总容量维度报告 ===${NC}"
    echo ""
    
    # 显示TOP10目录
    generate_top10_dirs "$gfs_path"
    echo ""
    
    # 解析总计数据
    IFS=':' read -r total_current total_daily total_monthly <<< "$totals"
    
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "调试: 解析后的数据 - 当前: '$total_current', 日增量: '$total_daily', 月增量: '$total_monthly'" >&2
    fi
    
    # 验证数据有效性
    if ! [[ "$total_current" =~ ^[0-9]+$ ]]; then 
        if [ "$DEBUG_MODE" -eq 1 ]; then
            echo "调试: total_current 验证失败: '$total_current'" >&2
        fi
        total_current=0
    fi
    if ! [[ "$total_daily" =~ ^[0-9]+$ ]]; then 
        if [ "$DEBUG_MODE" -eq 1 ]; then
            echo "调试: total_daily 验证失败: '$total_daily'" >&2
        fi
        total_daily=0
    fi
    if ! [[ "$total_monthly" =~ ^[0-9]+$ ]]; then 
        if [ "$DEBUG_MODE" -eq 1 ]; then
            echo "调试: total_monthly 验证失败: '$total_monthly'" >&2
        fi
        total_monthly=0
    fi
    
    # 获取文件系统信息
    local fs_info=$(get_filesystem_info "$gfs_path")
    IFS=':' read -r fs_total fs_used fs_available <<< "$fs_info"
    
    # 验证文件系统数据
    if ! [[ "$fs_total" =~ ^[0-9]+$ ]]; then fs_total=0; fi
    if ! [[ "$fs_used" =~ ^[0-9]+$ ]]; then fs_used=0; fi
    if ! [[ "$fs_available" =~ ^[0-9]+$ ]]; then fs_available=0; fi
    
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
    if [ "$total_daily" -gt 0 ] && [ "$fs_available" -gt 0 ]; then
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
    
    if [ "$total_monthly" -gt 0 ] && [ "$fs_available" -gt 0 ]; then
        local monthly_avg=$((total_monthly / 30))
        if [ "$monthly_avg" -gt 0 ]; then
            local days_remaining_monthly=$((fs_available / monthly_avg))
            printf "%-15s %d 天\n" "按月均增量预计:" "$days_remaining_monthly"
        else
            printf "%-15s %s\n" "按月均增量预计:" "无增量"
        fi
    else
        printf "%-15s %s\n" "按月均增量预计:" "无增量或负增长"
    fi
}

# 函数：测试增量统计功能
test_increment_functionality() {
    local gfs_path="$1"
    
    echo -e "${YELLOW}=== 测试增量统计功能 ===${NC}"
    echo ""
    
    # 创建测试目录
    local test_dir="$gfs_path/test_increment_$(date +%s)"
    echo "创建测试目录: $test_dir"
    
    if ! mkdir -p "$test_dir"; then
        echo -e "${RED}错误: 无法创建测试目录 $test_dir${NC}"
        return 1
    fi
    
    # 创建一些测试文件
    echo "创建测试文件..."
    echo "test data 1" > "$test_dir/file1.txt"
    echo "test data 2 with more content" > "$test_dir/file2.txt"
    dd if=/dev/zero of="$test_dir/largefile.dat" bs=1024 count=10 2>/dev/null
    
    # 等待一秒确保文件创建时间正确
    sleep 1
    
    # 测试当前增量（应该能找到刚创建的文件）
    echo ""
    echo "测试1天内的增量统计:"
    DEBUG_MODE=1
    local result=$(get_modified_size "$test_dir" 1)
    DEBUG_MODE=0
    
    echo "结果: $(bytes_to_human $result)"
    
    # 创建一个较旧的文件进行对比测试
    echo ""
    echo "创建一个较旧的文件用于对比..."
    local old_file="$test_dir/oldfile.txt"
    echo "old test data" > "$old_file"
    
    # 修改文件时间为2天前
    if [ "$OS_TYPE" = "macos" ]; then
        touch -t "$(date -v-2d '+%Y%m%d%H%M.%S')" "$old_file" 2>/dev/null
    else
        touch -d "2 days ago" "$old_file" 2>/dev/null
    fi
    
    echo "再次测试1天内的增量统计（不应包含旧文件）:"
    DEBUG_MODE=1
    result=$(get_modified_size "$test_dir" 1)
    DEBUG_MODE=0
    
    echo "结果: $(bytes_to_human $result)"
    
    echo ""
    echo "测试30天内的增量统计（应包含所有文件）:"
    DEBUG_MODE=1
    result=$(get_modified_size "$test_dir" 30)
    DEBUG_MODE=0
    
    echo "结果: $(bytes_to_human $result)"
    
    # 清理测试目录
    echo ""
    echo "清理测试目录..."
    rm -rf "$test_dir"
    
    echo -e "${GREEN}增量统计功能测试完成！${NC}"
}

# 主函数
main() {
    echo -e "${GREEN}GFS目录增量统计和容量预测工具${NC}"
    echo "=================================================="
    echo "操作系统类型: $OS_TYPE"
    echo ""
    
    # 解析命令行参数
    local gfs_path=""
    local test_mode=0
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --debug)
                DEBUG_MODE=1
                echo -e "${YELLOW}调试模式已启用${NC}"
                shift
                ;;
            --test-increment)
                test_mode=1
                shift
                ;;
            --help)
                show_usage
                ;;
            -*)
                echo -e "${RED}错误: 未知选项 $1${NC}"
                show_usage
                ;;
            *)
                if [ -z "$gfs_path" ]; then
                    gfs_path="$1"
                else
                    echo -e "${RED}错误: 多余的参数 $1${NC}"
                    show_usage
                fi
                shift
                ;;
        esac
    done
    
    # 检查是否提供了GFS路径
    if [ -z "$gfs_path" ]; then
        echo -e "${RED}错误: 请提供GFS挂载点路径${NC}"
        show_usage
    fi
    
    # 检查GFS挂载点是否存在
    if ! check_directory "$gfs_path"; then
        exit 1
    fi
    
    # 如果是测试模式，运行测试后退出
    if [ "$test_mode" -eq 1 ]; then
        test_increment_functionality "$gfs_path"
        exit 0
    fi
    
    # 检查必要的命令是否存在
    local required_cmds=("du" "find" "df" "stat")
    if [ "$OS_TYPE" != "macos" ]; then
        required_cmds+=("bc")
    fi
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}错误: 命令 '$cmd' 未找到，请确保已安装${NC}"
            exit 1
        fi
    done
    
    echo -e "${GREEN}开始分析GFS目录: $gfs_path${NC}"
    echo "监控的活跃目录列表:"
    printf "%s\n" "${ACTIVE_DIRS[@]}" | sed 's/^/  - /'
    
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo -e "${YELLOW}调试信息将显示在stderr中${NC}"
    fi
    echo ""
    
    # 生成目录维度报告
    local totals=$(generate_directory_report "$gfs_path")
    
    # 生成总容量维度报告
    generate_total_report "$gfs_path" "$totals"
    
    echo ""
    echo -e "${GREEN}分析完成！${NC}"
    
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo ""
        echo -e "${YELLOW}提示: 如果增量统计仍为0，请尝试以下方法:${NC}"
        echo "1. 确认监控目录中有最近修改的文件"
        echo "2. 运行测试模式: $0 --test-increment $gfs_path"
        echo "3. 检查目录权限是否正确"
        echo "4. 在配置区域添加您实际使用的目录名称"
    fi
}

# 运行主函数
main "$@" 