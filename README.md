# GCP Billing Killswitch

> "I woke up to a $47,000 Google Cloud bill. My API key had been scraped from a public repo."

This happens every week. A leaked key, a misconfigured job, a runaway service — and by the time GCP's native billing alerts fire, the damage is already done. Standard budget alerts have **up to 24 hours of data latency**. In that window, a compromised Vertex AI or Maps API key can generate tens of thousands of dollars in charges.

This tool cuts billing the moment an attack is detected — not the next day.

---

## How it works

Two independent layers with very different response times:

```
Anomaly detected
      │
      ├─── Layer 1: Request spike (Cloud Monitoring)
      │    Latency: ~5 minutes
      │    Trigger: API call volume exceeds threshold in a 5-min window
      │
      └─── Layer 2: Budget threshold (Billing Alert)
           Latency: ~24 hours
           Trigger: monthly spend reaches $100 (configurable)
                                   │
                                   ▼
                    Cloud Function (Python)
                    reads project_id from Pub/Sub message
                    calls cloudbilling.projects.updateBillingInfo("")
                    → billing unlinked → services shut down
```

Either layer independently triggers the same Cloud Function, which immediately unlinks billing from the affected project. One deployment protects all your projects.

> **What happens when it fires:** GCP begins shutting down billable services within minutes to hours. Free-tier resources stay up. To re-enable: go to `Billing > My projects` and re-link.

---

## Features

- **Dual-trigger** — spike detection (~5 min) + budget backstop (~24h)
- **Multi-project** — one function, all projects; each alerts independently
- **Simulation mode** — test the full pipeline without touching billing (`bash deploy.sh --simulate`)
- **Dedicated SA** — minimal-permission service account, no manual IAM steps
- **Single command** — one `bash deploy.sh` sets up everything end-to-end

---

## Prerequisites

- `gcloud` CLI authenticated as `Project Owner` or `Editor` on all protected projects
- Python 3.11+

---

## Setup

### 1. Clone and configure

```bash
git clone https://github.com/phyrexia/gcp-billing-killswitch
cd gcp-billing-killswitch
```

Edit the variables at the top of `deploy.sh`:

```bash
HOST_PROJECT="your-host-project-id"       # Project where the function lives
BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"   # gcloud beta billing accounts list
BUDGET_AMOUNT="100USD"                    # Per-project monthly hard cap

PROJECTS=(                                # All projects to protect
  "your-project-1"
  "your-project-2"
)
```

Find your billing account ID:
```bash
gcloud beta billing accounts list
```

Find projects linked to that billing account:
```bash
gcloud beta billing projects list --billing-account=YOUR_BILLING_ACCOUNT_ID
```

### 2. Test first (recommended)

Deploy in dry-run mode — the function runs but logs `[SIMULATE]` instead of touching billing:

```bash
bash deploy.sh --simulate
```

Trigger a fake alert to verify the pipeline end-to-end:

```bash
gcloud pubsub topics publish billing-alerts \
  --project=YOUR_HOST_PROJECT \
  --message='{"costAmount":150,"budgetAmount":100,"budgetDisplayName":"test","currencyCode":"USD"}' \
  --attribute="billing.googleapis.com/ProjectId=YOUR_PROJECT_ID"

# Check logs
gcloud functions logs read kill-billing --region=us-central1 --limit=20
```

You should see `[SIMULATE] Would have disabled billing for ...`

### 3. Arm it

```bash
bash deploy.sh
```

This sets up (idempotent — safe to re-run):
1. Required APIs enabled
2. Dedicated service account with minimal permissions
3. Pub/Sub topic `billing-alerts`
4. Cloud Function deployed (Gen2, Python 3.11)
5. Cloud Monitoring spike alert per project (~5 min layer)
6. Budget alert per project — $100/month cap (~24h layer)

---

## Tuning the spike threshold

The default of **500 requests in 5 minutes** suits idle or low-traffic projects. For projects with sustained API usage, raise it to avoid false positives:

```bash
SPIKE_THRESHOLD=5000   # adjust in deploy.sh
```

You can also set different thresholds per project by editing the alerting policy JSON in the deploy loop.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Protected Projects                                          │
│                                                              │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐        │
│  │  project-1  │   │  project-2  │   │  project-N  │        │
│  │             │   │             │   │             │        │
│  │ Budget +    │   │ Budget +    │   │ Budget +    │        │
│  │ Monitoring  │   │ Monitoring  │   │ Monitoring  │        │
│  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘        │
└─────────┼────────────────┼────────────────┼──────────────────┘
          │                │                │
          └────────────────┴────────────────┘
                           │
               Pub/Sub topic: billing-alerts
               (hosted in HOST_PROJECT)
                           │
               ┌───────────▼───────────┐
               │    Cloud Function     │
               │    kill-billing       │
               │                      │
               │  reads project_id    │
               │  from alert message  │
               │  calls Billing API   │
               └───────────────────────┘
                           │
               billingAccountName = ""
               → project unlinked from billing
               → billable services shut down
```

---

## Files

| File | Description |
|------|-------------|
| `main.py` | Cloud Function — handles both budget and monitoring alerts |
| `requirements.txt` | Python dependencies |
| `deploy.sh` | Full automated setup — idempotent, safe to re-run |

---

## Comparison

| Feature | This project | derailed-dash | dataslayermedia |
|---------|:-----------:|:-------------:|:---------------:|
| Spike detection (~5 min) | ✅ | ❌ | ❌ |
| Budget backstop (~24h) | ✅ | ✅ | ✅ |
| Multi-project | ✅ | ✅ | ❌ (hardcoded) |
| Simulation / dry-run | ✅ | ✅ | ❌ |
| Dedicated SA (least privilege) | ✅ | ✅ | ❌ |
| Single-command deploy | ✅ | Partial | ❌ |
| Per-project independent alerts | ✅ | ❌ | ❌ |

---

## License

MIT — use it, fork it, improve it.
