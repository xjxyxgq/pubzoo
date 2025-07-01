# 数据修复工具 (fix_data)

这是一个用于检查和修复数据库数据的 Go 程序，可以根据历史归档信息验证目标数据库中的数据行数，并在必要时删除不匹配的数据。

## 功能特性

- 从历史归档数据库查询归档列信息
- 智能前缀提取：自动去除数据库名和表名末尾的 `_数字` 后缀
- 数据库安全检查：确保目标数据库非只读状态且非从节点
- 自动检测归档列的数据类型（字符串/时间类型）
- 根据数据类型执行相应的统计查询
- 数据删除前自动备份为 SQL 文件
- 交互式确认删除操作
- 详细的执行报告和统计信息

## 安装和构建

1. 确保已安装 Go 1.21 或更高版本
2. 进入项目目录：
   ```bash
   cd fix_data
   ```
3. 下载依赖：
   ```bash
   go mod tidy
   ```
4. 构建程序：
   ```bash
   go build -o fix_data .
   ```

## 配置文件

在运行程序前，需要配置 `config.json` 文件：

```json
{
  "history_archive_db": {
    "host": "localhost",
    "port": 3306,
    "username": "root",
    "password": "password",
    "database": "archive_db",
    "table": "history_arc"
  },
  "target_db_defaults": {
    "username": "root",
    "password": "password"
  },
  "backup_dir": "./backups"
}
```

### 配置说明

- `history_archive_db`: 历史归档数据库连接信息
- `target_db_defaults`: 目标数据库的默认连接凭据
- `backup_dir`: 备份文件存储目录

## 任务文件格式

创建一个 CSV 格式的任务文件，每行包含以下字段（用逗号分隔）：

```
目标数据库地址,数据库名称,数据表名称,检索条件(YYYYmmdd),预期行数
```

### 示例任务文件 (tasks.csv)

```csv
# 示例任务文件
# 格式：目标数据库地址,数据库名称,数据表名称,检索条件(YYYYmmdd),预期行数
localhost:3306,test_db,user_logs,20240101,1000
192.168.1.100:3306,product_db,order_records,20240102,2500
localhost:3306,analytics_db,page_views,20240103,5000
```

## 使用方法

1. 准备配置文件 `config.json`
2. 创建任务文件（如 `tasks.csv`）
3. 运行程序：
   ```bash
   ./fix_data tasks.csv
   ```

## 程序执行流程

1. **加载配置和任务文件**
2. **连接历史归档数据库**
3. **对每个任务执行以下操作**：
   - 查询归档列名称
   - 连接目标数据库
   - 检测归档列数据类型
   - 统计符合条件的行数
   - 比较实际行数与预期行数
4. **处理不匹配的数据**：
   - 询问用户是否删除
   - 备份要删除的数据
   - 执行删除操作
5. **生成最终统计报告**

## 数据类型支持

程序支持两种归档列数据类型：

### 字符串类型
- varchar, char, text, longtext, mediumtext, tinytext
- 查询条件：`WHERE column_name LIKE 'YYYYmmdd%'`

### 时间类型
- datetime, timestamp, date, time
- 查询条件：`WHERE column_name >= STR_TO_DATE('YYYYmmdd', '%Y%m%d') AND column_name < STR_TO_DATE('YYYYmmdd', '%Y%m%d') + INTERVAL 1 DAY`

## 备份文件

删除数据前，程序会自动生成 SQL 备份文件，包含：
- 完整的 INSERT 语句
- 备份时间和源信息
- 数据行数统计

备份文件命名格式：`backup_{database}_{table}_{timestamp}.sql`

## 注意事项

1. **数据安全**：程序在删除数据前会自动备份，但请务必在生产环境使用前进行充分测试
2. **权限要求**：确保数据库账户具有必要的查询、删除权限
3. **网络连接**：确保程序能够访问所有目标数据库
4. **磁盘空间**：备份文件可能较大，确保备份目录有足够空间

## 错误处理

程序会详细记录各种错误情况：
- 数据库连接失败
- 归档列名未找到
- 数据类型不支持
- 权限不足等

出现错误时，程序会跳过当前任务并继续处理后续任务。

## 示例输出

```
✓ 已连接到历史归档数据库
✓ 读取到 3 个检查任务

--- 处理任务 1/3 ---
目标: localhost:3306/test_db.user_logs, 条件: 20240101, 预期行数: 1000
找到归档列: created_at
归档列数据类型: datetime
实际行数: 1000
预期行数: 1000
✅ 行数匹配，无需处理

==================================================
最终统计报告
==================================================
总任务数: 3
匹配任务: 2
不匹配任务: 1
匹配率: 66.7%
```