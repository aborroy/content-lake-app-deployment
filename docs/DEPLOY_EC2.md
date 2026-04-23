# Deploying to AWS EC2

This guide covers deploying the full stack on a **g4dn.xlarge** (4 vCPU / 16 GB RAM / NVIDIA T4 GPU) running Ubuntu.

The same Docker Model Runner used on Docker Desktop is also available on Linux via the `docker-model-plugin` package, keeping deployment assets and make commands identical across environments. On a GPU instance, Docker Model Runner automatically uses the T4 for inference, giving dramatically faster embedding and LLM response times compared to CPU-only instances. The only Linux-specific difference is setting `MODEL_RUNNER_URL` to `http://host.docker.internal:12434` in `.env.local` — the port Docker Model Runner binds to on Linux. The `host.docker.internal:host-gateway` mapping is already embedded in `compose.rag.yaml` so no extra compose file is needed.

## 1. Launch the EC2 Instance

In the AWS Console (or CLI), launch an instance with these settings:

| Setting | Value |
|---|---|
| AMI | Ubuntu Server 24.04 LTS (HVM), 64-bit x86 |
| Instance type | `g4dn.xlarge` |
| Key pair | Create or select an existing key pair |
| Storage | 150 GiB gp3 (delete on termination: your choice) |

**Security group inbound rules:**

| Port | Protocol | Source | Purpose |
|---|---|---|---|
| 22 | TCP | Your IP | SSH |
| 8080 | TCP | Your IP | Alfresco proxy |

> Restrict sources to your IP for a testing environment. Avoid `0.0.0.0/0` unless strictly necessary.

## 2. Connect to the Instance

```bash
ssh -i /path/to/your-key.pem ubuntu@<EC2_PUBLIC_IP>
```

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

## 4. Install NVIDIA Drivers and Container Toolkit

Docker Model Runner requires the NVIDIA kernel driver and the NVIDIA Container Toolkit to pass the GPU through to containers.

```bash
# Install the NVIDIA kernel driver
sudo apt-get install -y nvidia-driver-535
```

> A reboot is required after driver installation before the GPU is usable.

```bash
sudo reboot
```

Reconnect after the reboot:

```bash
ssh -i /path/to/your-key.pem ubuntu@<EC2_PUBLIC_IP>
```

Verify the driver is loaded:

```bash
nvidia-smi
```

You should see the T4 listed with driver version and CUDA version.

Now install the NVIDIA Container Toolkit so Docker can access the GPU:

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
```

## 5. Install Docker Engine

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

# Install Docker Engine, Compose plugin, and Model Runner plugin
sudo apt-get update
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin \
  docker-model-plugin

# Register the NVIDIA runtime with Docker
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Allow running Docker without sudo
sudo usermod -aG docker $USER
newgrp docker

# Verify
docker version
docker compose version
docker model version
```

## 6. Pull the AI Models

Pull the models before starting the full stack so the AI services find them ready on first startup. Docker Model Runner will use the T4 GPU automatically.

```bash
docker model pull ai/mxbai-embed-large
docker model pull ai/qwen2.5
```

> **Model choice on g4dn.xlarge (T4, 15 GB VRAM):** `ai/gpt-oss` is a ~13 GB reasoning model that leaves almost no headroom alongside the embedding model (~0.7 GB). On a T4 this causes the model runner to evict one model when the other is needed, adding a **3–5 minute cold-start penalty** to every RAG query. `ai/qwen2.5` is the recommended default — see benchmarks below.
>
> **Benchmarks on g4dn.xlarge (T4, warm model):**
>
> | Model | Size | tok/s (warm) | Total response (warm) | Cold start |
> |---|---|---|---|---|
> | `ai/mistral` (7B Q4) | ~4 GB | ~41 | ~1.3 s | ~50 s |
> | `ai/qwen2.5` (4B) | ~3 GB | ~41 | **~4 s** | **<5 s** |
> | `ai/gemma3` (4B) | ~3.5 GB | ~61 | ~3 s | ~50 s |
> | `ai/gpt-oss` (~13B) | ~13 GB | ~15 | 3–5 min | 3–5 min |
>
> `ai/qwen2.5` wins for RAG: comparable throughput to mistral with a near-zero cold start, meaning the model runner does not stall when switching between the embedding model and the LLM within a single query. `ai/gemma3` is faster at inference but its ~50 s cold start negates that advantage in practice.
>
> To use `ai/gpt-oss` without cold-start eviction you need at least a **g5.xlarge** (NVIDIA A10G, 24 GB VRAM), which gives both models room to stay resident simultaneously:
> ```bash
> docker model pull ai/gpt-oss
> # In .env.local:
> LLM_MODEL=ai/gpt-oss
> ```

## 7. Clone the Repository

```bash
git clone https://github.com/aborroy/content-lake-app-deployment.git
cd content-lake-app-deployment
```

## 8. Authenticate to Container Registries

The HXPR images are hosted on `ghcr.io`.

```bash
docker login ghcr.io
```

## 9. Create `.env.local`

Create `.env.local` to override the defaults for this EC2 deployment. Replace `<EC2_PUBLIC_IP>` with the actual public IP (or DNS name) of your instance.

