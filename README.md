# Android emulator game-save sync

Ubuntu 22.04/24.04 or Debian 12/13 VPS installer for a native, low-memory Syncthing service.

## Fresh VPS: all-in-one automatic sync and web drive

This installer sets up the low-memory Syncthing service, permanently enables automatic acceptance of folders shared by the preconfigured Android device, and installs the HTTPS web drive. It requires no arguments and no interactive input. The web drive defaults to `marcel` / `456qwe456`:

```bash
curl -fL --retry 3 --connect-timeout 15 https://raw.githubusercontent.com/marceldun/ntm/main/install-auto-sync-cloud.sh -o /tmp/install-auto-sync-cloud.sh && echo 'e2c24b42f02fc7f9edc2df4516dda8ce0767cdbe587f0ffa432ae4b2cbb36270  /tmp/install-auto-sync-cloud.sh' | sha256sum -c - && bash /tmp/install-auto-sync-cloud.sh
```

After adding the printed VPS device ID in Syncthing-Fork, every future folder is configured only on Android: add a folder, select its directory, share it with the VPS, and save. The VPS accepts it below `/var/lib/game-save-sync/saves` and displays it in the web drive without any later VPS command.

On the VPS, run this single command as root and paste the Android Syncthing-Fork device ID when prompted:

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/marceldun/ntm/main/gamesave-sync.sh -o /tmp/gamesave-sync.sh && echo '9d3b568b5e73bbd8779cefcf9933f7264cd73454285033111612a5e74ab93d22  /tmp/gamesave-sync.sh' | sha256sum -c - && bash /tmp/gamesave-sync.sh
```

See [安卓最少步骤.md](安卓最少步骤.md) for the Android setup and the Android 12 limitation affecting AetherSX2 private storage.

## Automatically accept any Android folder

Run this once on an already paired VPS. It allows the VPS to automatically accept future folders shared by that Android device and place them below `/var/lib/game-save-sync/saves`, so no later SSH command is needed.

```bash
curl -fL --retry 3 --connect-timeout 15 https://raw.githubusercontent.com/marceldun/ntm/main/enable-any-folder-sync.sh -o /tmp/enable-any-folder-sync.sh && echo '63ab0d5746035eda76a8841dce517c13a6e00d51f9c81fdecb193ce7e5a94f1f  /tmp/enable-any-folder-sync.sh' | sha256sum -c - && bash /tmp/enable-any-folder-sync.sh
```

For each new folder, add it in Syncthing-Fork on Android, select the local directory, check the paired VPS under shared devices, and save. Android requires this one-time directory selection to grant file access. The VPS then accepts it automatically and the web drive displays it without copying the data.

## Game Save Drive web interface

The synchronized files live at `/var/lib/game-save-sync/saves`. The optional web interface exposes that same directory without duplicating data. It provides authenticated HTTPS, responsive desktop/mobile layouts, uploads, single and multi-select downloads, folder navigation, image previews, list/grid views, and modified-time sorting.

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/marceldun/ntm/main/cloud-drive/install-cloud-drive.sh -o /tmp/install-cloud-drive.sh && echo '398f1805f823b07c24d19382789441cd9e95b65381fb07fbd42380bc20322b44  /tmp/install-cloud-drive.sh' | sha256sum -c - && bash /tmp/install-cloud-drive.sh
```

The installer stores only a PBKDF2 password hash, creates a self-signed HTTPS certificate, starts a low-privilege systemd service, verifies login and directory listing, and prints the final URL. A successful login uses a signed long-lived secure cookie, survives refreshes and service restarts, and remains valid until the user explicitly logs out.
