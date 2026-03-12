# Deploying to AWS EC2

This guide covers deploying the full stack on an **r6i.xlarge** (4 vCPU / 32 GB RAM) running Ubuntu.

Docker Model Runner is not available on Linux Docker Engine, so this guide uses [Ollama](https://ollama.com) as a drop-in replacement, defined in `compose.ollama.yaml`. All make commands use the `-ollama` variant targets.

---

## 1. Launch the EC2 Instance

In the AWS Console (or CLI), launch an instance with these settings:

| Setting | Value |
|---|---|
| AMI | Ubuntu Server 24.04 LTS (HVM), 64-bit x86 |
| Instance type | `r6i.xlarge` |
| Key pair | Create or select an existing key pair |
| Storage | 150 GiB gp3 (delete on termination: your choice) |

**Security group inbound rules:**

| Port | Protocol | Source | Purpose |
|---|---|---|---|
| 22 | TCP | Your IP | SSH |
| 8080 | TCP | Your IP | Alfresco proxy |
| 5601 | TCP | Your IP | OpenSearch Dashboards |

> Restrict sources to your IP for a testing environment. Avoid `0.0.0.0/0` unless strictly necessary.

---

## 2. Connect to the Instance

```bash
ssh -i /path/to/your-key.pem ubuntu@<EC2_PUBLIC_IP>
```

---

## 3. Prepare the OS

Update packages and add swap space. The stack is RAM-intensive during startup; 8 GB of swap prevents OOM kills while services are initialising.

```bash
sudo apt-get update && sudo apt-get upgrade -y

# 8 GB swap file
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

---

## 4. Install Docker Engine

```bash
# Add Docker's GPG key and repository
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine and Compose plugin
sudo apt-get update
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Allow running Docker without sudo
sudo usermod -aG docker $USER
newgrp docker

# Verify
docker version
docker compose version
```

---

## 5. Clone the Repository

```bash
git clone https://github.com/aborroy/alfresco-content-lake-deploy.git
cd alfresco-content-lake-deploy
```

---

## 6. Authenticate to Container Registries

The HXPR images are hosted on `ghcr.io`.

```bash
docker login ghcr.io
```

---

## 7. Create `.env.local`

Create `.env.local` to override the defaults for this EC2 deployment.
Replace `<EC2_PUBLIC_IP>` with the actual public IP (or DNS name) of your instance.

```bash
cat > .env.local << 'EOF'
SERVER_NAME=<EC2_PUBLIC_IP>

# Ollama replaces Docker Model Runner
MODEL_RUNNER_URL=http://ollama:11434
EMBEDDING_MODEL=mxbai-embed-large
LLM_MODEL=gpt-oss
EOF
```

> **Model note:** `gpt-oss` and `mxbai-embed-large` map 1:1 from `ai/gpt-oss` and `ai/mxbai-embed-large`.
> A `gpt-oss:120b` variant exists but requires far more RAM than the r6i.xlarge provides — stick with the default tag.

---

## 8. Export Build Credentials

These are required to build the HXPR image. Export them in your shell before starting the stack.

```bash
export MAVEN_USERNAME=<github-username>
export MAVEN_PASSWORD=<github-pat-with-read:packages>
export NEXUS_USERNAME=<hyland-nexus-username>
export NEXUS_PASSWORD=<hyland-nexus-password>

# Only needed if HylandSoftware/hxpr is not cloneable anonymously
export HXPR_GIT_AUTH_TOKEN=<github-pat-with-repo-read>
```

See the [Getting Credentials](README.md#getting-credentials) section in the main README for details on obtaining each credential.

---

## 9. Start the Stack

### 9a. Bring up Ollama first and pull the models

Pull the models before starting the full stack so the AI services find them ready on first startup.

```bash
make ollama-start
make ollama-pull
```

### 9b. Build and start the full stack

The initial build compiles several Java projects from source; it will take several minutes.

```bash
make up-ollama
```

---

## 10. Monitor Startup

The stack is fully ready when all services report `healthy` or `running`:

```bash
make ps-ollama
```

Follow logs for all services:

```bash
make logs-ollama
```

`hxpr-app` has a 120-second start period; expect the stack to take 3–5 minutes to fully stabilise.

---

## 11. Public Endpoints

Replace `<EC2_PUBLIC_IP>` with your instance's IP or DNS name.

| URL | Description |
|---|---|
| `http://<EC2_PUBLIC_IP>:8080/` | Content Lake UI |
| `http://<EC2_PUBLIC_IP>:8080/alfresco/` | Alfresco Repository |
| `http://<EC2_PUBLIC_IP>:8080/share/` | Alfresco Share |
| `http://<EC2_PUBLIC_IP>:8080/admin` | Alfresco Control Center |
| `http://<EC2_PUBLIC_IP>:8080/api-explorer/` | API Explorer |
| `http://<EC2_PUBLIC_IP>:8080/api/rag/` | RAG Service |
| `http://<EC2_PUBLIC_IP>:5601/` | OpenSearch Dashboards |

Default Alfresco credentials: `admin` / `admin`.

---

## 12. Day-to-Day Commands

```bash
make down-ollama    # stop and remove containers (preserves volumes)
make up-ollama      # start again (images already built, skips rebuild)
make logs-ollama    # tail all logs
make ps-ollama      # show service status
make clean-ollama   # ⚠️  remove containers AND all volumes (destructive)
```

---

## 13. Saving Costs

- **Stop the EC2 instance** when not in use — you are only charged for storage while stopped (~$0.10/GB/month for gp3).
- **EBS volumes persist** across instance stops, so your Alfresco data, Solr index, MongoDB, and pulled Ollama models are retained.
- Use an **Elastic IP** if you stop/start frequently, otherwise the public IP changes each time and you will need to update `SERVER_NAME` in `.env.local`.

```bash
# Assign a static Elastic IP in the AWS Console, then update .env.local:
SERVER_NAME=<ELASTIC_IP>
```
