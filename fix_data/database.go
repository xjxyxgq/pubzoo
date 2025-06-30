package main

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

// DatabaseManager 数据库管理器
type DatabaseManager struct {
	config    Config
	historyDB *sql.DB
	targetDBs map[string]*sql.DB
}

// NewDatabaseManager 创建数据库管理器
func NewDatabaseManager(config Config) *DatabaseManager {
	return &DatabaseManager{
		config:    config,
		targetDBs: make(map[string]*sql.DB),
	}
}

// ConnectHistoryDB 连接历史归档数据库
func (dm *DatabaseManager) ConnectHistoryDB() error {
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%d)/%s?parseTime=true",
		dm.config.HistoryArchiveDB.Username,
		dm.config.HistoryArchiveDB.Password,
		dm.config.HistoryArchiveDB.Host,
		dm.config.HistoryArchiveDB.Port,
		dm.config.HistoryArchiveDB.Database)

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return fmt.Errorf("连接历史归档数据库失败: %v", err)
	}

	if err = db.Ping(); err != nil {
		return fmt.Errorf("历史归档数据库连接测试失败: %v", err)
	}

	dm.historyDB = db
	return nil
}

// ConnectTargetDB 连接目标数据库
func (dm *DatabaseManager) ConnectTargetDB(host, database, username, password string) (*sql.DB, error) {
	key := fmt.Sprintf("%s-%s", host, database)

	if db, exists := dm.targetDBs[key]; exists {
		return db, nil
	}

	dsn := fmt.Sprintf("%s:%s@tcp(%s)/%s?parseTime=true",
		username, password, host, database)

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("连接目标数据库失败 %s/%s: %v", host, database, err)
	}

	if err = db.Ping(); err != nil {
		return nil, fmt.Errorf("目标数据库连接测试失败 %s/%s: %v", host, database, err)
	}

	dm.targetDBs[key] = db
	return db, nil
}

// extractNamePrefix 提取名称前缀，去除末尾的 _数字 组合
func extractNamePrefix(name string) string {
	// 正则表达式匹配末尾的 _数字 组合
	re := regexp.MustCompile(`_\d+$`)
	return re.ReplaceAllString(name, "")
}

// GetArchiveColumnName 获取归档列名
func (dm *DatabaseManager) GetArchiveColumnName(dbName, tableName string) (string, error) {
	// 提取数据库名和表名的前缀
	dbNamePre := extractNamePrefix(dbName)
	tableNamePre := extractNamePrefix(tableName)

	query := fmt.Sprintf("SELECT archive_column_name FROM %s WHERE table_name_pre = ? AND db_name_pre = ?",
		dm.config.HistoryArchiveDB.Table)

	var archiveColumnName string
	err := dm.historyDB.QueryRow(query, tableNamePre, dbNamePre).Scan(&archiveColumnName)
	if err != nil {
		if err == sql.ErrNoRows {
			return "", fmt.Errorf("未找到匹配的归档列名，数据库前缀: %s, 表前缀: %s", dbNamePre, tableNamePre)
		}
		return "", fmt.Errorf("查询归档列名失败: %v", err)
	}

	return archiveColumnName, nil
}

// GetColumnDataType 获取列的数据类型
func (dm *DatabaseManager) GetColumnDataType(db *sql.DB, database, table, column string) (string, error) {
	query := `SELECT DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS 
			  WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND COLUMN_NAME = ?`

	var dataType string
	err := db.QueryRow(query, database, table, column).Scan(&dataType)
	if err != nil {
		return "", fmt.Errorf("获取列数据类型失败: %v", err)
	}

	return dataType, nil
}

// CountRowsByCondition 根据条件统计行数
func (dm *DatabaseManager) CountRowsByCondition(db *sql.DB, table, column, condition, dataType string) (int, error) {
	var query string

	// 根据数据类型选择不同的查询方式
	if isStringType(dataType) {
		// 字符串类型
		query = fmt.Sprintf("SELECT COUNT(*) FROM %s WHERE %s LIKE ?", table, column)
		var count int
		err := db.QueryRow(query, condition+"%").Scan(&count)
		return count, err
	} else if isDateTimeType(dataType) {
		// 时间类型
		query = fmt.Sprintf(`SELECT COUNT(*) FROM %s WHERE %s >= STR_TO_DATE(?, '%%Y%%m%%d') 
							 AND %s < STR_TO_DATE(?, '%%Y%%m%%d') + INTERVAL 1 DAY`, table, column, column)
		var count int
		err := db.QueryRow(query, condition, condition).Scan(&count)
		return count, err
	} else {
		return 0, fmt.Errorf("不支持的数据类型: %s", dataType)
	}
}

