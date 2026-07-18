# Nextcloud Server Deployment Template

This repository provides a production-ready docker-compose environment for Nextcloud, Collabora Online (CODE), and related services. It includes two distinct deployment methods: a standalone version and a reverse proxy version (with automatic Let's Encrypt SSL via DuckDNS).

## Features
- Nextcloud Hub (PHP-FPM) with Redis caching and MariaDB.
- Collabora Online (CODE) for integrated document editing.
- Dedicated Cron container for background tasks.
- Advanced Nginx configuration with Docker internal DNS resolution to prevent 502 Bad Gateway errors.
- Automated SSL: Fully automatic Let's Encrypt certificate generation using `nginx-proxy` and `acme-companion`.
- Hardware Acceleration Ready: Easily enable NVIDIA GPU support by uncommenting the setup blocks in `docker-compose.yml`.

## NVIDIA GPU Support (Optional)
By default, this stack is configured to run on standard CPUs. If you have an NVIDIA GPU and the Docker NVIDIA toolkit installed:
1. Open the `docker-compose.yml` file in your chosen stack.
2. Under the `nextcloud` and `cron` services, uncomment the `NVIDIA_VISIBLE_DEVICES`, `NVIDIA_DRIVER_CAPABILITIES`, and the `deploy` blocks.
3. Restart your containers to enjoy hardware-accelerated processing (e.g., face recognition, video transcoding).

---

## Versions & Stack Details
- **Nextcloud**: `33.0.5 FPM` (Custom built with Hybrid CUDA 11.8 / 12.6 setup for GPU processing capabilities)
- **MariaDB**: `10.6` (Stable release optimized with custom InnoDB parameters)
- **Redis**: `7-alpine` (Configured with append-only mode for persistence)
- **Collabora Online**: `collabora/code` (Latest Stable with SSL disabled internally for proxying)
- **Web Server**: `nginx:alpine` (Utilizes custom reverse-proxy routing and DNS resolution)
- **Proxy Companion**: `nginx-proxy` & `acme-companion` (For the reverse-proxy stack)

---

## Deployment Options

This repository is split into two directories based on your network environment:

1. **standalone**: Use this if you do not need an external reverse proxy. Nextcloud will bind directly to your host's port 80/443.
2. **with-reverse-proxy**: Use this if you are using a reverse proxy (e.g., Nginx-Proxy) to handle multiple subdomains. This version is pre-configured to work with a dynamic DNS provider such as DuckDNS and automatically provisions Let's Encrypt SSL certificates.

---

## 1. Environment Preparation (Required for both)

Before starting, copy the environment template and configure your credentials.

```bash
cp .env.example .env
```
Edit `.env` and fill in standard variables such as database passwords, Nextcloud administrator credentials, and your domain name (e.g., your-domain.duckdns.org).

---

## 2. Using the Reverse Proxy Version (Recommended)

This version relies on two compose stacks communicating via an external Docker network. It is ideal if you use a dynamic DNS service like DuckDNS to route external traffic to your server and automatically issue Let's Encrypt SSL certificates.

### 2.1. Obtain a Free Domain from DuckDNS
If you do not already have a domain, you can easily get a free one:
1. Go to [DuckDNS.org](https://www.duckdns.org/) and sign in.
2. Under "domains", type a preferred subdomain and click "add domain".
3. Note your full domain name (e.g., `your-domain.duckdns.org`) and update it in the `.env` file.
4. Ensure your home router forwards ports `80` and `443` to your server's internal IP address.

### 2.2. Network Setup
Create the shared proxy network first.
```bash
docker network create proxy-tier
```

### 2.2. Start the Proxy
Navigate to the proxy directory and start the reverse proxy services. This container will handle incoming web traffic and automatically request SSL certificates.
```bash
cd with-reverse-proxy/proxy
docker-compose up -d
```

### 2.3. Start Nextcloud
Navigate to the Nextcloud directory under the reverse proxy folder.
```bash
cd ../nextcloud
docker-compose up -d
```

Your Nextcloud instance is now accessible at your configured DuckDNS domain securely over HTTPS.

---

## 3. Using the Standalone Version

If you prefer to run Nextcloud without an external proxy, use the standalone version.

### 3.1. Edit Nginx Configuration
Navigate to the `standalone` directory. In `nginx.conf`, replace the placeholder domain with your actual server IP or standard domain name.

### 3.2. Start the Stack
Deploy the standalone Nextcloud stack. The Nginx web server will bind directly to port 80 on your host.
```bash
cd standalone
docker-compose up -d
```

---

## Troubleshooting

- **502 Bad Gateway while editing documents**: The Nginx configuration in this repository dynamically resolves the Collabora container IP to prevent caching issues. If you still encounter this error, verify that the `nextcloud-collabora` container is fully mapped to the correct network.
- **SSL Certificate issues (Reverse Proxy)**: Check the Let's Encrypt companion container logs (`docker logs nextcloud-letsencrypt-companion` or similar) to ensure your DuckDNS domain is resolving to the correct IP address.

---

## GPU Troubleshooting (Recognize / Memories)

Field notes from running this stack with an NVIDIA GPU. Three separate failures produced overlapping symptoms; each has a different fix.

### Containers lose GPU access after `systemctl daemon-reload`

`nvidia-smi` inside the container fails with `Failed to initialize NVML: Unknown Error` while the host works fine. The device nodes are still present, but the container's cgroup device permissions are gone. This is a known interaction between systemd reloads and the NVIDIA container runtime.

Fix: restart the affected containers.
```bash
docker restart nextcloud-app nextcloud-cron
```
Photo classification silently falls back to CPU while in this state, so it is worth checking `docker exec nextcloud-app nvidia-smi` whenever classification feels slow.

### Recognize: video tagging (MoviNet) fails on GPU while photos work

Photo tagging uses plain TensorFlow.js kernels and runs on the GPU without issue. Video tagging loads a SavedModel and dies with:

```
NOT_FOUND: could not find registered platform with id: 0x...
  [[{{node movinet_classifier/movinet/stem/stem/conv3d/StatefulPartitionedCall}}]]
```

The prebuilt `libtensorflow` shipped inside `tfjs-node-gpu` never registers the XLA GPU platform ([tensorflow#50458](https://github.com/tensorflow/tensorflow/issues/50458)), and the MoviNet model has `_XlaMustCompile=true` baked into its function defs. The model demands a compiler the runtime does not have.

Workaround: rename the attr key inside `saved_model.pb` to a same-length unknown key. TensorFlow ignores unknown underscore-prefixed attrs and executes the ops as ordinary CUDA kernels. The protobuf stays valid because the byte length is unchanged.

```bash
./scripts/patch_movinet_xla.sh [container-name]   # defaults to nextcloud-app
```

The script backs up the original model before patching. Re-run it after every Recognize app update — updates restore the stock (XLA-enabled) model.

### Recognize: slow video tagging (software decode bottleneck)

Even with GPU inference working, MoviNet spends most of its time in ffmpeg: the app ships a bundled software-only ffmpeg (`ffmpeg-static`), so a 30s 4K HEVC clip takes ~48s just to decode. The GPU's NVDEC engine plus `scale_cuda` cuts this to ~11s (video decode and 4K→176px scaling both on GPU, only tiny frames copied back).

`scripts/patch_movinet_xla.sh` also handles this: it deploys a patched `MovinetModel.js` (kept in `scripts/backups/MovinetModel.js.nvdec`) that uses the system ffmpeg with `-hwaccel cuda` when `RECOGNIZE_GPU=true`, falling back to the bundled software path automatically if hardware decoding fails (e.g. AV1 on cards without AV1 decode). Like the model patch, it is overwritten by app updates — re-run the script afterwards. If an update changed `MovinetModel.js` upstream, diff the stock backup the script saves before blindly re-applying.

### Memories: video playback fails with "failed to connect to go-vod (port 47788)"

Memories spawns its `go-vod` transcoder on demand — unless `memories.vod.external` is set in `config.php`, in which case it waits for an externally managed instance and never starts its own. A leftover `external: true` from an earlier manual setup breaks all transcoded playback.

Two things to know when diagnosing:
- `occ config:list memories` shows the *app* config; the *system* config wins. Check `occ config:system:get memories.vod.external`.
- The missing execute bit on `bin-ext/go-vod-amd64` is a red herring: Memories copies the binary to a temp dir and chmods the copy itself.

Fix:
```bash
docker exec -u 33 nextcloud-app php occ config:system:set memories.vod.external --value=false --type=boolean
```
NVENC transcoding (`memories.vod.nvenc`) works with the Debian `ffmpeg` in this image once the container sees the GPU.
