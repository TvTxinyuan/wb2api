@echo off
setlocal
chcp 65001 >nul
title wb2api SSH 隧道（关闭此窗口即断开）

rem ===========================================================================
rem  在你自己的 Windows 电脑上双击运行，不要放到服务器上跑。
rem  作用：把服务器的 wb2api 管理后台 127.0.0.1:8790 映射到本机 http://127.0.0.1:8790/admin
rem  服务器不开任何防火墙端口，公网访问不到。
rem  用法：双击 → 输入服务器公网 IP → 登录用户名直接回车（默认 root）
rem ===========================================================================

set "IP=%~1"
set "USER_NAME=%~2"

if "%IP%"=="" set /p "IP=请输入服务器公网IP（例如 119.91.145.182）: "
if "%IP%"=="" (echo 没有输入 IP，退出。 & pause & exit /b 1)
if "%USER_NAME%"=="" set "USER_NAME=root"

where ssh >nul 2>nul
if errorlevel 1 (
  echo [错误] 这台电脑没有找到 ssh 命令。
  echo 解决：设置 - 系统 - 可选功能 - 添加功能 - 搜索 "OpenSSH 客户端" - 安装，然后重来。
  pause & exit /b 1
)

echo.
echo 正在连接 %USER_NAME%@%IP% ...
echo 第一次连接会问 yes/no，输入 yes 回车；然后输入服务器密码（输入时屏幕不显示，正常）。
echo 连接成功后不要关这个窗口，浏览器打开 http://127.0.0.1:8790/admin
echo.

"%SSH%" -o ConnectTimeout=15 -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 ^
  -N -L 127.0.0.1:8790:127.0.0.1:8790 %USER_NAME%@%IP%

echo.
echo 隧道已断开（网络波动或服务器重启都会这样）。想继续用就重新双击本文件。
pause
