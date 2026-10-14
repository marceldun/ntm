# 改进点 v2：解决 Windows 无法连接 VPS 443/8443

这是一个完整、独立、可以从全新 Ubuntu/Debian VPS 零开始安装的 v2 副本。上一版文件仍保留在仓库根目录，没有被删除或改名。

## v2 解决的问题

上一版 Windows WebDAV 必须直接访问 VPS 的 443 或 8443 端口。云厂商安全组、运营商或 Windows TLS 组件阻断端口时，会出现：

```text
Cannot reach the VPS cloud drive on port 443 or 8443.
```

v2 的电脑自动同步不再使用 443/8443。Windows 和 VPS 通过 Syncthing 的动态直连或官方中继连接，因此：

- 不受 VPS 网页端口阻断影响；
- 没有 Windows WebDAV 约 4GB 的单文件限制；
- Chrome/Edge 下载完成后自动同步到 VPS，再同步到安卓；
- VPS 只接受持有本机随机配对密钥的 Windows 设备；
- Windows 登录后自动后台启动；
- 保留网页云盘、安卓任意文件夹自动接收和原有游戏存档同步。

## 全新 VPS 或已有 VPS：只运行这一行

使用 root 登录 VPS 后执行：

```bash
curl -fL --retry 5 --connect-timeout 15 https://raw.githubusercontent.com/marceldun/ntm/main/v2-port-connectivity-fix/install-vps-v2.sh -o /tmp/install-vps-v2.sh && echo 'c1802078d5d24c797adde752abefb897f70bdfa78482142cf613448c70843828  /tmp/install-vps-v2.sh' | sha256sum -c - && bash /tmp/install-vps-v2.sh
```

脚本不会询问用户名、密码或设备 ID。默认值为：

- 安卓设备 ID：`XFQ7AJQ-34V53ZD-DCIHLSA-7TERDRR-27RXR54-FZCKF4I-F3FHCSC-NV4SZA3`
- 云盘用户名：`marcel`
- 云盘密码：`456qwe456`

安装结束会打印一整行 Windows PowerShell 命令，其中已经包含当前 VPS 的设备 ID、随机配对密钥和脚本 SHA-256。复制到 Windows 运行一次即可。

Windows 会自动创建并使用：

```text
C:\Users\你的用户名\Downloads\VPS-Auto-Sync
```

Chrome 和 Edge 会自动把新下载写入该目录。Syncthing 在后台把文件传到：

```text
/var/lib/game-save-sync/saves/电脑下载
```

安卓收到一次“电脑下载”邀请后，选择手机 `Download` 目录并保存。Android 的目录授权必须在手机上点击一次，之后不再操作。

## v2 独立文件

- `install-vps-v2.sh`：全新/已有 VPS 完整安装器。
- `windows-auto-sync-v2.ps1`：Windows 一键后台同步安装器。
- `device-enroller-v2.py`：带随机密钥验证的电脑自动接收服务。
- `cloud-drive/`：v2 独立网页云盘副本。
