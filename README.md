# Android emulator game-save sync

Ubuntu 22.04/24.04 or Debian 12/13 VPS installer for a native, low-memory Syncthing service.

On the VPS, run this single command as root and paste the Android Syncthing-Fork device ID when prompted:

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/marceldun/ntm/main/gamesave-sync.sh -o /tmp/gamesave-sync.sh && echo '9d3b568b5e73bbd8779cefcf9933f7264cd73454285033111612a5e74ab93d22  /tmp/gamesave-sync.sh' | sha256sum -c - && bash /tmp/gamesave-sync.sh
```

See [安卓最少步骤.md](安卓最少步骤.md) for the Android setup and the Android 12 limitation affecting AetherSX2 private storage.
