#!/bin/bash

# 1. 创建 .ssh 目录并设置权限
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# 2. 写入你的公钥（把下面替换成你自己的公钥字符串）
AUTH_KEYS="ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBGOjEzIjPbAH3A5hjxcuLPzUfZluzLr98Hxj7m1ZDrVdr7IllgOKSabKEtFzO1dEGUJX/9GKGHmv9nx4CUdwgfyKKbokjz6EiVOgYUiI4JWzK4R64XNjKB385sWWX2c3RA== administrator@WIN-20260307UYF"
echo "$AUTH_KEYS" > ~/.ssh/authorized_keys

# 3. 严格权限（sshd 强制要求）
chmod 600 ~/.ssh/authorized_keys

# 4. 启动 sshd（常见系统路径，二选一）
# Debian/Ubuntu
/usr/sbin/sshd -p 80
# 或 CentOS
# /usr/sbin/sshd

# 5. 后台启动 frpc（使用你自己的 frpc 配置路径）
cd /mnt/workspace
frpc/frpc

echo "sshd 已启动，frpc 已后台启动"
