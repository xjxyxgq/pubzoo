#! /opt/anaconda3/envs/cmpool/bin/python3
# -*- coding: utf-8 -*-
import pandas as pd
import os

# 确保安装了openpyxl
try:
    import openpyxl
except ImportError:
    print("请先安装 openpyxl: pip install openpyxl")
    exit(1)

def read_ip_list(ip_file_path):
    """从txt文件读取IP列表"""
    if not os.path.exists(ip_file_path):
        raise FileNotFoundError(f"IP列表文件未找到: {ip_file_path}")
    
    try:
        with open(ip_file_path, 'r', encoding='utf-8') as f:
            ips = [line.strip() for line in f if line.strip()]
        
        print(f"从 {ip_file_path} 读取到 {len(ips)} 个IP地址")
        return ips
        
    except Exception as e:
        raise Exception(f"读取IP列表文件错误 {ip_file_path}: {str(e)}")

def read_data_file(file_path):
    """Read data from either xlsx or csv file"""
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"File not found: {file_path}")
    
    file_ext = os.path.splitext(file_path)[1].lower()
    
    try:
        if file_ext == '.xlsx':
            return pd.read_excel(file_path, engine='openpyxl')
        elif file_ext == '.csv':
            return pd.read_csv(file_path)
        else:
            raise ValueError(f"Unsupported file format: {file_ext}. Please use .xlsx or .csv")
    except Exception as e:
        raise Exception(f"Error reading file {file_path}: {str(e)}")

def analyze_host_usage(data_file_path, ip_file_path, show_all=False):
    """
    Analyze individual host resource usage from monitoring data
    
    Args:
        data_file_path (str): Path to the monitoring data file (.xlsx or .csv)
        ip_file_path (str): Path to the IP list file (.txt)
        show_all (bool): Whether to show all hosts regardless of resource utilization
    """
    # Define resource utilization thresholds
    THRESHOLDS = {
        'CPU': 10,    # Maximum CPU utilization threshold
        'MEM': 20,    # Maximum memory utilization threshold
        'DISK': 20    # Maximum disk utilization threshold
    }
    
    # Read IP list file
    try:
        target_ips = read_ip_list(ip_file_path)
    except Exception as e:
        print(f"Error: {e}")
        return
    
    # Read monitoring data file
    try:
        df = read_data_file(data_file_path)
    except Exception as e:
        print(f"Error: {e}")
        return
    
    # Verify required columns exist
    required_columns = ['IP地址', '最大CPU', '最大内存', '最大磁盘']
    missing_columns = [col for col in required_columns if col not in df.columns]
    if missing_columns:
        print(f"Error: Missing required columns: {', '.join(missing_columns)}")
        return
    
    # Filter monitoring data for target IPs
    filtered_df = df[df['IP地址'].isin(target_ips)]
    
    # Check for missing IPs
    found_ips = set(filtered_df['IP地址'].unique())
    missing_ips = set(target_ips) - found_ips
    if missing_ips:
        print(f"Warning: 以下IP在监控数据中未找到:")
        for ip in sorted(missing_ips):
            print(f"  - {ip}")
        print()
    
    print(f"在监控数据中找到 {len(found_ips)} 个IP，共 {len(target_ips)} 个目标IP")
    
    # Analyze resource usage for each host
    underutilized_hosts = []
    
    for _, row in filtered_df.iterrows():
        ip = row['IP地址']
        max_cpu = row['最大CPU']
        max_mem = row['最大内存']
        max_disk = row['最大磁盘']

        trigger = ""
        if max_cpu < THRESHOLDS['CPU']:
            trigger += "#CPU"
        if max_mem < THRESHOLDS['MEM']:
            trigger += "#MEM"
        if max_disk < THRESHOLDS['DISK']:
            trigger += "#DISK"
        
        # Check if resource utilization is below thresholds or show_all is True
        if trigger != "" or show_all:
            underutilized_hosts.append({
                'ip': ip,
                'max_cpu': max_cpu,
                'max_mem': max_mem,
                'max_disk': max_disk,
                'trigger': trigger
            })
    
    # Output analysis results
    if underutilized_hosts:
        # Define column widths
        COL_WIDTHS = {
            'ip': 18,
            'metrics': 12,  # width for each metric column
            'trigger': 15
        }
        
        # Sort by IP address
        sorted_hosts = sorted(underutilized_hosts, key=lambda x: x['ip'])
        
        title = "Hosts with Resource Usage:" if show_all else "Hosts with Underutilized Resources:"
        print(f"\n{title}")
        total_width = COL_WIDTHS['ip'] + COL_WIDTHS['metrics']*3 + COL_WIDTHS['trigger']
        print("-" * total_width)
        
        # Print header
        print(f"{'IP Address':{COL_WIDTHS['ip']}} "
              f"{'Max CPU':{COL_WIDTHS['metrics']}} "
              f"{'Max Mem':{COL_WIDTHS['metrics']}} "
              f"{'Max Disk':{COL_WIDTHS['metrics']}} "
              f"{'Trigger':{COL_WIDTHS['trigger']}}")
        print("-" * total_width)
        
        for host in sorted_hosts:
            # Format each metric with percentage
            cpu_str = f"{host['max_cpu']:.2f}%"
            mem_str = f"{host['max_mem']:.2f}%"
            disk_str = f"{host['max_disk']:.2f}%"
            
            print(f"{host['ip']:{COL_WIDTHS['ip']}} "
                  f"{cpu_str:{COL_WIDTHS['metrics']}} "
                  f"{mem_str:{COL_WIDTHS['metrics']}} "
                  f"{disk_str:{COL_WIDTHS['metrics']}} "
                  f"{host['trigger']:{COL_WIDTHS['trigger']}}")
        
        print(f"\n统计信息:")
        print(f"  - 符合条件的主机数量: {len(sorted_hosts)}")
        print(f"  - 总目标主机数量: {len(target_ips)}")
        if not show_all:
            print(f"  - 低使用率主机比例: {len(sorted_hosts)/len(found_ips)*100:.1f}%")
            
    else:
        print("No hosts found with the specified criteria")

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description='Analyze individual host resource usage from monitoring data')
    parser.add_argument('--data', '-d', 
                       required=True,
                       help='Path to the monitoring data file (.xlsx or .csv)')
    parser.add_argument('--ips', '-i', 
                       required=True,
                       help='Path to the IP list file (.txt)')
    parser.add_argument('--all', '-a', 
                       action='store_true',
                       help='Show all hosts regardless of resource utilization')
    
    args = parser.parse_args()
    analyze_host_usage(args.data, args.ips, args.all) 