# 改进点 v3：解决 Windows 卡在本地同步服务启动

这是完整、独立、可从全新 Ubuntu/Debian VPS 零开始安装的 v3 副本。v1 和 v2 的全部文件与文档继续保留。

## v3 解决的问题

v2 在 Windows 输出下面两行后，会静默等待本地 Syncthing API：

```text
[1/6] Installing the verified Windows sync engine...
[2/6] Starting and configuring automatic synchronization...
```

如果后台进程提前退出或固定端口冲突，v2 不显示日志，看起来会一直卡住。v3 已将启动过程重新实现：

- 自动停止遗留的 v2 后台进程；
- 在 51 个本地端口中自动选择空闲端口，不再固定使用 28384；
- 使用无空格的相对启动参数，避免 Windows 参数引用问题；
- 保存 Syncthing、标准输出和错误日志；
- 每秒显示启动进度，不再静默卡住；
- 检测进程是否提前退出；
- 第一次失败时自动更换端口并重试；
- 最长等待时间固定，失败会直接显示最后的真实日志；
- 成功后仍会执行 PC→VPS 的真实文件复制验证；
- 继续使用 Syncthing 动态直连/中继，不依赖 VPS 的 443/8443，也没有 WebDAV 约 4GB 限制。

## 全新 VPS 或已有 VPS：只运行这一行

以 root 登录 VPS，执行：

```bash
curl -fL --retry 5 --connect-timeout 15 https://raw.githubusercontent.com/marceldun/ntm/main/v3-windows-service-start-fix/install-vps-v3.sh -o /tmp/install-vps-v3.sh && echo 'fb3bccc5ea7e6f87143794cc681b94d9235ab2ace6092d47ad8a8e9f2dee7756  /tmp/install-vps-v3.sh' | sha256sum -c - && bash /tmp/install-vps-v3.sh
```

脚本没有输入问题，默认使用：

- 安卓设备 ID：`XFQ7AJQ-34V53ZD-DCIHLSA-7TERDRR-27RXR54-FZCKF4I-F3FHCSC-NV4SZA3`
- 云盘用户名：`marcel`
- 云盘密码：`456qwe456`

安装结束会打印已经包含 VPS 设备 ID、随机配对密钥和 SHA-256 的 Windows PowerShell 命令。把那一整行复制到 Windows，只运行一次。

Windows 会自动使用：

```text
C:\Users\你的用户名\Downloads\VPS-Auto-Sync
```

VPS 对应目录：

```text
/var/lib/game-save-sync/saves/电脑下载
```

安卓收到“电脑下载”邀请时选择手机 `Download` 目录并保存一次。已经绑定过时无需再次处理。

## v3 独立文件

- `install-vps-v3.sh`：全新/已有 VPS 完整安装器。
- `windows-auto-sync-v3.ps1`：带端口自选、日志、进程检测和自动重试的 Windows 安装器。
- `device-enroller-v3.py`：随机密钥验证的电脑自动接收服务。
- `cloud-drive/`：完整网页云盘副本。
