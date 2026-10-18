# Nextcloud Server Deployment Template

This repository provides a production-ready docker-compose environment for Nextcloud, Collabora Online (CODE), and related services. It includes two distinct deployment methods: a standalone version and a reverse proxy version (with automatic Let's Encrypt SSL via DuckDNS).

## Features
- Nextcloud Hub (PHP-FPM) with Redis caching and MariaDB.
- Collabora Online (CODE) for integrated document editing.
- Dedicated Cron container for background tasks.
- Advanced Nginx configuration with Docker internal DNS resolution for both the Collabora and PHP-FPM backends, so either container can be recreated on a new IP without producing 502 Bad Gateway errors.
- Automated SSL: Fully automatic Let's Encrypt certificate generation using `nginx-proxy` and `acme-companion`.
- Hardware Acceleration Ready: NVIDIA GPU support by switching the service to the bundled CUDA `Dockerfile` and uncommenting the device blocks in `docker-compose.yml`.

## NVIDIA GPU Support (Optional)
By default both stacks run the stock Nextcloud image on standard CPUs. GPU support comes from the `Dockerfile` in the stack directory, which layers CUDA 11.8 + 12.6 and cuDNN on top of that image — passing devices into the stock image is not enough, since it contains no CUDA libraries.

If you have an NVIDIA GPU with the drivers and the NVIDIA container toolkit installed:
1. Open the `docker-compose.yml` file in your chosen stack.
2. Under **both** the `nextcloud` and `cron` services, comment out the `image:` line and uncomment `build: .` so the CUDA image gets built.
3. In the same two services, uncomment `NVIDIA_VISIBLE_DEVICES`, `NVIDIA_DRIVER_CAPABILITIES`, and the `deploy` block.
4. Rebuild and restart: `docker compose up -d --build`. The first build downloads several GB of CUDA packages and takes around 10-15 minutes.

Verify the container actually sees the card before trusting it:
```bash
docker exec nextcloud-app nvidia-smi
```

---

## Versions & Stack Details
- **Nextcloud**: `35.0.2 FPM` — the stock image by default, or the bundled Dockerfile with a hybrid CUDA 11.8 / 12.6 setup when GPU support is enabled. Either way the base carries PHP 8.5 on Debian trixie; the 33.x line carried PHP 8.4 on the same OS.
- **MariaDB**: `10.6` (Stable release optimized with custom InnoDB parameters)
- **Redis**: `7-alpine` (Configured with append-only mode for persistence)
- **Collabora Online**: `collabora/code` (Latest Stable with SSL disabled internally for proxying)
- **Web Server**: `nginx:alpine` (Utilizes custom reverse-proxy routing and DNS resolution)
- **Proxy Companion**: `nginx-proxy` & `acme-companion` (For the reverse-proxy stack)

---

## Deployment Options

This repository is split into two directories based on your network environment:

1. **standalone**: Use this if you do not need an external reverse proxy. Nextcloud binds directly to your host's port 80 and serves plain HTTP — suitable for a LAN-only instance, or behind TLS termination you provide yourself.
2. **with-reverse-proxy**: Use this if you are using a reverse proxy (e.g., Nginx-Proxy) to handle multiple subdomains. This version is pre-configured to work with a dynamic DNS provider such as DuckDNS and automatically provisions Let's Encrypt SSL certificates.

---

## 1. Environment Preparation (Required for both)

Compose reads `.env` from the directory the compose file lives in, so the file belongs **next to the stack you are deploying** — not at the repository root. Copy the template into that directory:

```bash
# reverse proxy version
cp .env.example with-reverse-proxy/nextcloud/.env

# or standalone version
cp .env.example standalone/.env
```

Edit that `.env` and fill in the database passwords, the Nextcloud administrator credentials, and your domain name (e.g. `your-domain.duckdns.org`).

Getting this wrong is quiet rather than loud: Compose substitutes an empty string for every variable it cannot find and only prints a warning. The database then initialises with a blank password, and on the reverse proxy version `VIRTUAL_HOST` ends up empty, so the proxy never routes to the site and no certificate is issued. If `docker compose config` prints `variable is not set` warnings, the file is in the wrong place.

The proxy stack itself (`with-reverse-proxy/proxy`) reads no variables and needs no `.env`.

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

### 2.3. Start the Proxy
Navigate to the proxy directory and start the reverse proxy services. This container will handle incoming web traffic and automatically request SSL certificates.
```bash
cd with-reverse-proxy/proxy
docker compose up -d
```

### 2.4. Start Nextcloud
Navigate to the Nextcloud directory under the reverse proxy folder.
```bash
cd ../nextcloud
docker compose up -d
```

Your Nextcloud instance is now accessible at your configured DuckDNS domain securely over HTTPS.

---

## 3. Using the Standalone Version

If you prefer to run Nextcloud without an external proxy, use the standalone version.

This stack serves plain HTTP on port 80. It does not terminate TLS and does not issue certificates — use the reverse proxy version for that, or put your own TLS terminator in front.

### 3.1. Check the Nginx Configuration
`standalone/nginx.conf` answers on any hostname (`server_name _`), so it works over a LAN IP as-is and normally needs no editing. Set `NEXTCLOUD_DOMAIN` in `.env` to the address you will actually use; it becomes Nextcloud's `overwritehost`.

### 3.2. Start the Stack
Deploy the standalone Nextcloud stack. The Nginx web server will bind directly to port 80 on your host.
```bash
cd standalone
docker compose up -d
```

---

## Upgrading to a New Major Version

Notes from moving this stack 33.0.5 → 34.0.3 and 34.0.4 → 35.0.1 (then 35.0.2). The core upgrade itself is handled by the image entrypoint; almost all of the work is around it.

### One major version per rebuild, but the patch level does not matter

The entrypoint refuses an upgrade only when the image is more than one major version ahead of the installed instance:

```sh
if [ "${image_version%%.*}" -gt "$((${installed_version%%.*} + 1))" ]; then
```

So `33.0.5 → 34.0.3` and `34.0.4 → 35.0.1` are each a single valid hop. There is no need to land on the latest 33.x first, which matters here because every rebuild re-downloads the CUDA layers.

### Check app compatibility before touching the tag

Apps that ship with the server move with it, but App Store apps do not. Query the App Store for the target platform and compare against what is installed:

```bash
curl -s https://apps.nextcloud.com/api/v1/platform/35.0.0/apps.json \
  | jq -r '.[] | select(.id=="recognize") | .releases[] | "\(.version) \(.platformVersionSpec)"'
```

Both **Recognize** and **Richdocuments** pin themselves to a single server major (`>=35.0.0 <36.0.0` for the 35 builds), so each server major requires a matching app major — Recognize 11 → 12 and Richdocuments 10 → 11 for 34, then Recognize 12 → 13 and Richdocuments 11 → 12 for 35. Also check `phpVersionSpec`: the 34 and 35 base images ship PHP 8.5, and apps declaring `<8.6` still pass while anything capped at `<8.5` would not.

The entrypoint updates App Store apps automatically during the upgrade, so these usually need no manual installation — only verification afterwards.

Do not read `releases[0]` as the latest stable release. For 35 the first Memories entry was `9.1.0-alpha.2`, which looked like Memories had no stable build for 35 yet; the entrypoint actually installed the stable `10.0.1`. Filter out pre-releases, or just check `occ app:list` after the upgrade.

### Patch upgrades are much cheaper

Within one major (34.0.3 → 34.0.4, 35.0.1 → 35.0.2) Recognize and Richdocuments do not move, so the models stay in place and the MoviNet patch stays applied. The cost is the image rebuild plus the backup. Run `occ app:list` before and after to see which apps the entrypoint moved.

### Disk space decides the order of operations

The custom GPU image is roughly 8.9 GB, most of it CUDA 11.8 + 12.6 + cuDNN. Building a new one while the old one is still present needs that much free space twice over, and the "reclaimable" figure from `docker system df` is misleading: the Nextcloud and cron images share a base, which the report counts twice.

The workable order is to back up first, delete the old images, and only then build:

```bash
docker compose stop nextcloud cron && docker compose rm -f nextcloud cron
docker images | grep nextcloud     # image names are <compose-project>-nextcloud / -cron,
                                   # where the project defaults to the stack directory name
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

`occ` lives inside the container and runs as the web server user, so every invocation below takes this shape:

```bash
docker exec -u 33 nextcloud-app php occ recognize:download-models
./scripts/patch_movinet_xla.sh
```

One trap: **app commands do not exist while the instance is in maintenance mode**. `occ recognize:download-models` fails with "There are no commands defined in the recognize namespace" rather than a mode warning. Turn maintenance mode off first.

The Recognize 12 update also replaces its bundled Node runtime (20 → 22) while keeping `@tensorflow/tfjs-node-gpu` on 4.x, so the CUDA layers in the Dockerfile need no changes. Recognize 13 (for 35) is the same: Node 22, tfjs 4.22, and the GPU binds with the unchanged Dockerfile. Confirm the GPU path still binds before trusting it:

```bash
docker exec -w /var/www/html/custom_apps/recognize <app> ./bin/node \
  -e "const tf=require('@tensorflow/tfjs-node-gpu');tf.ready().then(()=>console.log(tf.getBackend()))"
```

A successful run logs `Created device /device:GPU:0` and the card name.

### Recreating the app container used to strand the FPM upstream

Rebuilding the image means recreating the Nextcloud container, which can place it on a different IP. Collabora was already resolved through a variable and the Docker resolver, but the PHP-FPM backend was declared as a static `upstream` block — and Nginx resolves those once, at startup. Every request then returned 502 until the web container was restarted.

The configuration in this repository now resolves the FPM backend per request as well:

```nginx
resolver 127.0.0.11 valid=30s;      # in the server block
...
set $fpm_backend nextcloud:9000;    # in each PHP location
fastcgi_pass $fpm_backend;
```

Verified by forcing the app container onto a different address — occupying its old IP with a throwaway container, recreating Nextcloud so it landed elsewhere, and confirming the site still answered 200 with the web container untouched.

If you are running an older copy of this config, the workaround is `docker restart nextcloud-web` after any rebuild.

### Post-upgrade steps

```bash
docker exec -u 33 nextcloud-app php occ db:add-missing-indices
docker exec -u 33 nextcloud-app php occ db:add-missing-columns
docker exec -u 33 nextcloud-app php occ db:add-missing-primary-keys
docker exec -u 33 nextcloud-app php occ maintenance:repair --include-expensive
# the last one sanitizes system tags; upgrades skip it because it is slow
docker exec -u 33 nextcloud-app php occ db:schema:check -v
```

### A migration can be recorded as done while its table is missing

After the 35 upgrade, `db:schema:check` reported `missing table 'oc_federated_invites'` although `oc_migrations` already listed the `cloud_federation_api` migration that creates it. 35 no longer has `occ migrations:execute`, so the migration has to be run again through a normal upgrade. Back up the database first:

```bash
# forget the recorded migration, then make the app look outdated
DELETE FROM oc_migrations WHERE app='cloud_federation_api' AND version='1016Date202502262004';
docker exec -u 33 nextcloud-app php occ config:app:set cloud_federation_api installed_version --value=1.99.0
docker exec -u 33 nextcloud-app php occ upgrade   # re-runs the app migrations and restores the version
```

Use `occ config:app:set` instead of editing `oc_appconfig` directly. Otherwise the Redis cache keeps the old value.

The other findings can stay as they are. `memories_parent_mimetype` and `memories_type_tagid` are indices that Memories adds on purpose.

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
docker exec -u 33 nextcloud-app php occ background-job:execute <job-id> --force-execute
# job-id comes from oc_jobs, class ClassifyMovinetJob
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
