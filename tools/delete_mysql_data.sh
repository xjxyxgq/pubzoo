#!/bin/bash

# MySQL连接参数配置
MYSQL_HOST="localhost"
MYSQL_PORT="3306"
MYSQL_USER="root"
MYSQL_PASSWORD="your_password"
MYSQL_DATABASE="your_database"

# 自定义SQL语句配置
# 每个SQL语句都会循环执行直到没有记录被删除
# 格式：SQL语句（必须包含LIMIT子句）
DELETE_SQLS=(
    "DELETE FROM test WHERE id < 1000 LIMIT 1"
    "DELETE FROM user_logs WHERE created_at < '2023-01-01' LIMIT 10"
    "DELETE FROM temp_data WHERE status = 'expired' LIMIT 5"
    # 添加更多SQL语句...
)

# 其他配置
SLEEP_INTERVAL=0.1  # 每次删除后的休眠时间（秒）
LOG_INTERVAL=100    # 每删除多少条记录输出一次日志

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

# 检查MySQL连接
check_mysql_connection() {
    log_info "检查MySQL连接..."
    mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1;" "$MYSQL_DATABASE" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_error "无法连接到MySQL数据库，请检查连接参数"
        exit 1
    fi
    log_info "MySQL连接正常"
}

# SQL安全检查函数
validate_sql() {
    local sql="$1"
    local sql_upper=$(echo "$sql" | tr '[:lower:]' '[:upper:]')
    
    # 检查是否是DELETE语句
    if [[ ! "$sql_upper" =~ ^[[:space:]]*DELETE[[:space:]]+FROM[[:space:]]+ ]]; then
        log_error "SQL语句必须是DELETE语句: $sql"
        return 1
    fi
    
    # 检查是否包含WHERE条件
    if [[ ! "$sql_upper" =~ [[:space:]]WHERE[[:space:]] ]]; then
        log_error "SQL语句必须包含WHERE条件以确保安全: $sql"
        return 1
    fi
    
    # 检查是否包含LIMIT子句
    if [[ ! "$sql_upper" =~ [[:space:]]LIMIT[[:space:]]+[0-9]+ ]]; then
        log_error "SQL语句必须包含LIMIT子句以控制删除数量: $sql"
        return 1
    fi
    
    # 检查LIMIT值是否合理（不超过10000）
    local limit_value=$(echo "$sql_upper" | sed -n 's/.*LIMIT[[:space:]]\+\([0-9]\+\).*/\1/p')
    if [ -n "$limit_value" ] && [ "$limit_value" -gt 10000 ]; then
        log_warn "LIMIT值较大($limit_value)，建议设置为较小的值以避免长时间锁表"
        echo -n "是否继续执行此SQL？(y/N): "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "跳过此SQL语句"
            return 1
        fi
    fi
    
    # 检查是否包含危险的WHERE条件（如1=1, true等）
    if [[ "$sql_upper" =~ WHERE[[:space:]]+1[[:space:]]*=[[:space:]]*1 ]] || \
       [[ "$sql_upper" =~ WHERE[[:space:]]+TRUE ]] || \
       [[ "$sql_upper" =~ WHERE[[:space:]]+\'1\'[[:space:]]*=[[:space:]]*\'1\' ]]; then
        log_error "检测到危险的WHERE条件，可能会删除全表数据: $sql"
        return 1
    fi
    
    return 0
}

# 从DELETE语句中提取表名和WHERE条件，用于统计记录数
extract_count_sql() {
    local delete_sql="$1"
    
    # 转换为大写进行处理，确保大小写不敏感
    local sql_upper=$(echo "$delete_sql" | tr '[:lower:]' '[:upper:]')
    
    # 修复正则表达式：匹配 DELETE FROM table_name WHERE ... LIMIT n
    # 使用非贪婪匹配来正确捕获WHERE子句
    local count_sql=$(echo "$sql_upper" | sed -E 's/^[[:space:]]*DELETE[[:space:]]+FROM[[:space:]]+([^[:space:]]+)[[:space:]]+(WHERE.*)[[:space:]]+LIMIT[[:space:]]+[0-9]+[[:space:]]*$/SELECT COUNT(*) FROM \1 \2/')
    
    # 验证生成的SQL是否为有效的SELECT语句
    if [[ ! "$count_sql" =~ ^SELECT[[:space:]]+COUNT\(\*\)[[:space:]]+FROM[[:space:]]+ ]]; then
        log_error "无法从DELETE语句生成有效的COUNT查询: $delete_sql"
        echo ""
        return 1
    fi
    
    echo "$count_sql"
}

# 获取符合条件的记录总数
get_total_count() {
    local delete_sql="$1"
    local count_sql=$(extract_count_sql "$delete_sql")
    
    # 检查count_sql是否生成成功
    if [ -z "$count_sql" ]; then
        log_error "无法生成COUNT查询语句"
        echo "ERROR"
        return 1
    fi
    
    # 执行COUNT查询，同时捕获stdout和stderr
    local mysql_output=$(mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -s -N -e "$count_sql" "$MYSQL_DATABASE" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_error "执行COUNT查询失败: $count_sql"
        log_error "MySQL错误信息: $mysql_output"
        echo "ERROR"
        return 1
    fi
    
    # 清理输出，去除可能的空白字符
    local count=$(echo "$mysql_output" | tr -d '\r\n\t ' | head -n 1)
    
    # 验证结果是否为数字
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        log_error "COUNT查询返回非数字结果: '$mysql_output'，可能表不存在或查询语法错误"
        echo "ERROR"
        return 1
    fi
    
    echo "$count"
}

# 执行删除操作
execute_delete() {
    local delete_sql="$1"
    
    # 使用事务和ROW_COUNT()函数来准确获取影响行数
    local sql_with_count="$delete_sql; SELECT ROW_COUNT() AS affected_rows;"
    
    local result=$(mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -s -N -e "$sql_with_count" "$MYSQL_DATABASE" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_error "删除操作失败: $result"
        return 1
    fi
    
    # 获取受影响的行数（ROW_COUNT()的结果在最后一行）
    local affected_rows=$(echo "$result" | tail -n 1 | tr -d '\r\n')
    
    # 验证结果是否为数字
    if ! [[ "$affected_rows" =~ ^[0-9]+$ ]]; then
        log_warn "无法获取准确的影响行数，使用默认值0。原始结果: $result"
        affected_rows=0
    fi
    
    echo "$affected_rows"
}

# 执行单个SQL的删除循环
execute_sql_loop() {
    local delete_sql="$1"
    local sql_index="$2"
    
    log_info "开始执行第 $sql_index 条SQL: $delete_sql"
    
    # 获取初始记录数
    local total_count=$(get_total_count "$delete_sql")
    
    # 检查total_count是否为有效数字
    if [ -z "$total_count" ] || [ "x$total_count" = "xERROR" ] || ! [[ "$total_count" =~ ^[0-9]+$ ]]; then
        log_error "第 $sql_index 条SQL: 无法获取有效的记录数量，可能表不存在或查询失败。返回值: $total_count"
        return 1
    fi
    
    if [ "x$total_count" = "x0" ]; then
        log_info "第 $sql_index 条SQL: 没有符合条件的记录需要删除"
        return 0
    fi
    
    log_info "第 $sql_index 条SQL: 找到 $total_count 条符合条件的记录"
    
    # 开始删除循环
    local deleted_count=0
    local loop_count=0
    
    while true; do
        # 执行删除
        local affected_rows=$(execute_delete "$delete_sql")
        
        if [ $? -ne 0 ]; then
            log_error "第 $sql_index 条SQL删除操作失败，跳过此SQL"
            return 1
        fi
        
        # 如果没有删除任何记录，说明已经删除完毕
        if [ "x$affected_rows" = "x0" ]; then
            log_info "第 $sql_index 条SQL: 所有符合条件的记录已删除完毕"
            break
        fi
        
        # 确保affected_rows是数字，防止算术错误
        if [[ "$affected_rows" =~ ^[0-9]+$ ]]; then
            deleted_count=$((deleted_count + affected_rows))
        else
            log_warn "affected_rows不是有效数字: $affected_rows，跳过累加"
        fi
        loop_count=$((loop_count + 1))
        
        # 定期输出进度
        if [ $((loop_count % LOG_INTERVAL)) -eq 0 ]; then
            local remaining_count=$(get_total_count "$delete_sql")
            if [ "x$remaining_count" = "xERROR" ] || ! [[ "$remaining_count" =~ ^[0-9]+$ ]]; then
                log_info "第 $sql_index 条SQL: 已删除 $deleted_count 条记录，剩余记录数查询失败"
            else
                log_info "第 $sql_index 条SQL: 已删除 $deleted_count 条记录，剩余 $remaining_count 条记录"
            fi
        fi
        
        # 休眠一段时间，避免对数据库造成过大压力
        sleep "$SLEEP_INTERVAL"
    done
    
    log_info "第 $sql_index 条SQL删除完成，共删除 $deleted_count 条记录"
    return 0
}

# 主函数
main() {
    log_info "开始执行MySQL数据删除脚本"
    log_info "共配置了 ${#DELETE_SQLS[@]} 条SQL语句"
    
    # 检查连接
    check_mysql_connection
    
    # 验证所有SQL语句的安全性
    log_info "开始验证SQL语句安全性..."
    local valid_sqls=()
    local invalid_count=0
    
    for i in "${!DELETE_SQLS[@]}"; do
        local sql="${DELETE_SQLS[i]}"
        log_info "验证第 $((i+1)) 条SQL: $sql"
        
        if validate_sql "$sql"; then
            valid_sqls+=("$sql")
            log_info "✓ 第 $((i+1)) 条SQL验证通过"
        else
            invalid_count=$((invalid_count + 1))
            log_error "✗ 第 $((i+1)) 条SQL验证失败"
        fi
    done
    
    if [ ${#valid_sqls[@]} -eq 0 ]; then
        log_error "没有有效的SQL语句可以执行"
        exit 1
    fi
    
    if [ $invalid_count -gt 0 ]; then
        log_warn "发现 $invalid_count 条无效的SQL语句，将被跳过"
    fi
    
    log_info "SQL安全验证完成，共有 ${#valid_sqls[@]} 条有效SQL语句"
    
    # 显示所有有效的SQL语句
    log_info "将要执行的有效SQL语句："
    for i in "${!valid_sqls[@]}"; do
        log_info "  $((i+1)). ${valid_sqls[i]}"
    done
    
    # 确认是否继续
    echo -n "是否继续删除操作？(y/N): "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        exit 0
    fi
    
    # 统计总体执行情况
    local total_deleted=0
    local success_count=0
    local failed_count=0
    
    # 循环执行每条有效的SQL
    for i in "${!valid_sqls[@]}"; do
        local sql="${valid_sqls[i]}"
        local sql_index=$((i+1))
        
        log_info "========== 开始执行第 $sql_index 条SQL =========="
        
        if execute_sql_loop "$sql" "$sql_index"; then
            success_count=$((success_count + 1))
        else
            failed_count=$((failed_count + 1))
        fi
        
        log_info "========== 第 $sql_index 条SQL执行完毕 =========="
        echo
    done
    
    # 输出总体统计
    log_info "所有SQL执行完毕"
    log_info "成功执行: $success_count 条SQL"
    if [ $failed_count -gt 0 ]; then
        log_warn "失败: $failed_count 条SQL"
    fi
}

# 信号处理函数
cleanup() {
    log_warn "接收到中断信号，正在安全退出..."
    exit 130
}

# 设置信号处理
trap cleanup SIGINT SIGTERM

# 执行主函数
main "$@" 
