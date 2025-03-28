#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Jira工具: 用于批量操作Jira工单
"""

import argparse
import sys
from datetime import datetime
from jira import JIRA
from jira.exceptions import JIRAError

from config import load_config


def connect_jira():
    """连接到Jira服务器"""
    try:
        config = load_config()
        jira = JIRA(server=config["server"], basic_auth=(config["username"], config["password"]))
        return jira
    except JIRAError as e:
        print(f"连接Jira服务器失败: {e}")
        sys.exit(1)


def add_comment_and_close_issues(jql, comment=None, transition_name=None):
    """
    根据JQL查询Jira单，添加备注并关闭
    
    Args:
        jql: JQL查询语句
        comment: 要添加的备注内容，如果为None，将通过输入获取
        transition_name: 转换状态的名称，如果未提供，将尝试常见的关闭状态名称
    """
    jira = connect_jira()
    
    try:
        # 查询符合条件的Issue
        issues = jira.search_issues(jql, maxResults=500)
        print(f"找到 {len(issues)} 个Jira单")
        
        if not issues:
            print("没有找到符合JQL的Jira单")
            return
        
        # 首先列出所有符合条件的Jira单
        print("\n以下是符合条件的Jira单：")
        for issue in issues:
            print(f"{issue.key} {issue.fields.summary}")
        
        # 如果没有提供备注内容，则通过输入获取
        if comment is None:
            print("\n请输入要添加的备注信息 (输入多行文本，按Ctrl+D结束)：")
            comment_lines = []
            try:
                while True:
                    line = input()
                    comment_lines.append(line)
            except EOFError:
                comment = "\n".join(comment_lines)
            
            if not comment.strip():
                print("备注内容不能为空")
                return
            
            print(f"\n您输入的备注信息是：\n{comment}")
            confirm = input("\n确认要继续处理这些Jira单吗？(y/n): ")
            if confirm.lower() != 'y':
                print("已取消操作")
                return
        
        # 可能的关闭状态名称列表（根据需要调整）
        close_transitions = ["关闭", "Close", "Closed", "Done", "Resolve", "Resolved", "完成"]
        if transition_name:
            close_transitions.insert(0, transition_name)
        
        for issue in issues:
            issue_key = issue.key
            print(f"处理 {issue_key} - {issue.fields.summary}")
            
            # 添加备注
            jira.add_comment(issue, comment)
            print(f"  ✓ 已添加备注")
            
            # 获取可用的状态转换
            transitions = jira.transitions(issue)
            transition_id = None
            
            # 查找匹配的状态转换
            for t in transitions:
                if any(close_name.lower() in t['name'].lower() for close_name in close_transitions):
                    transition_id = t['id']
                    transition_name = t['name']
                    break
            
            if transition_id:
                # 执行状态转换（关闭Issue）
                jira.transition_issue(issue, transition_id)
                print(f"  ✓ 已将状态转换为 '{transition_name}'")
            else:
                print(f"  ✗ 找不到合适的关闭状态，可用的状态转换: {', '.join(t['name'] for t in transitions)}")
                
        print(f"已完成所有 {len(issues)} 个Jira单的处理")
    
    except JIRAError as e:
        print(f"处理Jira单时出错: {e}")
        sys.exit(1)


def list_issues(jql):
    """
    根据JQL列出Jira单的详细信息
    
    Args:
        jql: JQL查询语句
    """
    jira = connect_jira()
    
    try:
        # 查询符合条件的Issue
        issues = jira.search_issues(jql, maxResults=500)
        print(f"找到 {len(issues)} 个Jira单")
        
        if not issues:
            print("没有找到符合JQL的Jira单")
            return
        
        # 简化输出，只显示单号和标题
        for issue in issues:
            print(f"{issue.key} {issue.fields.summary}")
        
    except JIRAError as e:
        print(f"查询Jira单时出错: {e}")
        sys.exit(1)


def parse_arguments():
    """解析命令行参数"""
    parser = argparse.ArgumentParser(description='Jira批量处理工具')
    subparsers = parser.add_subparsers(dest='command', help='子命令')
    
    # 添加备注并关闭工单的子命令
    close_parser = subparsers.add_parser('close', help='添加备注并关闭Jira单')
    close_parser.add_argument('--jql', required=True, help='JQL查询语句')
    close_parser.add_argument('--comment', help='要添加的备注内容，如不提供将通过输入获取')
    close_parser.add_argument('--transition', help='关闭状态的名称，如果不确定可以不提供')
    
    # 列出工单的子命令
    list_parser = subparsers.add_parser('list', help='列出Jira单的详细信息')
    list_parser.add_argument('--jql', required=True, help='JQL查询语句')
    
    args = parser.parse_args()
    
    # 如果没有提供子命令，显示帮助
    if not args.command:
        parser.print_help()
        sys.exit(1)
        
    return args


def main():
    """主函数"""
    args = parse_arguments()
    
    if args.command == 'close':
        add_comment_and_close_issues(args.jql, args.comment, args.transition)
    elif args.command == 'list':
        list_issues(args.jql)


if __name__ == "__main__":
    main() 