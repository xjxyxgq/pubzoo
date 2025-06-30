package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
)

func main() {
	// 检查命令行参数
	if len(os.Args) != 2 {
		fmt.Println("使用方法: ./fix_data <输入文件路径>")
		fmt.Println("示例: ./fix_data tasks.csv")
		os.Exit(1)
	}

	inputFile := os.Args[1]

	// 加载配置
	config, err := loadConfig("config.json")
	if err != nil {
		fmt.Printf("加载配置失败: %v\n", err)
		os.Exit(1)
	}

	// 创建数据库管理器
	dbManager := NewDatabaseManager(config)
	defer dbManager.Close()

	// 连接历史归档数据库
	if err := dbManager.ConnectHistoryDB(); err != nil {
		fmt.Printf("连接历史归档数据库失败: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("✓ 已连接到历史归档数据库")

	// 读取任务文件
	tasks, err := readTasksFromFile(inputFile)
	if err != nil {
		fmt.Printf("读取任务文件失败: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("✓ 读取到 %d 个检查任务\n", len(tasks))

	// 处理每个任务
	var results []CheckResult
	for i, task := range tasks {
		fmt.Printf("\n--- 处理任务 %d/%d ---\n", i+1, len(tasks))
		fmt.Printf("目标: %s/%s.%s, 条件: %s, 预期行数: %d\n",
			task.TargetDBHost, task.DatabaseName, task.TableName,
			task.SearchCondition, task.ExpectedRowCount)

		result, err := processTask(dbManager, task)
		if err != nil {
			fmt.Printf("❌ 任务处理失败: %v\n", err)
			continue
		}

		results = append(results, result)
		printTaskResult(result)

		// 如果行数不匹配，询问是否删除
		if !result.IsMatch {
			if askForDeletion(result) {
				err := performDeletion(dbManager, result)
				if err != nil {
					fmt.Printf("❌ 删除操作失败: %v\n", err)
				} else {
					fmt.Println("✓ 删除操作完成")
				}
			}
		}
	}

	// 打印最终统计
	printFinalSummary(results)
}

// loadConfig 加载配置文件
func loadConfig(filename string) (Config, error) {
	var config Config

	file, err := os.Open(filename)
	if err != nil {
		return config, fmt.Errorf("无法打开配置文件 %s: %v", filename, err)
	}
	defer file.Close()

	decoder := json.NewDecoder(file)
	err = decoder.Decode(&config)
	if err != nil {
		return config, fmt.Errorf("解析配置文件失败: %v", err)
	}

	return config, nil
}

// readTasksFromFile 从文件读取任务列表
func readTasksFromFile(filename string) ([]CheckTask, error) {
	file, err := os.Open(filename)
	if err != nil {
		return nil, fmt.Errorf("无法打开文件 %s: %v", filename, err)
	}
	defer file.Close()

	var tasks []CheckTask
	scanner := bufio.NewScanner(file)
	lineNum := 0

	for scanner.Scan() {
		lineNum++
		line := strings.TrimSpace(scanner.Text())

		// 跳过空行和注释行
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// 解析CSV格式：目标数据库地址,数据库名称,数据表名称,检索条件,预期行数
		fields := strings.Split(line, ",")
		if len(fields) != 5 {
			return nil, fmt.Errorf("第 %d 行格式错误：需要5个字段，实际有 %d 个", lineNum, len(fields))
		}

		// 清理字段内容
		for i := range fields {
			fields[i] = strings.TrimSpace(fields[i])
		}

		// 解析预期行数
		expectedCount, err := strconv.Atoi(fields[4])
		if err != nil {
			return nil, fmt.Errorf("第 %d 行预期行数格式错误: %v", lineNum, err)
		}

		task := CheckTask{
			TargetDBHost:     fields[0],
			DatabaseName:     fields[1],
			TableName:        fields[2],
			SearchCondition:  fields[3],
			ExpectedRowCount: expectedCount,
		}

		tasks = append(tasks, task)
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("读取文件时出错: %v", err)
	}

	return tasks, nil
}

// processTask 处理单个检查任务
func processTask(dbManager *DatabaseManager, task CheckTask) (CheckResult, error) {
	result := CheckResult{
		Task:          task,
		ExpectedCount: task.ExpectedRowCount,
	}

	// 1. 从历史归档数据库获取归档列名
	archiveColumn, err := dbManager.GetArchiveColumnName(task.DatabaseName, task.TableName)
	if err != nil {
		return result, fmt.Errorf("获取归档列名失败: %v", err)
	}
	result.ArchiveColumn = archiveColumn
	fmt.Printf("找到归档列: %s\n", archiveColumn)

	// 2. 连接目标数据库
	targetDB, err := dbManager.ConnectTargetDB(task.TargetDBHost, task.DatabaseName, dbManager.config.TargetDBDefaults.Username, dbManager.config.TargetDBDefaults.Password)
	if err != nil {
		return result, fmt.Errorf("连接目标数据库失败: %v", err)
	}

	// 3. 获取归档列的数据类型
	dataType, err := dbManager.GetColumnDataType(targetDB, task.DatabaseName, task.TableName, archiveColumn)
	if err != nil {
		return result, fmt.Errorf("获取列数据类型失败: %v", err)
	}
	fmt.Printf("归档列数据类型: %s\n", dataType)

	// 4. 统计符合条件的行数
	actualCount, err := dbManager.CountRowsByCondition(targetDB, task.TableName, archiveColumn, task.SearchCondition, dataType)
	if err != nil {
		return result, fmt.Errorf("统计行数失败: %v", err)
	}

	result.ActualCount = actualCount
	result.IsMatch = (actualCount == task.ExpectedRowCount)

	return result, nil
}

// printTaskResult 打印任务结果
func printTaskResult(result CheckResult) {
	fmt.Printf("归档列: %s\n", result.ArchiveColumn)
	fmt.Printf("实际行数: %d\n", result.ActualCount)
	fmt.Printf("预期行数: %d\n", result.ExpectedCount)

	if result.IsMatch {
		fmt.Println("✅ 行数匹配，无需处理")
	} else {
		fmt.Printf("⚠️  行数不匹配，差异: %d\n", result.ActualCount-result.ExpectedCount)
	}
}

// askForDeletion 询问用户是否删除数据
func askForDeletion(result CheckResult) bool {
	fmt.Printf("\n数据行数不匹配，是否删除目标数据？\n")
	fmt.Printf("表: %s.%s\n", result.Task.DatabaseName, result.Task.TableName)
	fmt.Printf("条件: %s\n", result.Task.SearchCondition)
	fmt.Printf("将删除 %d 行数据\n", result.ActualCount)
	fmt.Print("请输入 y/yes 确认删除，或 n/no 跳过: ")

	var input string
	fmt.Scanln(&input)
	input = strings.ToLower(strings.TrimSpace(input))

	return input == "y" || input == "yes"
}

// performDeletion 执行删除操作
func performDeletion(dbManager *DatabaseManager, result CheckResult) error {
	// 连接目标数据库
	targetDB, err := dbManager.ConnectTargetDB(result.Task.TargetDBHost, result.Task.DatabaseName, dbManager.config.TargetDBDefaults.Username, dbManager.config.TargetDBDefaults.Password)
	if err != nil {
		return fmt.Errorf("连接目标数据库失败: %v", err)
	}

	// 获取列数据类型
	dataType, err := dbManager.GetColumnDataType(targetDB, result.Task.DatabaseName, result.Task.TableName, result.ArchiveColumn)
	if err != nil {
		return fmt.Errorf("获取列数据类型失败: %v", err)
	}

	fmt.Println("正在备份数据...")
	// 备份数据
	backupFile, err := dbManager.BackupDataToFile(targetDB, result.Task, result.ArchiveColumn, dataType)
	if err != nil {
		return fmt.Errorf("备份数据失败: %v", err)
	}
	fmt.Printf("✓ 数据已备份到: %s\n", backupFile)

	fmt.Println("正在删除数据...")
	// 删除数据
	deletedRows, err := dbManager.DeleteDataByCondition(targetDB, result.Task, result.ArchiveColumn, dataType)
	if err != nil {
		return fmt.Errorf("删除数据失败: %v", err)
	}

	fmt.Printf("✓ 成功删除 %d 行数据\n", deletedRows)
	return nil
}

// printFinalSummary 打印最终统计
func printFinalSummary(results []CheckResult) {
	fmt.Println("\n" + strings.Repeat("=", 50))
	fmt.Println("最终统计报告")
	fmt.Println(strings.Repeat("=", 50))

	totalTasks := len(results)
	matchedTasks := 0
	for _, result := range results {
		if result.IsMatch {
			matchedTasks++
		}
	}

	fmt.Printf("总任务数: %d\n", totalTasks)
	fmt.Printf("匹配任务: %d\n", matchedTasks)
	fmt.Printf("不匹配任务: %d\n", totalTasks-matchedTasks)

	if totalTasks > 0 {
		fmt.Printf("匹配率: %.1f%%\n", float64(matchedTasks)*100/float64(totalTasks))
	}

	// 详细列表
	if totalTasks-matchedTasks > 0 {
		fmt.Println("\n不匹配的任务:")
		for _, result := range results {
			if !result.IsMatch {
				fmt.Printf("- %s.%s: 实际 %d, 预期 %d (差异: %d)\n",
					result.Task.DatabaseName, result.Task.TableName,
					result.ActualCount, result.ExpectedCount,
					result.ActualCount-result.ExpectedCount)
			}
		}
	}
}
