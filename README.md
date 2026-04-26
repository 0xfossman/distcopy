# distcopy

`distcopy.sh` is a Bash utility to download Linux images from a YAML configuration.
It supports clear execution modes (`check`, `wget`, `torrent`, `cron`) and is designed for unattended runs.

## Features

- English-only UI/messages and documentation
- Separate modes:
  - `check` mode
  - `wget` mode
  - `torrent` mode
  - `cron` mode
- Clean downloader choice: `download_method: wget` or `download_method: rtorrent`
- Step-by-step checks with status output (`✅` / `❌`)
- Dependency checks for `wget`, `rtorrent`, and `cron`/`crond`
- Optional dependency installation (interactive + root) using `dialog`
- Stops immediately if `distcopy.yaml` is missing
- Resumable `wget` downloads (`-c`)
- Torrent URLs included (including Arch torrent URL)
- Temporary `.torrent` metadata file is deleted after `rtorrent` finishes
- Log rotation by line count (`log_max_lines`, `log_keep_files`)
- Pruning keeps only `max_files_per_distro` files in wget mode
- Pruning is intentionally skipped in torrent mode to avoid deleting unfinished torrent data

## Supported distros

- Arch Linux
- Debian
- Ubuntu
- OpenWrt x86
- Cachy OS

## Setup config with dialog

```bash
chmod +x distcopy.sh
./distcopy.sh --setup
```

This creates `distcopy.yaml` via a `dialog` checklist.

## Run

```bash
./distcopy.sh
```

If `distcopy.yaml` does not exist, the script exits with an error.

## Modes

Set `mode` in `distcopy.yaml`:

- `check` – run pre-flight checks only
- `wget` – run checks + direct downloads with wget + pruning
- `torrent` – run checks + force rtorrent downloads (no pruning)
- `cron` – run checks + use `cron_download_mode` (`wget`, `torrent`, or `auto`)
  - `auto` uses `download_method` from config (`wget` or `rtorrent`)

## Cron example

```cron
15 3 * * * cd /workspace/distcopy && /workspace/distcopy/distcopy.sh >> /workspace/distcopy/distcopy.log 2>&1
```

## Example `distcopy.yaml`

```yaml
mode: cron
cron_download_mode: auto
download_method: wget
max_files_per_distro: 3
min_free_gb: 5
downloads_dir: downloads
log_max_lines: 2000
log_keep_files: 5
distros:
  - arch_linux
  - debian
  - ubuntu
  - openwrt_x86
  - cachy_os
```
