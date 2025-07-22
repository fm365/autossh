#!/bin/bash
# SSH 全互信配置工具（修复 expect 提示符匹配，适用于 root 用户自动配置免密）

set -euo pipefail

# 参数初始化
IP_FILE="ip_list.txt"
PORT="22"
USER="root"
PASSWORD=""
USE_SUDO=0
LOG_FILE="ssh_mutual_trust.log"
TMP_DIR="/tmp/ssh-mutual-trust"
KEY_NAME="id_rsa"
PUB_ALL="$TMP_DIR/all_authorized_keys"

# 解析参数
while [[ $# -gt 0 ]]; do
  case $1 in
    -f) IP_FILE="$2"; shift 2 ;;
    -u) USER="$2"; shift 2 ;;
    -p) PORT="$2"; shift 2 ;;
    -P) PASSWORD="$2"; shift 2 ;;
    --sudo) USE_SUDO=1; shift ;;
    --log) LOG_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 -f ip_list.txt -u root -P password [--sudo]"
      exit 0 ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
done

# 环境准备
command -v expect >/dev/null || { echo "❌ 请先安装 expect 工具"; exit 1; }
mkdir -p "$TMP_DIR"
> "$LOG_FILE"
> "$PUB_ALL"

mapfile -t IP_LIST < "$IP_FILE"
[[ ${#IP_LIST[@]} -eq 0 ]] && echo "❌ IP 列表为空" && exit 1

echo "ð ️ 开始配置 SSH 全互信..." | tee -a "$LOG_FILE"

# Step 1: 每台主机生成密钥并导出 .pub
for ip in "${IP_LIST[@]}"; do
  echo "[1] 处理 $ip：生成密钥对 + 拉取公钥" | tee -a "$LOG_FILE"

  /usr/bin/expect <<EOF
set timeout 60
spawn ssh -q -o StrictHostKeyChecking=no -p $PORT $USER@$ip
expect {
    "(yes/no)?" { send "yes\r"; exp_continue }
    "*assword:" { send "$PASSWORD\r"; exp_continue }
    "*# " {}
    "*\\\$ " {}
}
send -- "export PS1='# '\r"
send -- "mkdir -p ~/.ssh\r"
#send -- "[ -f ~/.ssh/$KEY_NAME.pub ] || ssh-keygen -t rsa -b 4096 -f ~/.ssh/$KEY_NAME -N ''\r"
send -- "test -f ~/.ssh/$KEY_NAME.pub || ssh-keygen -t rsa -b 4096 -f ~/.ssh/$KEY_NAME -N ''\r"
send -- "exit\r"
expect eof
EOF

  /usr/bin/expect <<EOF
set timeout 30
spawn scp -P $PORT $USER@$ip:~/.ssh/$KEY_NAME.pub $TMP_DIR/${ip}.pub
expect {
  "(yes/no)?" { send "yes\r"; exp_continue }
  "*assword:" { send "$PASSWORD\r"; exp_continue }
  eof
}
EOF
done

# Step 2: 合并所有公钥
echo "[2] 合并所有公钥..." | tee -a "$LOG_FILE"
cat $TMP_DIR/*.pub | sort | uniq > "$PUB_ALL"

# Step 3: 分发到每台服务器
for ip in "${IP_LIST[@]}"; do
  echo "[3] 分发 authorized_keys 到 $ip" | tee -a "$LOG_FILE"

  /usr/bin/expect <<EOF
set timeout 30
spawn scp -P $PORT "$PUB_ALL" $USER@$ip:/tmp/authorized_keys
expect {
  "(yes/no)?" { send "yes\r"; exp_continue }
  "*assword:" { send "$PASSWORD\r"; exp_continue }
  eof
}
EOF

  if [[ "$USE_SUDO" -eq 1 ]]; then
    /usr/bin/expect <<EOF
set timeout 30
spawn ssh -q -o StrictHostKeyChecking=no -p $PORT $USER@$ip
expect {
  "*assword:" { send "$PASSWORD\r"; exp_continue }
  "*# " {}
  "*\\\$ " {}
}
send -- "echo '$PASSWORD' | sudo -S mkdir -p /root/.ssh\r"
send -- "echo '$PASSWORD' | sudo -S cp /tmp/authorized_keys /root/.ssh/authorized_keys\r"
send -- "sudo chmod 600 /root/.ssh/authorized_keys && sudo chmod 700 /root/.ssh\r"
send -- "rm -f /tmp/authorized_keys\r"
send -- "exit\r"
expect eof
EOF
  else
    /usr/bin/expect <<EOF
set timeout 30
spawn ssh -q -o StrictHostKeyChecking=no -p $PORT $USER@$ip
expect {
  "*assword:" { send "$PASSWORD\r"; exp_continue }
  "*# " {}
  "*\\\$ " {}
}
send -- "mkdir -p ~/.ssh\r"
send -- "mv /tmp/authorized_keys ~/.ssh/authorized_keys\r"
send -- "chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh\r"
send -- "exit\r"
expect eof
EOF
  fi
done

echo -e "\n✅ 所有服务器之间的 SSH 全互信配置完成！" | tee -a "$LOG_FILE"
