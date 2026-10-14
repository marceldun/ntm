# 改进点 v5：F 盘自动命名并支持一台电脑导入多台 VPS

这是完整、独立、可从全新 Ubuntu/Debian VPS 零开始安装的 v5 副本。v1、v2、v3、v4 的全部文件与文档继续保留。

## v5 解决的问题

v5 保留 v4 的 Windows PowerShell 5.1、端口自选、超时、日志、版本固定和真实传输验证，并新增：

- 电脑统一根目录为 `F:\新建文件夹`；
- 每台 VPS 自动命名为 `IP-国家名-磁盘容量`；
- 每台 VPS 使用独立 Syncthing 文件夹 ID，不会与其他 VPS 合并或覆盖；
- 同一台电脑可按顺序导入 5、10 或 100 台 VPS，已有 VPS 配置会保留；
- 每次导入后，Chrome/Edge 默认下载目录自动切换到刚导入的 VPS 子目录；
- 桌面创建“VPS多服务器同步”入口；
- 自动停止 v2、v3、v4 的旧电脑同步进程和启动项。

## 全新 VPS 或已有 VPS：只运行这一行

以 root 登录 VPS，执行：

```bash
curl -fL --retry 5 --connect-timeout 15 https://raw.githubusercontent.com/marceldun/ntm/main/v5-multi-vps-f-drive/install-vps-v5.sh -o /tmp/install-vps-v5.sh && echo 'ec26c6acbdfd22edcc7204501b22f00fe3118dab6d427d5ac01fb02cd8c11c08  /tmp/install-vps-v5.sh' | sha256sum -c - && bash /tmp/install-vps-v5.sh
```

脚本没有输入问题，默认使用：

- 安卓设备 ID：`XFQ7AJQ-34V53ZD-DCIHLSA-7TERDRR-27RXR54-FZCKF4I-F3FHCSC-NV4SZA3`
- 云盘用户名：`marcel`
- 云盘密码：`456qwe456`

安装结束会打印已经包含 VPS 设备 ID、随机配对密钥和 SHA-256 的 Windows PowerShell 命令。把那一整行复制到 Windows，只运行一次。

Windows 会自动使用类似下面的独立目录：

```text
F:\新建文件夹\202.155.14.177-Indonesia-20GB
```

以后每增加一台 VPS，只运行那台 VPS 安装结束时打印的 Windows 命令一次。所有 VPS 会同时留在同一个 v5 后台同步程序中。

VPS 对应目录类似：

```text
/var/lib/game-save-sync/saves/202.155.14.177-Indonesia-20GB
```

安卓收到“电脑下载”邀请时选择手机 `Download` 目录并保存一次。已经绑定过时无需再次处理。

## v5 独立文件

- `install-vps-v5.sh`：全新/已有 VPS 完整安装器。
- `windows-auto-sync-v5.ps1`：带端口自选、日志、进程检测和自动重试的 Windows 安装器。
- `device-enroller-v5.py`：随机密钥验证的电脑自动接收服务。
- `cloud-drive/`：完整网页云盘副本。
