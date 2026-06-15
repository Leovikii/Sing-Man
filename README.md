# Sing-Man

A single-file, modular toolkit for Debian/Ubuntu servers — install Sing-box, harden the firewall, deploy common stacks, and patch the kernel from one interactive menu.

## Quick install

```sh
curl -fsSL https://github.com/Leovikii/sm/releases/latest/download/sm.sh -o sm.sh && bash sm.sh
```

```sh
wget -qO sm.sh https://github.com/Leovikii/sm/releases/latest/download/sm.sh && bash sm.sh
```

On first run the script copies itself to `/usr/local/bin/sm.sh`. After that, just type:

```sh
sm.sh
```

## Features

- **Sing-box** — install / upgrade from the official apt repo, manage the systemd service, tail live logs, clean uninstall
- **Config sync** — pull a JSON config from any URL, validate it, hot-reload the service. Your default URL survives self-updates
- **System full-upgrade** — patch kernel CVEs with safe defaults (`force-confold`) and a reboot prompt
- **Common stacks** — install or uninstall **Caddy** and **Docker CE + Compose** with one keypress
- **UFW firewall** — install with sane defaults (22/80/443), add or delete rules with automatic IPv4/IPv6 dual-stack handling
- **TCP tuning** — one-tap BBR / network optimization
- **Self-update** — menu option 9 fetches the latest release and reloads in place
- **Safe uninstall** — auto-detects every component installed via sm and asks per item; Docker data directory requires a second confirmation

## Architecture

`shell/sm.sh` is generated. Source lives in `shell/src/` and is split into atomic modules (`lib/`, `modules/`, `menu/`). Rebuild with:

```sh
bash shell/build.sh
```

## Requirements

- Debian or Ubuntu (or any Debian-derived distro)
- root (`sudo -i`)
