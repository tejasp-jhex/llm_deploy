# 5. Suggested Improvements — Production-Oriented Deployment

The current deployment provides a strong single-GPU proof of concept. To move toward a production-oriented inference platform, the next phase should introduce **multi-node GPU serving, intelligent request routing, observability, autoscaling, load testing, and failure recovery**.

The goal is not simply to add more GPUs, but to demonstrate that the inference platform can handle concurrent workloads, recover from failures, and scale according to demand.

---

## 5.1 Target Architecture

The single-GPU architecture should be expanded from one inference node to two independent GPU nodes.

### Current Architecture

```text
Client
   |
   v
GKE Service
   |
   v
GPU Node
   |
   +-- llm-d / vLLM
   |
   +-- Qwen2.5-0.5B-Instruct
```

### Improved Architecture

```text
                         Applications
                              |
                              v
                    OpenAI-Compatible API
                              |
                              v
                     Gateway / Ingress
                              |
                              v
                    +-------------------+
                    |      llm-d        |
                    | Routing / EPP     |
                    +---------+---------+
                              |
                    +---------+---------+
                    |                   |
                    v                   v
             +-------------+     +-------------+
             | GPU Node 1  |     | GPU Node 2  |
             | NVIDIA L4   |     | NVIDIA L4   |
             |             |     |             |
             |    vLLM     |     |    vLLM     |
             |    Qwen     |     |    Qwen     |
             +-------------+     +-------------+
                    |                   |
                    +---------+---------+
                              |
                              v
                    Monitoring / Metrics
                              |
                    +---------+---------+
                    |                   |
                    v                   v
               Prometheus            Grafana
```

The important change is that the system now has **two independent inference endpoints** instead of a single GPU serving all traffic.

---

## 5.2 Deploy Two GPU Nodes

The GKE cluster should contain two GPU-capable nodes.

### Node Configuration

Each node should contain:

* 1 × NVIDIA L4 GPU
* 4 vCPUs
* 16 GB RAM
* vLLM inference server
* Qwen2.5-0.5B-Instruct
* llm-d integration

The resulting infrastructure becomes:

```text
GKE Standard Cluster
│
├── GPU Node 1
│   └── NVIDIA L4
│       └── vLLM + Qwen2.5-0.5B-Instruct
│
└── GPU Node 2
    └── NVIDIA L4
        └── vLLM + Qwen2.5-0.5B-Instruct
```

Each GPU should independently be capable of serving the model.

This provides basic redundancy and allows inference traffic to be distributed across multiple GPU workers.

---

## 5.3 Run One Inference Replica Per GPU

The deployment should use one vLLM inference workload per GPU.

```text
GPU Node 1
    |
    +-- vLLM Replica 1
            |
            +-- Qwen2.5-0.5B-Instruct


GPU Node 2
    |
    +-- vLLM Replica 2
            |
            +-- Qwen2.5-0.5B-Instruct
```

The objective is to avoid treating the two GPUs as one large GPU.

Instead, each GPU becomes an independent inference worker.

This allows the platform to:

* Serve requests concurrently
* Continue serving if one inference worker fails
* Increase total serving capacity
* Experiment with intelligent request routing
* Prepare the architecture for horizontal scaling

---

## 5.4 Enable llm-d Intelligent Routing

The next major improvement should be implementing the **Gateway API Inference Extension and Endpoint Picker (EPP)** capabilities described in the initial architecture.

The current Kubernetes Service provides basic service-level routing. The improved architecture should allow llm-d to make more inference-aware routing decisions.

### Target Flow

```text
Incoming Request
       |
       v
   llm-d Gateway
       |
       v
 Endpoint Picker
       |
       +------------------+
       |                  |
       v                  v
   GPU Node 1          GPU Node 2
      vLLM                vLLM
       |                    |
       +---------+----------+
                 |
                 v
              Response
```

The objective is to move beyond simple round-robin traffic distribution and use inference-aware routing as the number of GPU workers increases.

The original design identifies this as an important Day 2 capability because routing can be used together with vLLM prefix caching and KV-cache locality.

---

## 5.5 Add Production Observability

The system should expose and collect inference metrics rather than only checking whether Kubernetes reports the pod as `Running`.

A monitoring stack should collect:

### Infrastructure Metrics

* GPU utilization
* GPU memory utilization
* CPU utilization
* Memory utilization
* Node health
* Pod restarts

### Inference Metrics

* Request rate
* Requests running
* Requests waiting
* Queue depth
* Request latency
* Time to First Token (TTFT)
* Token generation rate
* Tokens per second
* Error rate

