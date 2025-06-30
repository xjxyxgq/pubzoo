package main

import "time"

// Config 程序配置结构
type Config struct {
	HistoryArchiveDB HistoryArchiveDBConfig `json:"history_archive_db"`
	TargetDBDefaults TargetDBConfig         `json:"target_db_defaults"`
	BackupDir        string                 `json:"backup_dir"`
}

// HistoryArchiveDBConfig 历史归档数据库配置
type HistoryArchiveDBConfig struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Username string `json:"username"`
	Password string `json:"password"`
	Database string `json:"database"`
	Table    string `json:"table"`
}

// TargetDBConfig 目标数据库默认配置
type TargetDBConfig struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// CheckTask 检查任务结构
type CheckTask struct {
	TargetDBHost     string // 目标数据库地址
	DatabaseName     string // 数据库名称
	TableName        string // 数据表名称
	SearchCondition  string // 检索条件（YYYYmmdd格式）
	ExpectedRowCount int    // 预期符合条件的数据行数
}

// ArchiveInfo 归档信息结构
type ArchiveInfo struct {
	ArchiveColumnName string `db:"archive_column_name"`
}

// ColumnInfo 列信息结构
type ColumnInfo struct {
	ColumnName string `db:"COLUMN_NAME"`
	DataType   string `db:"DATA_TYPE"`
}

// CheckResult 检查结果结构
type CheckResult struct {
	Task          CheckTask
	ActualCount   int
	ExpectedCount int
	ArchiveColumn string
	IsMatch       bool
}

// BackupRecord 备份记录结构
type BackupRecord struct {
	TaskInfo    CheckTask
	BackupFile  string
	BackupTime  time.Time
	DeletedRows int
}
