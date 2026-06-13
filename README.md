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