```bash
cat > .env.local << 'EOF'
SERVER_NAME=<EC2_PUBLIC_IP>

# Docker Model Runner on Linux binds to port 12434 on the host.
# Containers reach it via host.docker.internal (mapped by compose.rag.yaml).
MODEL_RUNNER_URL=http://host.docker.internal:12434
EOF
```

> `EMBEDDING_MODEL` is unchanged. `LLM_MODEL` defaults to `ai/qwen2.5` — see the benchmarks in step 6 for model choice guidance.

## 10. Export Build Credentials

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

## 11. Build and Start the Stack

The initial build compiles several Java projects from source; it will take several minutes.

```bash
make up
```

## 12. Monitor Startup

```bash
make ps
```

Follow logs for all services:

```bash
make logs
```

`hxpr-app` has a 120-second start period; expect the stack to take 3–5 minutes to fully stabilise.

## 13. Public Endpoints

Replace `<EC2_PUBLIC_IP>` with your instance's IP or DNS name.

| URL | Description |
|---|---|
| `http://<EC2_PUBLIC_IP>:8080/` | Content Lake UI |
| `http://<EC2_PUBLIC_IP>:8080/alfresco/` | Alfresco Repository |
| `http://<EC2_PUBLIC_IP>:8080/share/` | Alfresco Share |
| `http://<EC2_PUBLIC_IP>:8080/admin/` | Alfresco Control Center |
| `http://<EC2_PUBLIC_IP>:8080/api/rag/` | RAG Service |

## 14. Day-to-Day Commands

```bash
make down     # stop and remove containers (preserves volumes)
make up       # start again (images already built, skips rebuild)
make logs     # tail all logs
make ps       # show service status
make clean    # remove containers AND all volumes (destructive)
```

## 15. Saving Costs

- Stop the EC2 instance when not in use — you are only charged for storage while stopped (~$0.10/GB/month for gp3).
- EBS volumes persist across instance stops, so Alfresco data, Solr index, MongoDB, and pulled model weights are all retained.

## 16. Upgrading to g5.xlarge (NVIDIA A10G, 24 GB VRAM)

The **g5.xlarge** provides an NVIDIA A10G GPU with 24 GB VRAM, which allows `ai/gpt-oss` (~13 GB) and `ai/mxbai-embed-large` (~0.7 GB) to reside in VRAM simultaneously — eliminating the 3–5 minute cold-start eviction penalty present on the T4.

**Cost difference (us-east-1, on-demand):** ~$0.48/hr more than g4dn.xlarge ($1.006 vs $0.526).

### Option A — Stop and resize an existing instance (recommended)

This preserves all EBS data (Alfresco content, Solr index, MongoDB, pulled model weights).

```bash
# 1. Retrieve your instance ID
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=<your-instance-name>" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)

# 2. Stop the instance
aws ec2 stop-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID

# 3. Change the instance type
aws ec2 modify-instance-attribute \
  --instance-id $INSTANCE_ID \
  --instance-type '{"Value": "g5.xlarge"}'

# 4. Start the instance
aws ec2 start-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# 5. Get the new public IP (it changes on restart unless you use an Elastic IP)
aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text
```

> If you have an Elastic IP attached to the instance, the address is preserved across the stop/start.

### Option B — Launch a fresh g5.xlarge instance

Follow the full deployment guide from step 1, selecting `g5.xlarge` as the instance type. The NVIDIA driver version (`nvidia-driver-535`) and all other steps are identical — the A10G is supported by the same driver series.

### After the resize — enable gpt-oss

Once the instance is running on g5.xlarge, pull the model and update your `.env.local`:

```bash
# Pull gpt-oss (this will take a few minutes; the model is ~13 GB)
docker model pull ai/gpt-oss

# Update .env.local to use gpt-oss
cat >> .env.local << 'EOF'
LLM_MODEL=ai/gpt-oss
EOF

# Restart the RAG service to pick up the new model
docker compose restart rag-service
```

Verify the model is resident in VRAM (both models should show simultaneously):

```bash
nvidia-smi
docker model ls
```

With 24 GB VRAM, `ai/gpt-oss` (~13 GB) and `ai/mxbai-embed-large` (~0.7 GB) leave ~10 GB headroom — no evictions, no cold starts.

## 17. High-Concurrency Mode: vLLM + TEI

### When to use this

Docker Model Runner (the default) processes inference requests **serially** — one at a time. Under concurrent load (multiple users querying simultaneously, or a quality-measurement program that also ingests content), requests pile up in a queue. The symptom is `docker-model-runner` CPU spiking above 200% while GPU utilisation stays low: the GPU finishes a request quickly but the next one has not been dispatched yet.

**vLLM** replaces the LLM backend with *continuous batching*: multiple in-flight requests are fused into a single GPU kernel dispatch, giving 3–5× throughput improvement at the same hardware cost. **HuggingFace TEI** does the same for embeddings — relevant here because ingestion jobs (batch and live ingesters) and RAG queries both hit the embedding endpoint concurrently.

### How it works (no stack changes required)

