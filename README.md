# szukaj_cpu

Person detection on live RTSP CCTV streams for small home servers without a dedicated GPU.
A YOLO model runs on the CPU through OpenVINO, video is decoded on the Intel iGPU (VAAPI),
and every detection becomes an event with a thumbnail, a full-resolution frame, a clip cut
from the main stream, an entry in a browsable HTML gallery, a push notification (ntfy) and
a marker on the Shinobi CCTV timeline.

Developed and tested on Debian 13 (OpenMediaVault 8) with an Intel Core i5-7500 (HD 630),
two cameras (Dahua, Tiandy) and Shinobi.

## How it works

```
camera ──► ffmpeg #1: main stream, stream copy ──► RAM segment buffer (/dev/shm)
   │                                               └─► clips, full-resolution frames
   └─────► ffmpeg #2: substream, keyframes only, VAAPI decode ──► YOLO (OpenVINO, CPU)
                                                                   └─► events
events ──► gallery (index.html, wyniki.csv, thumbnails, clips, full frames)
       ──► ntfy notification with photo   ──► Shinobi timeline event (API /motion)
```

* Detection runs on the camera **substream** (1 s keyframe interval, Smart Codec off), so the
  recorded **main stream** can keep Smart Codec / a long GOP and small recordings.
* Substream frames are stretched to the main-stream aspect ratio (e.g. 704×576 → 1024×576).
* The OpenVINO model is exported in 16:9 (e.g. 960×544), so no time is spent on padding.
* Inference uses OpenVINO directly (no PyTorch/Ultralytics at runtime): ~175–195 ms per frame
  with 4 threads on an i5-7500, two cameras at one frame per second each.
* After each event the best moment is re-analysed on the main stream and saved in full
  resolution (JPEG XL, JPEG or WebP).
* Gallery entries, thumbnails, clips and full frames older than `retention_days` are deleted.

## Layout

| Path | Content |
|---|---|
| `/opt/szukaj_cpu/` | program, Python venv, config template, tools, ntfy setup |
| `/usr/bin/szukaj-cpu` | launcher (`--init`, `--test`, `--version`) |
| `/usr/bin/szukaj-cpu-export-tools` | optional model-export tools (Ultralytics + PyTorch) |
| `/usr/lib/systemd/system/szukaj_cpu@.service` | service, one instance per user |
| `~/.szukaj_cpu/szukaj_cpu.toml` | configuration (cameras, paths, ntfy, Shinobi) |
| `~/.szukaj_cpu/models/` | YOLO weights and exported OpenVINO models |
| `~/.szukaj_cpu/ffmpeg`, `ffprobe` | optional static ffmpeg build (used when present) |

## Installation

Build the package (any Debian/Ubuntu machine with `dpkg-deb`):

```bash
bash packaging/build-deb.sh            # → dist/szukaj-cpu_1.0.1_all.deb
```

Install on the server (needs internet access – the post-install step creates the Python
environment with OpenVINO and OpenCV):

```bash
sudo apt install ./szukaj-cpu_1.0.1_all.deb
szukaj-cpu --init                       # creates ~/.szukaj_cpu/szukaj_cpu.toml
nano ~/.szukaj_cpu/szukaj_cpu.toml      # cameras, gallery path, Shinobi, ntfy
sudo usermod -aG render,video $USER     # iGPU access (log in again)
```

A model is exported once per input size. Install the export tools for that step only:

```bash
sudo szukaj-cpu-export-tools install    # Ultralytics + PyTorch (CPU), several hundred MB
szukaj-cpu --test                       # exports the model, checks cameras and Shinobi API
sudo szukaj-cpu-export-tools remove     # optional, the exported model stays
```

Start the service for your user:

```bash
sudo systemctl enable --now szukaj_cpu@$USER
journalctl -u szukaj_cpu@$USER -f
```

### Migrating from the old `install.sh` setup (`~/szukaj_cpu`)

```bash
bash uninstall.sh          # stops szukaj_cpu.service, moves config, models and static
                           # ffmpeg to ~/.szukaj_cpu, removes ~/szukaj_cpu
sudo apt install ./szukaj-cpu_1.0.1_all.deb
sudo systemctl enable --now szukaj_cpu@$USER
```

