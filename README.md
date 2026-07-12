# Sing-Man

A single-file, modular toolkit for Debian/Ubuntu servers — install Sing-box, manage its configuration and service, harden UFW, tune TCP, and update the system from one interactive menu.

## Quick install

```sh
curl -fsSL https://github.com/Leovikii/Sing-Man/releases/latest/download/sm.sh -o sm.sh && bash sm.sh
```

```sh
wget -qO sm.sh https://github.com/Leovikii/Sing-Man/releases/latest/download/sm.sh && bash sm.sh
```

On first run the script copies itself to `/usr/local/bin/sm.sh`. After that, just type:

```sh
sm.sh
```

## Features

- **Sing-box** — install / upgrade from the official apt repo, manage the systemd service, tail live logs, clean uninstall
- **Config sync** — pull a JSON config from any URL, validate it, hot-reload the service. Your default URL survives self-updates
- **System full-upgrade** — patch kernel CVEs with safe defaults (`force-confold`) and a reboot prompt
- **UFW firewall** — install with sane defaults (22/80/443), add or delete rules with automatic IPv4/IPv6 dual-stack handling
- **TCP tuning** — one-tap BBR / network optimization
- **Self-update** — menu option 7 fetches the latest release and reloads in place
- **Update channels** — persistently choose stable-only or preview (beta/rc) updates
- **Safer operations** — single-instance locking, HTTPS-only downloads, pinned repository key fingerprint, configuration rollback
- **Safe uninstall** — asks before removing Sing-box, UFW, the management script, and cached state

## Architecture

`shell/sm.sh` is generated. Source lives in `shell/src/` and is split into atomic modules (`lib/`, `modules/`, `menu/`). Rebuild with:

```sh
bash shell/build.sh
```

Pull requests into `main` run CI. Script changes must increase `SCRIPT_VERSION`
in `shell/src/config.sh`. After a successful merge, CD builds and publishes the
matching immutable release. Protect `main` from direct pushes so releases can
only originate from reviewed pull requests.

## Requirements

- Debian or Ubuntu (or any Debian-derived distro)
- root (`sudo -i`)
