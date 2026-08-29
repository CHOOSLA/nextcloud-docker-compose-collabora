# Nextcloud Server Deployment Template

This repository provides a production-ready docker-compose environment for Nextcloud, Collabora Online (CODE), and related services. It includes two distinct deployment methods: a standalone version and a reverse proxy version (with automatic Let's Encrypt SSL via DuckDNS).

## Features
- Nextcloud Hub (PHP-FPM) with Redis caching and MariaDB.
- Collabora Online (CODE) for integrated document editing.
- Dedicated Cron container for background tasks.
- Advanced Nginx configuration with Docker internal DNS resolution for the Collabora backend, so its container IP can change without producing 502 Bad Gateway errors. (The PHP-FPM backend uses a static `upstream` block — see the upgrade notes below.)
- Automated SSL: Fully automatic Let's Encrypt certificate generation using `nginx-proxy` and `acme-companion`.
- Hardware Acceleration Ready: Easily enable NVIDIA GPU support by uncommenting the setup blocks in `docker-compose.yml`.

## NVIDIA GPU Support (Optional)
By default, this stack is configured to run on standard CPUs. If you have an NVIDIA GPU and the Docker NVIDIA toolkit installed:
1. Open the `docker-compose.yml` file in your chosen stack.
2. Under the `nextcloud` and `cron` services, uncomment the `NVIDIA_VISIBLE_DEVICES`, `NVIDIA_DRIVER_CAPABILITIES`, and the `deploy` blocks.
3. Restart your containers to enjoy hardware-accelerated processing (e.g., face recognition, video transcoding).

---

## Versions & Stack Details
- **Nextcloud**: `34.0.3 FPM` (Custom built with Hybrid CUDA 11.8 / 12.6 setup for GPU processing capabilities). The base image carries PHP 8.5 on Debian trixie; the 33.x line carried PHP 8.4 on the same OS.
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

## Upgrading to a New Major Version

Notes from moving this stack from 33.0.5 to 34.0.3. The core upgrade itself is handled by the image entrypoint; almost all of the work is around it.

### One major version per rebuild, but the patch level does not matter

The entrypoint refuses an upgrade only when the image is more than one major version ahead of the installed instance:

```sh
if [ "${image_version%%.*}" -gt "$((${installed_version%%.*} + 1))" ]; then
```

So `33.0.5 → 34.0.3` is a single valid hop. There is no need to land on the latest 33.x first, which matters here because every rebuild re-downloads the CUDA layers.

### Check app compatibility before touching the tag

Apps that ship with the server move with it, but App Store apps do not. Query the App Store for the target platform and compare against what is installed:

```bash
curl -s https://apps.nextcloud.com/api/v1/platform/34.0.0/apps.json \
  | jq -r '.[] | select(.id=="recognize") | .releases[] | "\(.version) \(.platformVersionSpec)"'
```

Both **Recognize** and **Richdocuments** pin themselves to a single server major (`>=34.0.0 <35.0.0`), so each server major requires a matching app major — Recognize 11 → 12, Richdocuments 10 → 11 in this case. Also check `phpVersionSpec`: the 34 base image ships PHP 8.5, and apps declaring `<8.6` still pass while anything capped at `<8.5` would not.

The entrypoint updates App Store apps automatically during the upgrade, so these usually need no manual installation — only verification afterwards.

### Disk space decides the order of operations

The custom GPU image is roughly 8.9 GB, most of it CUDA 11.8 + 12.6 + cuDNN. Building a new one while the old one is still present needs that much free space twice over, and the "reclaimable" figure from `docker system df` is misleading: the Nextcloud and cron images share a base, which the report counts twice.

The workable order is to back up first, delete the old images, and only then build:

```bash
docker compose stop nextcloud cron && docker compose rm -f nextcloud cron
docker rmi <project>-nextcloud <project>-cron
docker compose build nextcloud
```

Rollback does not depend on keeping the old image around. Point `FROM` back at the previous tag and rebuild — old tags remain on Docker Hub. What does need backing up is the database and the `nextcloud` volume, which holds `custom_apps` including several GB of Recognize models:

```bash
docker exec <db> mariadb-dump --single-transaction -u root -p<pw> <db> > nextcloud.sql
docker run --rm -v <project>_nextcloud:/src:ro -v /backup:/dst alpine tar cf /dst/html.tar -C /src .
```

### Recognize models are not in the app package

The App Store tarball is under 100 MB; the models are fetched separately. An app update therefore wipes `custom_apps/recognize/models` entirely (~1.2 GB). Re-download them and re-apply the patches:

```bash
occ recognize:download-models
./scripts/patch_movinet_xla.sh
```

One trap: **app commands do not exist while the instance is in maintenance mode**. `occ recognize:download-models` fails with "There are no commands defined in the recognize namespace" rather than a mode warning. Turn maintenance mode off first.

The Recognize 12 update also replaces its bundled Node runtime (20 → 22) while keeping `@tensorflow/tfjs-node-gpu` on 4.x, so the CUDA layers in the Dockerfile need no changes. Confirm the GPU path still binds before trusting it:

```bash
docker exec -w /var/www/html/custom_apps/recognize <app> ./bin/node \
  -e "const tf=require('@tensorflow/tfjs-node-gpu');tf.ready().then(()=>console.log(tf.getBackend()))"
```

A successful run logs `Created device /device:GPU:0` and the card name.

### Recreating the app container breaks the FPM upstream

`nginx.conf` resolves Collabora through a variable and the Docker resolver, so its IP may change freely. The PHP-FPM backend is declared as a static `upstream` block, which Nginx resolves once at startup. Recreating the Nextcloud container gives it a new IP and every request returns 502 until the web container is restarted:

```bash
docker restart nextcloud-web
```

Worth doing as the last step of any upgrade that recreates the app container.

### Post-upgrade steps

```bash
occ db:add-missing-indices
occ db:add-missing-columns
occ db:add-missing-primary-keys
occ maintenance:repair --include-expensive   # sanitizes system tags; skipped during upgrades because it is slow
```

### The code integrity error is expected here

`occ setupchecks` reports a failed integrity check for `core/js/mimetypelist.js` (invalid hash) and `core/img/filetypes/*.svg` (extra files). This is not upgrade damage — the Drawio app registers custom mimetypes, which writes icons into the core directory and regenerates the mimetype list. It is present before and after the upgrade, and it will reappear whenever Drawio is installed.

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

VRAM caveat: NVDEC needs a few hundred MB of GPU memory on top of what TensorFlow already holds (~1.8GB for MoviNet inference). On a 3GB card shared with other GPU workloads the decode context often fails to allocate and the classifier silently falls back to software decoding — watch for "NVDEC transcoding failed" in the log. Cards with 6GB+ (or a GPU not shared with other services) get the full speedup.

### Recognize: queue stops processing outside 01:00–05:00 UTC

Not a bug. Recognize classifier jobs are registered as `TIME_INSENSITIVE`, and Nextcloud only runs such jobs inside the maintenance window (`maintenance_window_start` system config, default window = start hour + 4h, UTC). Outside the window the queue simply waits — check `occ config:system:get maintenance_window_start` before debugging. To drain a large backlog immediately, force the job in a loop:

```bash
occ background-job:execute <job-id> --force-execute   # job-id from oc_jobs, class ClassifyMovinetJob
```

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
