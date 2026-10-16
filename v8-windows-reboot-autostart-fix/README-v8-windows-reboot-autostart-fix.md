# 改进点 v8：Windows 重启后自动恢复同步

这是完整、独立、可从全新 Ubuntu/Debian VPS 零开始安装的 v8 副本。v1 至 v7 的文件和文档全部保留。

## v8 修复内容

v7 在登录启动目录中直接运行 Syncthing。Windows 登录时如果 D 盘尚未就绪，启动可能失败，并且退出后不会再次启动。v8 改为：

- 登录后启动隐藏的低内存守护程序；
- D 盘尚未出现时自动等待，不会启动到错误目录；
- Syncthing 未运行时每 10 秒自动重新启动；
- 使用绝对配置路径和日志路径，不依赖启动时的工作目录；
- 保留 v7 的十秒补充扫描、双向同步和浏览器策略清理；
- 同步目录仍为 `D:\IP-国家名-磁盘容量`；
- 使用独立的 v8 Windows 配置、日志、启动项和 VPS 配对服务；
- 一台电脑仍可导入多台 VPS。

## 全新或已有 VPS：只运行这一行

```bash
curl -fL --retry 5 --connect-timeout 15 https://raw.githubusercontent.com/marceldun/ntm/main/v8-windows-reboot-autostart-fix/install-vps-v8.sh -o /tmp/install-vps-v8.sh && echo 'aa43e48c7e1d2c07c88a8efbe42ba231a5881553c11d9e39f86efbd5e264cc5a  /tmp/install-vps-v8.sh' | sha256sum -c - && bash /tmp/install-vps-v8.sh
```

脚本没有输入问题，默认使用：

- 安卓设备 ID：`XFQ7AJQ-34V53ZD-DCIHLSA-7TERDRR-27RXR54-FZCKF4I-F3FHCSC-NV4SZA3`
- 云盘用户名：`marcel`
- 云盘密码：`456qwe456`

VPS 安装完成会打印一整行 Windows 命令。复制到 Windows CMD 运行一次，之后电脑登录、D 盘晚到或同步进程异常退出时都会自动恢复。

## v8 独立文件

- `install-vps-v8.sh`：全新或已有 VPS 的完整安装器。
- `windows-auto-sync-v8.ps1`：Windows PowerShell 5.1 完整安装器及启动守护配置。
- `device-enroller-v8.py`：电脑自动接收与扫描设置维护服务。
- `cloud-drive/`：完整网页云盘副本。