`uninstall.sh --dry-run` shows what would be done; `--package` removes the .deb,
`--purge` also deletes `~/.szukaj_cpu`.

## Configuration

All options are documented in [`config/szukaj_cpu.toml`](config/szukaj_cpu.toml). Most important:

```toml
[detection]
imgsz = 960                  # model input width; height follows aspect_ratio (16:9 → 544)
threads = 4                  # OpenVINO threads per inference
frame_selection = "keyframes"

[[camera]]
name = "brama"
url = "rtsp://USER:PASS@192.168.1.10:554/cam/realmonitor?channel=1&subtype=0"           # recorded
analysis_url = "rtsp://USER:PASS@192.168.1.10:554/cam/realmonitor?channel=1&subtype=1"  # detection
shinobi_monitor = "MONITOR_ID"
```

Camera settings: in the **substream** set the I-frame interval to the frame rate (1 s) and
turn Smart Codec / H.264+ off. The main stream can stay as it is.

The configuration contains camera passwords and API keys – it is created with mode `600`.

## Local ntfy server

The public ntfy.sh keeps messages and attachments only for a limited time, so a notification
read late may come without its photo. `ntfy/setup-ntfy.sh` installs a local
[ntfy](https://ntfy.sh) server that keeps messages and photos for 5 days (like the gallery),
with access control:

```bash
sudo bash /opt/szukaj_cpu/ntfy/setup-ntfy.sh --config ~/.szukaj_cpu/szukaj_cpu.toml
sudo systemctl restart szukaj_cpu@$USER
```

It installs ntfy from the project's apt repository (archive.ntfy.sh, falling back to the Debian package), writes `/etc/ntfy/server.yml` (port 8092),
creates a write-only user `szukaj_cpu` with a token (written to the config) and a read-only
user for the phone. In the ntfy app add the server, log in and subscribe to the topic
(`szukaj` by default).

* **iOS:** the config sets `upstream-base-url: https://ntfy.sh`, which is required for instant
  notifications from a self-hosted server; only a "poll this topic" signal goes through ntfy.sh,
  the message and photo are fetched from your server.
* **Outside the home network** the phone must reach `base-url`, because photos are downloaded
  from it. If Tailscale is logged in on the server, the script uses its
  `https://<server>.<tailnet>.ts.net` address and enables `tailscale serve` for ntfy
  (tailnet only); on the iPhone set Tailscale *VPN On Demand* to *Always*. Without Tailscale
  it falls back to the LAN address and warns. The address is stored in every message when it
  is sent, so older notifications keep the previous one.
* `ntfy/docker-compose.yml` is an alternative for running ntfy in Docker.

## Optional: minimal static ffmpeg

`tools/build_ffmpeg.sh` builds the latest stable FFmpeg with libjxl, optimised for
`-march=skylake` (Skylake/Kaby Lake), containing only what szukaj_cpu uses. It builds in a
Debian 13 container (Docker or Podman), so it runs on the server's glibc:

```bash
bash tools/build_ffmpeg.sh                      # → ./ffmpeg-szukaj/
scp ffmpeg-szukaj/ffmpeg ffmpeg-szukaj/ffprobe USER@SERVER:~/.szukaj_cpu/
```

With `ffmpeg = "auto"` the static build in `~/.szukaj_cpu/` is used automatically.

## Tools

* `tools/test_przerwy.py` – measures raw OpenVINO inference time (continuous vs. with pauses,
  2 and 4 threads) to tell model speed apart from service overhead.

## Removal

```bash
bash /opt/szukaj_cpu/uninstall.sh --package         # keeps ~/.szukaj_cpu
bash /opt/szukaj_cpu/uninstall.sh --package --purge # also deletes ~/.szukaj_cpu
```

## Notes

* YOLO11 weights are downloaded from Ultralytics on first export and are licensed by
  Ultralytics under AGPL-3.0; they are not part of this repository.
* Logs and comments in the program are in Polish.
