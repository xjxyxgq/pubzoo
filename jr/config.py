import os
import sys
from dotenv import load_dotenv

def load_config():
    """加载配置信息，优先从环境变量读取，如果没有则从.env文件读取"""
    # 尝试加载 .env 文件
    load_dotenv()
    
    # 获取必要的配置
    jira_server = os.environ.get("JIRA_SERVER")
    jira_username = os.environ.get("JIRA_USERNAME")
    jira_password = os.environ.get("JIRA_PASSWORD") or os.environ.get("JIRA_API_TOKEN")
    
    # 检查必要配置是否存在
    if not all([jira_server, jira_username, jira_password]):
        print("错误: 请确保以下环境变量已设置:")
        print("JIRA_SERVER - Jira服务器地址, 例如 https://your-domain.atlassian.net")
        print("JIRA_USERNAME - Jira用户名, 通常是邮箱地址")
        print("JIRA_PASSWORD 或 JIRA_API_TOKEN - Jira密码或API令牌")
        print("\n你可以创建一个.env文件，或者设置系统环境变量")
        sys.exit(1)
    
    return {
        "server": jira_server,
        "username": jira_username,
        "password": jira_password
    } 