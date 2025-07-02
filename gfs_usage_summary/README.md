# GFS目录增量统计和容量预测工具

这是一个用于统计挂载在本地的GFS目录增量使用情况，并预测剩余可用时长的Shell脚本工具。

## 功能特性

- 🔍 **目录维度统计**：分析指定活跃目录的当前容量、日增量、月增量
- 📊 **总容量维度报告**：提供TOP10最大目录、文件系统容量信息和增量预测
- ⏰ **容量预测**：基于当前增量速度预计存储空间可用时长
- 🖥️ **跨平台支持**：支持macOS和Linux系统
- 🎨 **友好界面**：带颜色的终端输出，易于阅读

## 系统要求

### macOS系统
- `du`, `find`, `df`, `stat`, `awk` (系统自带)

### Linux系统
- `du`, `find`, `df`, `stat`, `awk`, `bc`

## 安装和配置

### 1. 下载脚本
将 `gfs_usage_monitor.sh` 下载到您的系统中并添加执行权限：

```bash
chmod +x gfs_usage_monitor.sh
```

### 2. 配置监控目录
编辑脚本中的 `ACTIVE_DIRS` 数组，添加您需要监控的活跃目录：

```bash
# 配置区域 - 需要监控的活跃目录列表
# 请根据实际情况修改这些目录路径（相对于GFS挂载点的路径）
ACTIVE_DIRS=(
    "project_data"      # 项目数据目录
    "logs"              # 日志目录
    "backups"           # 备份目录
    "temp_files"        # 临时文件目录
    "user_uploads"      # 用户上传目录
    "database_dumps"    # 数据库转储目录
    "media_files"       # 媒体文件目录
)
```

## 使用方法

### 基本用法
```bash
./gfs_usage_monitor.sh <gfs_mount_point>
```

### 示例
```bash
# 分析挂载在 /mnt/gfs 的GFS文件系统
./gfs_usage_monitor.sh /mnt/gfs

# 分析挂载在 /Volumes/GFS 的GFS文件系统 (macOS)
./gfs_usage_monitor.sh /Volumes/GFS
```

## 输出报告说明

### 目录维度报告
```
=== 目录维度报告 ===

目录名称                      当前容量     日增量       月增量
------------------------------    ------------    ------------    ------------
project_data                  10GB        120MB       3GB
logs                          5GB         85MB        2GB
backups                       15GB        50MB        1GB
temp_files                    2GB         200MB       5GB
user_uploads                  8GB         150MB       4GB
------------------------------    ------------    ------------    ------------
总计                          40GB        605MB       15GB
```

### 总容量维度报告
```
=== 总容量维度报告 ===

TOP10 最大目录:

backups                       15GB
project_data                  10GB
user_uploads                  8GB
logs                          5GB
temp_files                    2GB

文件系统容量信息:
总容量:         500GB
已使用:         350GB
可用空间:       150GB

监控目录增量信息:
监控总容量:     40GB
总日增量:       605MB
总月增量:       15GB

容量预测:
按日增量预计:   248 天
按月均增量预计: 300 天
```

## 工作原理

### 增量计算方法
- **日增量**：使用 `find` 命令查找过去24小时内修改的文件 (`-mtime -1`)
- **月增量**：使用 `find` 命令查找过去30天内修改的文件 (`-mtime -30`)
- **文件大小**：通过文件的mtime属性判断是否在指定时间范围内

### 容量预测算法
- **按日增量预测**：`剩余空间 ÷ 日增量 = 预计可用天数`
- **按月均增量预测**：`剩余空间 ÷ (月增量 ÷ 30) = 预计可用天数`

### 跨平台兼容性
脚本自动检测操作系统类型并使用对应的命令参数：
- **macOS**：使用 `df -k`, `stat -f%z`, `du -s`
- **Linux**：使用 `df -B1`, `stat -c%s`, `du -sb`

## 注意事项

1. **权限要求**：确保脚本有读取GFS挂载点及其子目录的权限
2. **性能考虑**：对于大型目录，首次运行可能需要较长时间
3. **准确性**：
   - 增量统计基于文件修改时间，新创建的文件会被计算在内
   - 删除的文件不会从增量中减去
   - 建议定期运行以获得更准确的趋势数据

## 故障排除

### 常见错误
1. **目录不存在**：检查GFS挂载点路径是否正确
2. **权限被拒绝**：确保有读取目录的权限
3. **命令未找到**：检查必要的系统命令是否已安装

### 调试模式
如需查看详细的处理过程，可以修改脚本中的错误重定向：

```bash
# 将这行
local totals=$(generate_directory_report "$gfs_path" 2>/dev/null)

# 改为
local totals=$(generate_directory_report "$gfs_path")
```

## 自定义扩展

### 添加新的时间范围
可以修改 `get_modified_size` 函数来支持其他时间范围：

```bash
# 例如：获取过去7天的增量
local weekly_bytes=$(get_modified_size "$full_path" 7)
```

### 修改输出格式
可以调整 `printf` 格式化字符串来改变报告的显示样式。

### 添加邮件通知
可以在脚本末尾添加邮件发送功能，定期发送报告。

## 许可证

本工具采用MIT许可证，可自由使用和修改。 