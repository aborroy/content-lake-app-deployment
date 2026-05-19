# HTTPS on EC2 with Let's Encrypt

Adds a trusted TLS certificate to the nginx proxy using Let's Encrypt / Certbot.
No changes to compose files or the nginx template are required beyond what the
`USE_HTTPS` flag already controls.

## Prerequisites

- An EC2 instance with a **public domain name** pointing to its Elastic IP
  (see `DEPLOY_EC2.md` sections 2--3).
- **Port 443 open** in the EC2 security group (add it alongside port 80).
- The stack running and reachable at `http://<your-domain>/`.

## 1. Open Port 443 in the Security Group

In the AWS console, add an inbound rule to the instance's security group:

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 443  | TCP      | Your IP (or `0.0.0.0/0` for public access) | HTTPS |

Or via the AWS CLI:

```bash
SG_ID=$(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0
```

## 2. Install Certbot

```bash
sudo apt-get update
sudo apt-get install -y certbot
```

## 3. Obtain a Certificate

Certbot's standalone mode spins up a temporary HTTP server on port 80 to complete
the Let's Encrypt challenge. The stack must be **stopped** while it runs so port 80
is free.

```bash
make down

sudo certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --email you@example.com \
  --domain content-lake.example.com
```

Replace `you@example.com` and `content-lake.example.com` with your values.

On success, Certbot writes the certificate to:

```
/etc/letsencrypt/live/content-lake.example.com/fullchain.pem
/etc/letsencrypt/live/content-lake.example.com/privkey.pem
```

## 4. Copy the Certificate into the Stack

The nginx proxy reads certs from `nginx/certs/local/` (git-ignored). Copy the
Let's Encrypt files there:

```bash
mkdir -p nginx/certs/local

sudo cp /etc/letsencrypt/live/content-lake.example.com/fullchain.pem \
        nginx/certs/local/server.crt

sudo cp /etc/letsencrypt/live/content-lake.example.com/privkey.pem \
        nginx/certs/local/server.key

sudo chown $USER:$USER nginx/certs/local/server.crt nginx/certs/local/server.key
chmod 644 nginx/certs/local/server.crt
chmod 600 nginx/certs/local/server.key
```

## 5. Enable HTTPS in `.env.local`

```bash
cat >> .env.local << 'EOF'
SERVER_NAME=content-lake.example.com
USE_HTTPS=true
EOF
```

## 6. Restart the Stack

```bash
make up-demo   # or up-alfresco / up-nuxeo / up-full
```

The proxy now:
- Serves HTTPS on port 443 with the Let's Encrypt certificate
- Redirects HTTP (port 80) → HTTPS

## 7. Verify

```bash
# Certificate details -- should show Let's Encrypt issuer, not self-signed
echo | openssl s_client -connect content-lake.example.com:443 -servername content-lake.example.com 2>/dev/null \
  | openssl x509 -noout -issuer -dates

# HTTPS endpoints (no -k needed -- certificate is trusted)
curl -s -o /dev/null -w "%{http_code}\n" https://content-lake.example.com/
curl -s -o /dev/null -w "%{http_code}\n" https://content-lake.example.com/aca/
curl -s -o /dev/null -w "%{http_code}\n" https://content-lake.example.com/api/rag/health

# HTTP redirect
curl -I http://content-lake.example.com/
# Expected: 301 Moved Permanently, Location: https://content-lake.example.com/
```

## 8. Automate Certificate Renewal

Let's Encrypt certificates expire after 90 days. Set up a cron job that renews
the certificate and refreshes the stack's copy automatically.

Create `/etc/cron.d/certbot-content-lake`:

```bash
sudo tee /etc/cron.d/certbot-content-lake << 'EOF'
# Renew Let's Encrypt certificate for content-lake.
# Runs at 02:30 on the 1st and 15th of each month.
# Stops the stack, renews, copies new cert, restarts.
30 2 1,15 * * ubuntu /home/ubuntu/content-lake-app-deployment/scripts/renew-cert.sh >> /var/log/certbot-content-lake.log 2>&1
EOF
```

Create `scripts/renew-cert.sh` in the repository:

```bash
cat > scripts/renew-cert.sh << 'EOF'
#!/usr/bin/env bash
# Renew the Let's Encrypt certificate and reload the nginx proxy.
# Called by cron -- must be self-contained.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="${SERVER_NAME:-$(grep SERVER_NAME "$REPO_DIR/.env.local" | cut -d= -f2)}"
CERT_DIR="$REPO_DIR/nginx/certs/local"

cd "$REPO_DIR"

echo "[$(date)] Stopping stack for certificate renewal..."
make down

echo "[$(date)] Renewing certificate for $DOMAIN..."
certbot renew --non-interactive --standalone --domain "$DOMAIN"

echo "[$(date)] Copying renewed certificate..."
cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CERT_DIR/server.crt"
cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem"   "$CERT_DIR/server.key"
chown "$USER:$USER" "$CERT_DIR/server.crt" "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"
chmod 600 "$CERT_DIR/server.key"

echo "[$(date)] Restarting stack..."
make up-demo   # adjust target if not using the demo profile

echo "[$(date)] Renewal complete."
EOF

chmod +x scripts/renew-cert.sh
```

Test the renewal script manually before relying on cron:

```bash
bash scripts/renew-cert.sh
```

> Certbot will skip the actual renewal if the certificate is not yet due to
> expire (valid for more than 30 days) and the stack will be restarted anyway.
> This is safe.

## Troubleshooting

**`certbot: error: port 80 already in use`**  
Run `make down` before running `certbot certonly`.

**`nginx: [emerg] cannot load certificate`**  
The cert files are missing from `nginx/certs/local/`. Re-run step 4.

**`curl: (60) SSL certificate problem: certificate has expired`**  
The 90-day certificate was not renewed. Run `bash scripts/renew-cert.sh` manually
and check the cron log at `/var/log/certbot-content-lake.log`.

**Alfresco or ACA rejects the new domain name**  
Set `SERVER_NAME` in `.env.local` to the same domain used for the certificate and
restart. The nginx `server_name` directive and the `APP_CONFIG_ECM_HOST` env var
in `compose.ui.yaml` both pick up `SERVER_NAME` automatically.
