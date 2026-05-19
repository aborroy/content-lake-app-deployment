# Local HTTPS with Self-Signed Certificates

Enables HTTPS on the nginx proxy for local development without affecting HTTP.  
Internal service-to-service traffic stays on HTTP inside the Docker network.

## Prerequisites

- OpenSSL installed (`openssl version`)
- Docker Desktop running

## Setup

### 1. Generate the certificate

```bash
bash scripts/generate-local-cert.sh
```

This creates `nginx/certs/local/server.crt` and `server.key` (git-ignored).

### 2. Enable HTTPS in `.env.local`

```bash
echo "USE_HTTPS=true" >> .env.local
```

### 3. Restart the stack

```bash
make down && make up-alfresco   # or up-nuxeo / up-full / up-demo
```

The proxy now:
- Serves HTTPS on port 443
- Redirects HTTP (port 80) → HTTPS

## Browser certificate acceptance

Browsers will warn about the self-signed certificate. Accept it once per browser:

| Browser | How to proceed |
|---------|----------------|
| **Chrome** | Click **Advanced** → **Proceed to localhost (unsafe)** |
| **Firefox** | Click **Advanced** → **Accept the Risk and Continue** |
| **Safari** | Click **Show Details** → **visit this website** → confirm |

## Verify it works

```bash
# HTTPS (ignore cert warning with -k)
curl -k https://localhost/alfresco/api/-default-/public/alfresco/versions/1/probes/-ready-

# HTTP redirect
curl -I http://localhost/aca/
# Expected: 301 Moved Permanently, Location: https://localhost/aca/
```

## Revert to HTTP-only

```bash
echo "USE_HTTPS=false" >> .env.local
make down && make up-alfresco
```

Or remove the `USE_HTTPS` line from `.env.local` entirely (defaults to `false`).

## Troubleshooting

**`nginx: [emerg] cannot load certificate`**  
The cert files are missing. Re-run `bash scripts/generate-local-cert.sh`.

**Port 443 already in use**  
Override the port: `echo "HTTPS_PORT=8443" >> .env.local` then access `https://localhost:8443`.

**Browser still shows HTTP after enabling HTTPS**  
Clear the browser's HSTS cache for `localhost` or use a private/incognito window.