A lightweight nginx proxy listens on port **12434** — the same port Docker Model Runner occupies on Linux. It routes by path:

```
compose services → http://host.docker.internal:12434  (nginx proxy)
                         ├── /v1/embeddings  → TEI   :8080
                         └── /v1/*           → vLLM  :8000
```

Because the proxy mirrors the existing port, `MODEL_RUNNER_URL=http://host.docker.internal:12434` in `.env.local` does **not** change. No compose files, no Java code, and no `.env` defaults are modified.

All three containers (`tei`, `vllm`, `ai-proxy`) run with `--network host` so they reach each other via `127.0.0.1` and are reachable from inside the compose network via `host.docker.internal`.

### VRAM budget (T4, 16 GB)

| Container | Model | Approx. VRAM |
|-----------|-------|--------------|
| vLLM | `Qwen/Qwen2.5-3B-Instruct-AWQ` (4-bit AWQ, same family as `ai/qwen2.5`) | ~9.6 GB at `--gpu-memory-utilization 0.60` (model + KV cache) |
| TEI | `mixedbread-ai/mxbai-embed-large-v1` (same weights as `ai/mxbai-embed-large`) | ~0.7 GB |
| **Total** | | **~10.3 GB** — ~5.7 GB headroom |

### Step 1 — Stop Docker Model Runner

```bash
sudo systemctl stop docker-model-runner
# Or, if the systemd unit is not present:
docker model stop --all 2>/dev/null || true
```

> Docker Model Runner is no longer needed once the proxy is running. Stopping it frees the CPU
> overhead it consumes even when idle and ensures nothing else claims port 12434.

### Step 2 — Create the nginx routing config

```bash
sudo mkdir -p /opt/ai-proxy
sudo tee /opt/ai-proxy/nginx.conf > /dev/null << 'EOF'
events {}
http {
  server {
    listen 12434;

    # Embedding requests → TEI
    location /v1/embeddings {
      proxy_pass         http://127.0.0.1:8080;
      proxy_read_timeout 120s;
      proxy_send_timeout 120s;
    }

    # Everything else (chat, models list, …) → vLLM
    location / {
      proxy_pass         http://127.0.0.1:8000;
      proxy_read_timeout 300s;
      proxy_send_timeout 300s;
    }
  }
}
EOF
```

### Step 3 — Start TEI (embeddings)

The T4 uses NVIDIA Turing architecture (SM75); the `turing-latest` TEI image is required.

```bash
docker run -d \
  --name tei \
  --gpus device=0 \
  --network host \
  --restart unless-stopped \
  -v /opt/models:/data \
  ghcr.io/huggingface/text-embeddings-inference:turing-latest \
  --model-id mixedbread-ai/mxbai-embed-large-v1 \
  --port 8080
```

> The model (~0.6 GB) is downloaded from HuggingFace on first start and cached in `/opt/models`.
> No HuggingFace token is required — the model is public.

### Step 4 — Start vLLM (LLM inference)

```bash
docker run -d \
  --name vllm \
  --gpus device=0 \
  --network host \
  --restart unless-stopped \
  -v /opt/models:/root/.cache/huggingface \
  vllm/vllm-openai:latest \
  --model Qwen/Qwen2.5-3B-Instruct-AWQ \
  --quantization awq \
  --gpu-memory-utilization 0.60 \
  --max-model-len 8192 \
  --port 8000
```

> The model (~2 GB AWQ) is downloaded on first start and cached in `/opt/models`.
> `--gpu-memory-utilization 0.60` reserves 9.6 GB for vLLM (model weights + KV cache),
> leaving the remaining VRAM for TEI and system overhead.

### Step 5 — Start the nginx proxy on port 12434

```bash
docker run -d \
  --name ai-proxy \
  --network host \
  --restart unless-stopped \
  -v /opt/ai-proxy/nginx.conf:/etc/nginx/nginx.conf:ro \
  nginx:alpine
```

### Step 6 — No .env.local change needed

`MODEL_RUNNER_URL=http://host.docker.internal:12434` already targets the port the nginx proxy
occupies. Leave it unchanged.

### Step 7 — Restart the AI-facing services

```bash
docker compose restart rag-service \
  batch-ingester live-ingester \
  nuxeo-batch-ingester nuxeo-live-ingester
```

### Verify the setup

```bash
# Both containers should show VRAM allocations that sum to ≤ 16 GB
nvidia-smi

# vLLM health
curl http://localhost:8000/health

# TEI health
curl http://localhost:8080/health

# Proxy routes — should return the vLLM model list
curl http://localhost:12434/v1/models

# End-to-end embedding via proxy
curl -s -X POST http://localhost:12434/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"input":"smoke test","model":"mixedbread-ai/mxbai-embed-large-v1"}' \
  | grep -o '"object":"list"'

# End-to-end chat via proxy
curl -s -X POST http://localhost:12434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-3B-Instruct-AWQ","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
  | grep -o '"object":"chat.completion"'
```

### Reverting to Docker Model Runner

```bash
docker stop ai-proxy tei vllm
docker rm   ai-proxy tei vllm
sudo systemctl start docker-model-runner
# Or: docker model serve  (if using the CLI-managed daemon)
```