# GKE Single-GPU Deployment of Qwen2.5-0.5B-Instruct using vLLM and llm-d

This build plan details the architecture and deployment steps for setting up a single-GPU node to deploy the **Qwen2.5-0.5B-Instruct** model using the **vLLM** engine and **llm-d** (the Kubernetes-native distributed/disaggregated inference framework). 

Because `llm-d` is fundamentally designed to exploit Kubernetes orchestration (utilizing GKE's Gateway API Inference Extensions for intelligent request scheduling and disaggregated prefill/decode), we will deploy this on **Google Kubernetes Engine (GKE)**. 

Since Google Cloud does not offer legacy 6GB GPUs, we will utilize the **NVIDIA L4 (24GB GDDR6)** or the **NVIDIA T4 (16GB GDDR6)**, both of which represent GCP's most cost-effective and modern entry-level hardware matching your lightweight VRAM requirement.

---

## 1. Technical Approach

The core architectural decision is choosing the right compute and accelerator framework to demonstrate the `llm-d -> vLLM -> Qwen2.5-0.5B` pipeline.

### Compute & GPU Platform Alternatives

| Compute Platform | Instance / GPU Specs | Best Suited For | Key Advantages |
| --- | --- | --- | --- |
| **GKE Standard Cluster** *(Recommended)* | `g2-standard-4` (4 vCPUs, 16GB RAM) + **1x NVIDIA L4 (24GB VRAM)** | Production-ready demos, auto-scaling, and utilizing native `llm-d` scheduler features. | Integrates natively with the `llm-d` Gateway API Endpoint Picker (EPP) and multi-tier KV caches. |
| **GCE Virtual Machine** | `g2-standard-4` (4 vCPUs, 16GB RAM) + **1x NVIDIA L4 (24GB VRAM)** | Simple single-container debugging and low-overhead playground. | Fastest setup; no Kubernetes API or routing controller overhead. |
| **GCE Virtual Machine (Legacy Low-Cost)** | `n1-standard-4` (4 vCPUs, 15GB RAM) + **1x NVIDIA T4 (16GB VRAM)** | Absolute lowest-cost hardware sandbox. | Uses legacy T4 hardware; lower hourly cost but lacks BF16 support. |

> **Primary Recommendation:** We recommend deploying on a **GKE Standard Cluster with an NVIDIA L4 GPU node (`g2-standard-4`)**. `llm-d` is co-developed by Google, Red Hat, and NVIDIA specifically to run as a Kubernetes-native daemon stack. Standardizing on GKE allows you to leverage native `llm-d` routing, local SSD cache volume mounts, and GKE's automated GPU driver installer.

### Optional Upgrades

- **Spot VMs:** For non-production demonstration environments, run the GKE node pool on Spot VMs to reduce compute and GPU costs by up to 60-90%.
- **Hyperdisk Balanced:** Use a 50Gi `pd-balanced` boot disk to optimize model weight loading and container image streaming performance.

---

## 2. Solution Overview

### Objectives & Assumptions

- **Objectives:** Provision a GKE node with a single GPU, pull the `llm-d` Docker container, cache the `Qwen2.5-0.5B-Instruct` model weights, and serve the model over an OpenAI-compatible API.
- **Prerequisites:**
- A Google Cloud project with billing enabled.
- Appropriate GPU quotas (e.g., `NVIDIA_L4_GPUS` or `NVIDIA_T4_GPUS`) in `us-central1`.

### Estimated Deployment Time

- **Cluster Provisioning:** ~10-12 minutes.
- **Model Download & Container Startup:** ~3-5 minutes (Qwen2.5-0.5B is exceptionally small at ~1.0 GB).
- **Total Time:** **~15 minutes**.

### Architecture Components

- **Orchestration:** Google Kubernetes Engine (GKE) Standard.
- **Compute:** `g2-standard-4` node instance.
- **Accelerator:** 1x NVIDIA L4 GPU (24GB VRAM).
- **Software Stack:** `ghcr.io/llm-d/llm-d-cuda:v0.5.0` (extends vLLM).
- **Storage:** 50Gi Persistent Volume Claim (`pd-balanced`) for huggingface caching.

### Estimated Costs

Below is a breakdown of estimated monthly costs based on standard on-demand pricing in `us-central1`.

| Scenario | Est. Monthly Cost | Key Cost Levers |
| --- | --- | --- |
| **GKE Standard Cluster (g2-standard-4 + 1x L4 GPU)** | **~$588.99** | GKE Management Fee ($0.10/hr) + G2 Node ($515.99/mo) |
| **GCE Standalone VM (g2-standard-4 + 1x L4 GPU)** | **~$515.99** | Direct VM + GPU hourly rates (No Kubernetes overhead) |
| **GCE Standalone VM (n1-standard-4 + 1x T4 GPU)** | **~$394.20** | Legacy N1 VM + T4 GPU (Lowest-cost option) |

> **Expert Callout:** **Obtainability:** There are no matching zonal reservations found in the project context for the us-central1-a zone and g2-standard-4 machine type. You may run this workload on Spot or Flex Start preemptible resources to optimize costs.

---

## 3. Step-by-Step Implementation Plan

### Pre-Flight Checks
Ensure that your GCP project has the required GPU quotas. In the GCP Console, navigate to **IAM & Admin > Quotas** and check for `NVIDIA_L4_GPUS` in region `us-central1`.

Run the following command to enable the required APIs:

```bash
gcloud services enable container.googleapis.com compute.googleapis.com --project=women-safety-by-pioneers
```

### Unified Variables
Copy and paste this code block to configure your environment. Do not use placeholders.

```bash
# Target GCP Environment Variables
export PROJECT_ID="women-safety-by-pioneers"
export REGION="us-central1"
export ZONE="us-central1-a"
export CLUSTER_NAME="llmd-qwen-demo"
export NAMESPACE="vllm-qwen"
```

### Execution Steps

#### Step 1: Initialize gcloud Configuration

```bash
gcloud config set project ${PROJECT_ID}
gcloud config set compute/region ${REGION}
gcloud config set compute/zone ${ZONE}
```

#### Step 2: Create GKE Cluster with L4 GPU Node Pool
Create a single-node GKE Standard cluster targeting the preferred zone. The `--gpu-driver-version=default` flag instructs GKE to automatically install the appropriate NVIDIA drivers on the node.

```bash
gcloud container clusters create ${CLUSTER_NAME} \
    --project=${PROJECT_ID} \
    --zone=${ZONE} \
    --num-nodes=1 \
    --machine-type=g2-standard-4 \
    --accelerator=type=nvidia-l4,count=1,gpu-driver-version=default \
    --workload-pool=${PROJECT_ID}.svc.id.goog
```

#### Step 3: Get Cluster Credentials

```bash
gcloud container clusters get-credentials ${CLUSTER_NAME} --zone ${ZONE} --project ${PROJECT_ID}
```

#### Step 4: Save the Kubernetes Manifest
Create a file named `llmd-qwen-deployment.yaml` and paste the following manifest exactly as returned by the GKE manifest helper. Do not modify its contents.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vllm-qwen
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: qwen-model-cache
  namespace: vllm-qwen
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: pd-balanced
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qwen-vllm
  namespace: vllm-qwen
  labels:
    app: qwen-vllm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: qwen-vllm
  template:
    metadata:
      labels:
        app: qwen-vllm
    spec:
      containers:
      - name: llm-d-vllm
        image: ghcr.io/llm-d/llm-d-cuda:v0.5.0
        args:
        - --model
        - qwen/Qwen2.5-0.5B-Instruct
        # FLAG[Info]: Using a single GPU. Tensor parallel size is set to 1.
        - --tensor-parallel-size
        - "1"
        - --max-model-len
        - "8192"
        # FLAG[Info]: fp16 is generally recommended for Qwen2.5-0.5B on T4/L4 to save memory while maintaining precision.
        - --dtype
        - float16
        ports:
        - containerPort: 8000
          name: http
        env:
        - name: VLLM_USE_PRECOMPILED_KERNELS
          value: "1"
        resources:
          requests:
            cpu: "2"
            memory: 8Gi
            # FLAG[Verification]: Verify that the chosen region has NVIDIA L4 or T4 GPU quota available.
            nvidia.com/gpu: "1"
          limits:
            cpu: "4"
            memory: 16Gi
            nvidia.com/gpu: "1"
        volumeMounts:
        - name: model-cache
          mountPath: /root/.cache/huggingface
        - name: dshm
          mountPath: /dev/shm
        livenessProbe:
          httpGet:
            path: /health
            port: http
          initialDelaySeconds: 60
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: http
          initialDelaySeconds: 30
          periodSeconds: 15
        startupProbe:
          httpGet:
            path: /health
            port: http
          failureThreshold: 20
          periodSeconds: 10
      nodeSelector:
        # FLAG[Verification]: Confirm if targeting "nvidia-l4" or "nvidia-tesla-t4". Defaulting to L4 for better performance.
        cloud.google.com/gke-accelerator: nvidia-l4
      volumes:
      - name: model-cache
        persistentVolumeClaim:
          claimName: qwen-model-cache
      - name: dshm
        emptyDir:
          medium: Memory
          sizeLimit: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: qwen-vllm-service
  namespace: vllm-qwen
spec:
  selector:
    app: qwen-vllm
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8000
  type: ClusterIP
```

Apply the deployment:

```bash
kubectl apply -f llmd-qwen-deployment.yaml
```

#### Step 5: Monitor Startup Logs
Check the status of your Pods and monitor the model download.

```bash
kubectl get pods -n ${NAMESPACE} -w
```

Once the pod is `Running`, stream the vLLM engine initialization logs to verify successful GPU-acceleration activation and weight loading:

```bash
kubectl logs deployment/qwen-vllm -n ${NAMESPACE} -c llm-d-vllm --follow
```

#### Step 6: Test the Inference API
Port-forward the GKE cluster service to test the deployment from your local workstation:

```bash
kubectl port-forward service/qwen-vllm-service -n ${NAMESPACE} 8080:80 &
PF_PID=$!

# Wait for port-forward to establish
sleep 3

# Send an OpenAI-compatible completion request
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen/Qwen2.5-0.5B-Instruct",
    "messages": [
      {"role": "user", "content": "Hello Qwen! What are three key features of the llm-d framework?"}
    ],
    "temperature": 0.7
  }'