### Recommended Monitoring Flow

```text
GKE
 |
 +-- GPU Metrics
 |
 +-- Kubernetes Metrics
 |
 +-- vLLM Metrics
 |
 v
Prometheus
 |
 v
Grafana
 |
 +-- GPU Dashboard
 +-- Inference Dashboard
 +-- Latency Dashboard
 +-- Error Dashboard
```

The vLLM request-waiting and request-running metrics identified in the original design should be used as important signals for workload saturation and scaling decisions.

---

## 5.6 Implement GPU-Aware Autoscaling

The deployment should not rely only on CPU or memory utilization to determine when additional inference capacity is required.

The more relevant signals are inference workload metrics such as:

* Number of waiting requests
* Number of running requests
* Request latency
* GPU utilization

### Example Scaling Behavior

```text
Low Traffic
     |
     v
1 GPU Replica
     |
     | Traffic increases
     v
Request Queue Increases
     |
     v
2 GPU Replicas
     |
     | Traffic decreases
     v
Return to 1 GPU Replica
```

The purpose is to demonstrate that GPU infrastructure can scale according to actual inference demand.

---

## 5.7 Perform Load Testing

This is one of the most important improvements.

A production-oriented deployment should demonstrate how the system behaves under increasing concurrent traffic.

Test progressively:

```text
10 concurrent requests
        ↓
25 concurrent requests
        ↓
50 concurrent requests
        ↓
100 concurrent requests
        ↓
200 concurrent requests
```

For each test, record:

| Metric          | Description                      |
| --------------- | -------------------------------- |
| Requests/sec    | Overall serving throughput       |
| P50 latency     | Typical request latency          |
| P95 latency     | High-percentile latency          |
| P99 latency     | Tail latency                     |
| TTFT            | Time until first generated token |
| Tokens/sec      | Generation throughput            |
| Error rate      | Failed requests                  |
| Queue depth     | Requests waiting for inference   |
| GPU utilization | GPU workload                     |
| GPU memory      | GPU memory consumption           |

The resulting benchmark should establish the practical capacity of the two-GPU deployment.

---

## 5.8 Perform Failure Testing

A production-oriented inference system should also demonstrate what happens when an inference worker fails.

### Failure Scenario

```text
Normal Operation

        Requests
           |
       +---+---+
       |       |
       v       v
    GPU 1    GPU 2
     vLLM     vLLM


        ↓

GPU Node 1 Failure


        ↓

llm-d detects unavailable endpoint


        ↓

Requests continue toward GPU Node 2


        ↓

Kubernetes recreates / restores
the failed workload
```

Measure:

* Number of failed requests
* Recovery time
* Pod restart time
* Model startup time
* Time until the endpoint becomes healthy again

This provides evidence of the system's resilience rather than only demonstrating successful deployment.

---

## 5.9 Improve Model Storage and Startup

The existing 50Gi persistent storage should continue to be used for model caching.

The objective is:

```text
First Startup
    |
    v
Download Model
    |
    v
Persistent Model Cache
    |
    v
Future Pod Startup
    |
    v
Reuse Cached Model
```

This becomes especially important when additional GPU replicas are introduced because model initialization can otherwise increase deployment and recovery time.

---

## 5.10 Add Health and Readiness Validation

The existing deployment already includes:

* Liveness probe
* Readiness probe
* Startup probe

These should be retained.

The improved deployment should verify the following lifecycle:

```text
Pod Created
    |
    v
Container Starting
    |
    v
Model Loading
    |
    v
GPU Initialized
    |
    v
Health Check Passed
    |
    v
Readiness Check Passed
    |
    v
Receive Production Traffic
```

A pod should only receive inference traffic after the model is fully ready.

---

## 5.11 Add Security Before External Exposure

The current proof of concept uses a Kubernetes internal `ClusterIP` service.

Before exposing the inference endpoint externally, add:

* HTTPS/TLS
* Authentication
* Authorization
* API credentials or tokens
* Rate limiting
* Request size limits
* Network restrictions
* Secret management
* Audit logging

The production request flow should therefore become:

```text
Client
  |
  v
HTTPS
  |
  v
Authentication
  |
  v
Rate Limiting
  |
  v
Inference Gateway
  |
  v
llm-d
  |
  +--------+--------+
  |                 |
  v                 v
GPU Node 1       GPU Node 2
```

---

## 5.12 Establish Performance and Reliability Targets

After load testing, define measurable service targets.

Examples include:

