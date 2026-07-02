# 09 — Observability

**What you'll learn:** Monitor Connectivity Link with metrics, Perses dashboards, distributed tracing, and Envoy access logs — and correlate them using `x-request-id`.

**Prerequisites:** Phases 00–08 completed (Gateway with TLS, AuthPolicy, RateLimitPolicy enforced).

## Overview

Connectivity Link integrates with OpenShift's observability stack:

- **Metrics** — Prometheus scrapes Envoy, Authorino, Limitador, and Gateway API state metrics
- **Dashboards** — Perses dashboards in the OpenShift console (via Cluster Observability Operator)
- **Tracing** — Optional distributed tracing with Tempo and OpenTelemetry
- **Access logs** — Envoy gateway logs correlated with traces and metrics

Work through the subsections in order. Tracing (09c) is optional but recommended before access logs (09d), which ties all three pillars together.

## Subsections

| # | Section | Description |
|---|---------|-------------|
| 09a | [Metrics & Monitoring](./09a-metrics-monitoring/) | User workload monitoring, Kuadrant metrics |
| 09b | [Perses Dashboards](./09b-dashboards/) | COO, Perses UI, Connectivity Link dashboard |
| 09c | [Tracing (optional)](./09c-tracing/) | Tempo, OpenTelemetry, distributed tracing |
| 09d | [Access Logs](./09d-access-logs/) | Envoy access logs and correlation |

## Architecture

```
                         Metrics (09a)              Dashboards (09b)
                              │                           │
                              ▼                           ▼
  Client ──► Gateway ──► App   Prometheus ──federate──► Thanos ──► Perses
                │                                              │
                │ access logs (09d)                            │
                ▼                                              │
           Envoy stdout                                        │
                │                                              │
                └──────── x-request-id correlation ────────────┘
                                    │
                    Traces (09c)    │
                         OTel Collector ──► Tempo ──► Console (Observe → Traces)
```

## Verify

After completing all subsections:

- [ ] Prometheus scrapes Connectivity Link metrics (`kuadrant_hits`, `istio_requests_total`, etc.)
- [ ] Connectivity Link Overview dashboard is visible in **Observe → Dashboards (Perses)**
- [ ] (Optional) Correlated `envoy-gateway` → `echo` traces appear in **Observe → Traces**
- [ ] Access logs, traces, and metrics can be correlated via `x-request-id`

---

Next: [09a — Metrics & Monitoring](./09a-metrics-monitoring/) | After observability: [10 — Cleanup](../10-cleanup/)