// BackupDataToFile 备份数据到文件
func (dm *DatabaseManager) BackupDataToFile(db *sql.DB, task CheckTask, archiveColumn, dataType string) (string, error) {
	// 创建备份目录
	if err := os.MkdirAll(dm.config.BackupDir, 0755); err != nil {
		return "", fmt.Errorf("创建备份目录失败: %v", err)
	}

	// 生成备份文件名
	timestamp := time.Now().Format("20060102_150405")
	filename := fmt.Sprintf("backup_%s_%s_%s.sql", task.DatabaseName, task.TableName, timestamp)
	filepath := filepath.Join(dm.config.BackupDir, filename)

	// 打开备份文件
	file, err := os.Create(filepath)
	if err != nil {
		return "", fmt.Errorf("创建备份文件失败: %v", err)
	}
	defer file.Close()

	// 写入文件头信息
	file.WriteString(fmt.Sprintf("-- 备份时间: %s\n", time.Now().Format("2006-01-02 15:04:05")))
	file.WriteString(fmt.Sprintf("-- 源数据库: %s\n", task.DatabaseName))
	file.WriteString(fmt.Sprintf("-- 源表: %s\n", task.TableName))
	file.WriteString(fmt.Sprintf("-- 条件: %s\n", task.SearchCondition))
	file.WriteString(fmt.Sprintf("-- 归档列: %s\n\n", archiveColumn))

	// 构造查询SQL
	var whereClause string
	if isStringType(dataType) {
		whereClause = fmt.Sprintf("WHERE %s LIKE '%s%%'", archiveColumn, task.SearchCondition)
	} else if isDateTimeType(dataType) {
		whereClause = fmt.Sprintf(`WHERE %s >= STR_TO_DATE('%s', '%%Y%%m%%d') 
								   AND %s < STR_TO_DATE('%s', '%%Y%%m%%d') + INTERVAL 1 DAY`,
			archiveColumn, task.SearchCondition, archiveColumn, task.SearchCondition)
	}

	// 查询要备份的数据
	query := fmt.Sprintf("SELECT * FROM %s %s", task.TableName, whereClause)
	rows, err := db.Query(query)
	if err != nil {
		return "", fmt.Errorf("查询备份数据失败: %v", err)
	}
	defer rows.Close()

	// 获取列信息
	columns, err := rows.Columns()
	if err != nil {
		return "", fmt.Errorf("获取列信息失败: %v", err)
	}

	// 生成INSERT语句
	rowCount := 0
	for rows.Next() {
		// 创建扫描目标
		values := make([]interface{}, len(columns))
		valuePtrs := make([]interface{}, len(columns))
		for i := range values {
			valuePtrs[i] = &values[i]
		}

		// 扫描行数据
		if err := rows.Scan(valuePtrs...); err != nil {
			return "", fmt.Errorf("扫描行数据失败: %v", err)
		}

		// 构造INSERT语句
		insertSQL := fmt.Sprintf("INSERT INTO %s (", task.TableName)
		insertSQL += strings.Join(columns, ", ")
		insertSQL += ") VALUES ("

		valueStrings := make([]string, len(values))
		for i, v := range values {
			if v == nil {
				valueStrings[i] = "NULL"
			} else {
				switch v := v.(type) {
				case []byte:
					valueStrings[i] = fmt.Sprintf("'%s'", strings.ReplaceAll(string(v), "'", "''"))
				case string:
					valueStrings[i] = fmt.Sprintf("'%s'", strings.ReplaceAll(v, "'", "''"))
				case time.Time:
					valueStrings[i] = fmt.Sprintf("'%s'", v.Format("2006-01-02 15:04:05"))
				default:
					valueStrings[i] = fmt.Sprintf("%v", v)
				}
			}
		}

		insertSQL += strings.Join(valueStrings, ", ")
		insertSQL += ");\n"

		file.WriteString(insertSQL)
		rowCount++
	}

	file.WriteString(fmt.Sprintf("\n-- 备份完成，共备份 %d 行数据\n", rowCount))
	return filepath, nil
}

// DeleteDataByCondition 根据条件删除数据
func (dm *DatabaseManager) DeleteDataByCondition(db *sql.DB, task CheckTask, archiveColumn, dataType string) (int, error) {
	var whereClause string
	var args []interface{}

	if isStringType(dataType) {
		whereClause = fmt.Sprintf("WHERE %s LIKE ?", archiveColumn)
		args = []interface{}{task.SearchCondition + "%"}
	} else if isDateTimeType(dataType) {
		whereClause = fmt.Sprintf(`WHERE %s >= STR_TO_DATE(?, '%%Y%%m%%d') 
								   AND %s < STR_TO_DATE(?, '%%Y%%m%%d') + INTERVAL 1 DAY`,
			archiveColumn, archiveColumn)
		args = []interface{}{task.SearchCondition, task.SearchCondition}
	} else {
		return 0, fmt.Errorf("不支持的数据类型: %s", dataType)
	}

	deleteSQL := fmt.Sprintf("DELETE FROM %s %s", task.TableName, whereClause)
	result, err := db.Exec(deleteSQL, args...)
	if err != nil {
		return 0, fmt.Errorf("删除数据失败: %v", err)
	}

	affected, err := result.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("获取删除行数失败: %v", err)
	}

	return int(affected), nil
}

// Close 关闭所有数据库连接
func (dm *DatabaseManager) Close() {
	if dm.historyDB != nil {
		dm.historyDB.Close()
	}

	for _, db := range dm.targetDBs {
		db.Close()
	}
}

// 辅助函数：判断是否为字符串类型
func isStringType(dataType string) bool {
	stringTypes := []string{"varchar", "char", "text", "longtext", "mediumtext", "tinytext"}
	dataType = strings.ToLower(dataType)
	for _, t := range stringTypes {
		if strings.Contains(dataType, t) {
			return true
		}
	}
	return false
}

// 辅助函数：判断是否为日期时间类型
func isDateTimeType(dataType string) bool {
	dateTimeTypes := []string{"datetime", "timestamp", "date", "time"}
	dataType = strings.ToLower(dataType)
	for _, t := range dateTimeTypes {
		if strings.Contains(dataType, t) {
			return true
		}
	}
	return false
}
