# 改进点 v6：Windows 中文路径损坏与 D 盘目录修复

这是完整、独立、可从全新 Ubuntu/Debian VPS 零开始安装的 v6 副本。v1 至 v5 的文件和文档全部保留，没有替换或删除。

## v6 解决的问题

v5 在 Windows PowerShell 5.1 中提交 Syncthing 配置时，中文目录可能被编码为 `?????`，导致扫描 `F:\?????\...` 失败。v6 完整修复如下：

- 电脑目录统一改为 `D:\IP-国家名-磁盘容量`，路径中不再包含中文；
- 配置请求明确使用 UTF-8 字节与 `charset=utf-8`；
- 使用独立的 v6 Windows 程序、配置、日志、开机启动项和 VPS 配对服务；
- 自动停止 v2 至 v5 的旧 Windows 同步进程和启动项；
- 同一台电脑仍可依次导入多台 VPS，每台 VPS 使用独立目录；
- Chrome/Edge 自动下载到最后导入的 VPS 目录；
- 保留云盘、安卓自动接收、随机配对密钥和双向同步功能。

## 全新或已有 VPS：只运行这一行

```bash
curl -fL --retry 5 --connect-timeout 15 https://raw.githubusercontent.com/marceldun/ntm/main/v6-windows-encoding-d-drive-fix/install-vps-v6.sh -o /tmp/install-vps-v6.sh && echo '318de41fd3f9d3bb942dca3de2f660e3abe3c2f66fa9e272f743cfe9f957e318  /tmp/install-vps-v6.sh' | sha256sum -c - && bash /tmp/install-vps-v6.sh
```

脚本不询问用户名或密码，默认使用：

- 安卓设备 ID：`XFQ7AJQ-34V53ZD-DCIHLSA-7TERDRR-27RXR54-FZCKF4I-F3FHCSC-NV4SZA3`
- 云盘用户名：`marcel`
- 云盘密码：`456qwe456`

安装完成会打印包含 VPS 设备 ID、随机密钥、文件夹 ID、自动名称和 SHA-256 的 Windows 命令。把打印出的整行复制到 Windows CMD 运行一次即可。

电脑目录示例：

```text
D:\202.155.14.177-Indonesia-20GB
D:\203.0.113.20-Saudi_Arabia-40GB
```

每增加一台 VPS，在新 VPS 运行同一条安装命令，然后在电脑运行它打印的 Windows 命令一次。之前导入的 VPS 会继续保留和同步。

## v6 独立文件

- `install-vps-v6.sh`：全新或已有 VPS 的完整安装器。
- `windows-auto-sync-v6.ps1`：Windows PowerShell 5.1 完整安装器。
- `device-enroller-v6.py`：随机密钥保护的电脑自动接收服务。
- `cloud-drive/`：完整网页云盘副本。
