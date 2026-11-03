# wb2api 一键部署包

把 [wb2api](https://github.com/xiaofan6ya/wb2api)（原 `workbuddy2api`）部署到一台 Ubuntu 服务器的一键脚本包。
wb2api 是把 WorkBuddy 登录态包装成 **OpenAI / Anthropic / Responses 兼容 API** 的服务，带多账号池、API Key、用量统计和网页管理后台。

> 本包是「部署脚本 + 教程」，不含 wb2api 源码本身——源码会在安装时自动从 GitHub 拉取。

## 文件说明

| 文件 | 跑在哪 | 作用 |
| --- | --- | --- |
| `install-wb2api.sh` | 服务器 | 一键安装（装 Docker → 拉源码 → 生成密码 → 构建启动） |
| `install-wb2api-utf8.sh` | 服务器 | 同上，UTF-8 无 BOM 编码版本（防止 `\r` 报错） |
| `update-wb2api.sh` | 服务器 | 升级用（git pull + 重建镜像） |
| `backup-wb2api.sh` | 服务器 | 备份数据库和配置 |
| `wb2api-tunnel.bat` | Windows | 打开 SSH 隧道，浏览器访问服务器的 8790 后台 |
| `安装教程.md` | 任意 | 面向新手的完整中文图文教程 |

## 快速开始（最简路径）

### 1. 上传脚本（Windows PowerShell）

```powershell
cd 本包所在目录
scp .\install-wb2api.sh .\update-wb2api.sh .\backup-wb2api.sh root@你的服务器公网IP:/root/
```

### 2. 在服务器上安装

```bash
chmod +x /root/install-wb2api.sh
bash /root/install-wb2api.sh
```

安装完成后会打印后台地址、账号、密码（务必保存）。

### 3. 打开后台（Windows）

双击 `wb2api-tunnel.bat` → 输入服务器 IP → 回车 → 输密码，然后浏览器打开：

```
http://127.0.0.1:8790/admin
```

详细步骤、备用方案、常见问题见 `安装教程.md`。

## 版本约定

- 目标系统：Ubuntu 22.04 / 24.04，root 用户
- 安装方式：Docker + Compose，数据库 SQLite（无需 MySQL/Redis）
- 默认分支：`master`，可用 `WB2API_REF=xxx` 指定
- 默认端口：仅绑定 `127.0.0.1:8790`（公网不可达，靠 SSH 隧道访问）
