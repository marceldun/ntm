# 改进点 v7：D 盘文件自动同步与浏览器下载路径恢复

这是完整、独立、可从全新 Ubuntu/Debian VPS 零开始安装的 v7 副本。v1 至 v6 的文件和文档全部保留。

## v7 修复内容

v6 的安装测试调用了手动扫描接口，因此没有真正验证文件放入 D 盘目录后能否由后台自动发现。v7 改为：

- Windows 和 VPS 同时启用文件监控；
- 每 10 秒自动补充扫描一次，文件监控失效时仍会同步；
- 安装测试不调用手动扫描接口，直接等待后台发现并传输文件；
- 同步目录保持为 `D:\IP-国家名-磁盘容量`；
- 自动删除旧版写入 Chrome/Edge 的强制下载目录策略；
- 不设置浏览器下载位置，用户可在浏览器中自由修改；
- 使用独立的 v7 Windows 配置、日志、启动项和 VPS 配对服务；
- 一台电脑仍可导入多台 VPS，每台 VPS 使用独立目录。

## 全新或已有 VPS：只运行这一行

```bash
curl -fL --retry 5 --connect-timeout 15 https://raw.githubusercontent.com/marceldun/ntm/main/v7-auto-rescan-browser-policy-fix/install-vps-v7.sh -o /tmp/install-vps-v7.sh && echo 'dc5139e180134ecb02c7793c187df4610b66ed9daad22e3ac66b35dfbeb8bc2a  /tmp/install-vps-v7.sh' | sha256sum -c - && bash /tmp/install-vps-v7.sh
```

脚本没有输入问题，默认使用：

- 安卓设备 ID：`XFQ7AJQ-34V53ZD-DCIHLSA-7TERDRR-27RXR54-FZCKF4I-F3FHCSC-NV4SZA3`
- 云盘用户名：`marcel`
- 云盘密码：`456qwe456`

VPS 安装完成会打印一整行 Windows 命令。复制到 Windows CMD 运行一次，脚本会创建类似：

```text
D:\202.155.14.177-Indonesia-20GB
```

以后把文件放入这个目录，后台会自动发现并同步到 VPS 云盘。Chrome 和 Edge 的默认下载位置不会被修改。

## v7 独立文件

- `install-vps-v7.sh`：全新或已有 VPS 的完整安装器。
- `windows-auto-sync-v7.ps1`：Windows PowerShell 5.1 完整安装器。
- `device-enroller-v7.py`：电脑自动接收与扫描设置维护服务。
- `cloud-drive/`：完整网页云盘副本。