# Tear down the port-forward background task
kill $PF_PID
```

---

## 4. Post-Execution Strategy

Now that you have successfully deployed the baseline single-node demonstrator, consider the following "Day 2" operational upgrades when moving this design toward a production environment:

### 1. Enable Native `llm-d` Routing (Gateway API)
As you scale up to multiple GPU nodes, standard Kubernetes round-robin load-balancing will invalidate the KV cache. Configure the **Gateway API Inference Extension (GAIE)** and its **Endpoint Picker (EPP)**. This routes requests sharing historical context to the exact same GPU node, exploiting vLLM prefix caching to drop TTFT (Time-To-First-Token) latency by up to 50%.

### 2. Disaggregated Prefill & Decode
Under high workload variability, transition your `llm-d` deployment into a disaggregated state:

- Dedicate 1x GPU node to the **prefill stage** (compute-heavy prompt processing).
- Dedicate another GPU node to the **decoding stage** (memory-bandwidth-bound token generation).

This isolates long system prompt evaluation from active streaming token production.

### 3. Horizontal Pod Auto-Scaling (HPA) using vLLM Metrics
Do not scale model servers using CPU or memory metrics. Implement GKE Prometheus metrics scraping to target the vLLM native metrics:

- `vllm:num_requests_waiting` (identifies queue buildup).
- `vllm:num_requests_running` (identifies active hardware saturation).

Configure GKE’s Horizontal Pod Autoscaler (HPA) to spin up additional GPU instances only when the waiting queue exceeds a desired threshold.