# Sing-Man

A single-file, modular toolkit for Debian/Ubuntu servers and OpenWrt 25+ (APK). Manage Sing-box, its configuration and service, and the management script. Debian/Ubuntu also provides UFW, TCP tuning and system updates.

## Quick install

```sh
curl -fsSL https://github.com/Leovikii/Sing-Man/releases/latest/download/sm.sh -o sm.sh && bash sm.sh
```

```sh
wget -qO sm.sh https://github.com/Leovikii/Sing-Man/releases/latest/download/sm.sh && bash sm.sh
```

For CDN-accelerated downloads, use the same Action-built Release asset through the third-party `gh-proxy.com` CDN:

```sh
wget -O sm.sh https://gh-proxy.com/https://github.com/Leovikii/Sing-Man/releases/latest/download/sm.sh && bash sm.sh
```

```sh
curl -fsSL https://gh-proxy.com/https://github.com/Leovikii/Sing-Man/releases/latest/download/sm.sh -o sm.sh && bash sm.sh
```

These links download the latest published Release. The generated `shell/sm.sh` is not committed to the repository, so jsDelivr's repository-file URLs cannot serve the complete script.

For OpenWrt, install Bash and the HTTPS downloader first (run as root):

```sh
apk update && apk add bash curl ca-bundle
curl -fsSL https://github.com/Leovikii/Sing-Man/releases/latest/download/sm.sh -o /tmp/sm.sh && bash /tmp/sm.sh
```

On first run the script copies itself to `/usr/local/bin/sm.sh` on Debian/Ubuntu or `/usr/bin/sm.sh` on OpenWrt. After that, just type:

```sh
sm.sh
```

## Features

- **Sing-box** — Debian/Ubuntu uses the official apt repo and systemd; OpenWrt installs the latest stable OpenWrt APK from official SagerNet GitHub Releases, verifies its SHA-256 digest, and uses the package's native procd/UCI service and logread
- **Autostart management (3.3.1)** — main/service menus show boot status separately from runtime status; enable or disable boot startup through native systemd or OpenWrt procd/UCI, without starting or stopping the service
- **Config sync** — pull a JSON config from any URL, validate it, hot-reload the service. Your default URL survives self-updates
- **System full-upgrade** — patch kernel CVEs with safe defaults (`force-confold`) and a reboot prompt
- **UFW firewall** — install with sane defaults (22/80/443), add or delete rules with automatic IPv4/IPv6 dual-stack handling
- **TCP tuning** — one-tap BBR / network optimization
- **Self-update** — menu option 7 fetches the latest release and reloads in place
- **Update channels** — persistently choose stable-only or preview (beta/rc) updates
- **Safer operations** — single-instance locking, HTTPS-only downloads, pinned repository key fingerprint, configuration rollback
- **Safe uninstall** — asks before removing Sing-box, UFW, the management script, and cached state

## Boot startup (3.3.1)

Service menu options 6 and 7 enable or disable boot startup without changing the current running state. Manual start, stop and restart preserve the boot startup choice. First installation enables startup by default; core updates and OpenWrt APK rollback preserve the existing choice. A stopped service stays stopped after a core update.

On Debian/Ubuntu, status comes from `systemctl is-enabled`. Masked, temporary, static, missing and unavailable services are shown separately; the script never automatically unmasks a service. Query failures are shown as unknown, not disabled.

On OpenWrt, disabling startup removes the native rc.d startup links and leaves the UCI service permission available for manual start. Enabling startup also enables `sing-box.main.enabled`. If startup links exist but UCI blocks the service, the menu reports that startup cannot take effect. Manually starting this blocked service enables its UCI permission and disables boot startup, keeping effective startup off. Native true values (`1`, `on`, `true`, `yes`, `enabled`) are respected.

## OpenWrt support (3.3.0)

Only OpenWrt 25 and newer with `apk` is supported. Older `opkg` releases and unversioned SNAPSHOT builds are rejected. The script requires Bash; it does not run under BusyBox ash.

