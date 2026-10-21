# 改进点 v9：云盘掉线与无法登录自动恢复

这是从 v8 整合出的完整独立版本，可在全新 Ubuntu/Debian VPS 从零安装，也可直接修复已有环境。v1 至 v8 均原样保留。

## v9 修复内容

- 云盘固定使用 8443，重装后地址不会在 443 与 8443 之间变化；
- 默认账号固定为 marcel，密码固定为 456qwe456，安装时不提问；
- 云盘服务开机自启，异常退出后 3 秒自动重启；
- 每分钟执行一次短时 HTTPS 健康检查，服务停止或卡死时自动恢复，不常驻占内存；
- 自动修复目录权限，并在证书过期、损坏或 VPS IP 改变时更新证书；
- 安装过程中真实验证登录、256 KiB 上传、下载哈希和删除；
- 安装过程中强制杀掉云盘进程并验证 systemd 自动拉起；
- 保留 v8 的安卓自动接收、Windows 重启恢复、多 VPS、双向同步及 D:\\IP-国家名-磁盘容量；
- 不修改 Chrome、Edge 或其他浏览器的下载路径。

## 全新安装或修复已有 VPS

只在 VPS 的 root 终端运行 README 发布版本提供的一行命令。完成后固定访问：

https://VPS的IP:8443/

登录信息：

- 用户名：marcel
- 密码：456qwe456

已有 Windows 和安卓同步配置会保留；单纯修复云盘时不需要重装 Windows 客户端。

## 文件

- install-vps-v9.sh：完整 VPS 安装与原地修复脚本。
- cloud-drive/install-cloud-drive-v9.sh：固定端口、证书、登录和自愈服务。
- windows-auto-sync-v9.ps1：完整 Windows 多 VPS 自动同步安装器。
- device-enroller-v9.py：Windows 自动配对服务。