| Category     | Example Measurement                     |
| ------------ | --------------------------------------- |
| Availability | Service uptime                          |
| Latency      | P95 / P99 latency                       |
| TTFT         | Time to first token                     |
| Throughput   | Requests/sec                            |
| Generation   | Tokens/sec                              |
| Reliability  | Request error rate                      |
| Recovery     | Time to recover from node failure       |
| Scaling      | Time required to add inference capacity |

These numbers should come from actual experiments rather than assumptions.

---

## 5.13 Production-Oriented Validation Checklist

The improved deployment should be considered successful when the following can be demonstrated:

### Infrastructure

* [ ] Two GKE GPU nodes
* [ ] One NVIDIA L4 per node
* [ ] One inference workload per GPU
* [ ] Persistent model caching
* [ ] Kubernetes health/readiness checks

### Inference

* [ ] vLLM serving Qwen2.5-0.5B-Instruct
* [ ] OpenAI-compatible API
* [ ] Two active inference endpoints
* [ ] llm-d routing implemented

### Scaling

* [ ] Increasing traffic creates additional inference capacity
* [ ] Scaling decisions use inference-related metrics
* [ ] Traffic can return to a smaller number of replicas

### Observability

* [ ] GPU metrics
* [ ] vLLM metrics
* [ ] Request metrics
* [ ] Latency metrics
* [ ] Queue metrics
* [ ] Grafana dashboards
* [ ] Alerts for failures and saturation

### Reliability

* [ ] GPU/pod failure tested
* [ ] Automatic workload recovery verified
* [ ] Request behavior during failure measured
* [ ] Recovery time measured

### Performance

* [ ] 10 concurrent request test
* [ ] 25 concurrent request test
* [ ] 50 concurrent request test
* [ ] 100+ concurrent request test
* [ ] P50/P95/P99 latency measured
* [ ] TTFT measured
* [ ] Tokens/sec measured
* [ ] Error rate measured

### Security

* [ ] HTTPS
* [ ] Authentication
* [ ] Rate limiting
* [ ] Secrets managed securely
* [ ] External access controlled

---

## 5.14 Expected Project Maturity After Improvements

The project can be positioned at different maturity levels depending on how many of the above capabilities are actually implemented and tested.

| Deployment Stage | Description                                                                  |                    Expected Level |
| ---------------- | ---------------------------------------------------------------------------- | --------------------------------: |
| **Current**      | Single GPU + vLLM + llm-d + GKE                                              |                        Strong POC |
| **Stage 1**      | Two GPU nodes + two inference replicas                                       |     Production-oriented prototype |
| **Stage 2**      | Two GPU nodes + llm-d intelligent routing                                    |      Advanced inference prototype |
| **Stage 3**      | Routing + autoscaling + monitoring                                           |         Production-style platform |
| **Stage 4**      | Load testing + failure testing + SLO measurements                            | Demonstrated production readiness |
| **Stage 5**      | Security + CI/CD + operational automation + continued performance validation |    Mature production architecture |

The most important goal is **not to claim industry-scale capacity simply because multiple GPUs are deployed**.

The project should demonstrate capacity through measurements.

The final objective is therefore:

```text
Deploy
   ↓
Route
   ↓
Observe
   ↓
Load Test
   ↓
Scale
   ↓
Fail
   ↓
Recover
   ↓
Measure
   ↓
Optimize
```

This transforms the project from a **single-GPU LLM deployment POC** into a **production-oriented Kubernetes inference engineering project**.

---

## 5.15 Final Target Architecture

The final demonstrator should aim for:

```text
                         Users / Applications
                                  |
                                  v
                       HTTPS / API Gateway
                                  |
                       Authentication + Limits
                                  |
                                  v
                         llm-d / Gateway API
                                  |
                           Endpoint Picker
                                  |
                  +---------------+---------------+
                  |                               |
                  v                               v
          +---------------+               +---------------+
          |   GKE Node 1  |               |   GKE Node 2  |
          |               |               |               |
          |  NVIDIA L4    |               |  NVIDIA L4    |
          |               |               |               |
          |     vLLM      |               |     vLLM      |
          |       |       |               |       |       |
          |     Qwen      |               |     Qwen      |
          +-------+-------+               +-------+-------+
                  |                               |
                  +---------------+---------------+
                                  |
                                  v
                         Prometheus Metrics
                                  |
                                  v
                              Grafana
                                  |
                                  v
                         Alerts / Operations
```

### Final Goal

The completed system should demonstrate:

**Kubernetes-native LLM serving + multi-GPU inference + intelligent routing + autoscaling + observability + load testing + failure recovery.**

That provides substantially stronger evidence of production-oriented engineering than simply deploying the model on a second GPU.