| Feature | Debian / Ubuntu | OpenWrt 25+ (APK) |
| --- | --- | --- |
| Sing-box install, update, uninstall | Official APT repository | Official GitHub stable OpenWrt APK |
| Service and live logs | systemd / journalctl | procd / ubus / logread |
| Boot startup status and enable/disable | systemd | procd rc.d + UCI |
| Config download, validation and rollback | Yes | Yes |
| Script self-update and stable/preview channels | Yes | Yes |
| System full-upgrade, UFW, TCP/BBR tuning | Yes | Unavailable |

OpenWrt hides menu options 4–6 and blocks their execution. The script does not configure firewall rules, routing, DNS, network interfaces, TUN devices or kernel parameters. Configure any networking required by your Sing-box configuration yourself. APK resolves the official package's dependencies, including `firewall4`, `kmod-tun`, `kmod-inet-diag` and `kmod-nft-queue`; their installation is part of the upstream package requirements.

The core always follows the official **stable** Release channel, independently of the script's stable/preview channel. The asset must exactly match `sing-box_<version>_openwrt_<apk --print-arch>.apk` and provide a valid GitHub Release SHA-256 digest. Unsupported architectures or failed verification stop installation. The verified local APK is installed with `apk add --allow-untrusted` because upstream APKs are not signed by the device's repository keys; the system trust store is unchanged. No global `apk upgrade` is run.

Existing APK-managed Sing-box installations can be managed directly. The script refuses to overwrite non-APK installations or conflicting binaries in PATH. Existing configuration is preserved and checked with the new core before an update; a custom absolute UCI `sing-box.main.conffile` path is respected. A running service is restarted after updating; a stopped service stays stopped. If an update fails to start, the script attempts to download, verify and reinstall the previous official stable APK. Recovery requires that release's matching APK and network access; failures are reported for manual recovery. A fresh installation replaces the package's public-listening example with a minimal configuration with no listening ports.

OpenWrt paths:

- Script: `/usr/bin/sm.sh`
- Persistent script settings (saved config URL, update date and channel): `/etc/sm/`
- Core: `/usr/bin/sing-box`; configuration: `/etc/sing-box/config.json`
- Native service: `/etc/init.d/sing-box`; UCI: `/etc/config/sing-box`; working directory follows UCI `sing-box.main.workdir` (upstream default: `/usr/share/sing-box`)

Native commands remain available:

```sh
/etc/init.d/sing-box start
/etc/init.d/sing-box stop
/etc/init.d/sing-box restart
/etc/init.d/sing-box enable
/etc/init.d/sing-box disable
logread -e sing-box
```

Uninstalling the core uses `apk del sing-box`, retaining its shared dependencies. JSON and UCI configuration are preserved unless you explicitly choose to delete them. Firewall/network settings are not removed. After a firmware sysupgrade, check installed packages and reinstall the APK and script if necessary; automatic restoration is outside this release's scope.

## Architecture

`shell/sm.sh` is generated. Source lives in `shell/src/` and is split into atomic modules (`lib/`, `modules/`, `menu/`). Rebuild with:

```sh
bash shell/build.sh
bash shell/tests/regression.sh
bash shell/tests/openwrt.sh
bash shell/tests/autostart.sh
# On a systemd host:
sudo bash shell/tests/autostart.sh --systemd
```

Pull requests into `main` run CI. Script changes must increase `SCRIPT_VERSION`
in `shell/src/config.sh`. After a successful merge, CD builds and publishes the
matching immutable release. Protect `main` from direct pushes so releases can
only originate from reviewed pull requests.

## Requirements

- Debian or Ubuntu (or a Debian-derived distro), or OpenWrt 25+ using APK
- root (`sudo -i`)
- Bash; sufficient free RAM in `/tmp` for the downloaded APK and extracted core, and writable storage for package installation
