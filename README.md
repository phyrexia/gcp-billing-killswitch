# GCP Billing Killswitch

Automatically disables billing on Google Cloud projects the moment costs go out of control — two layers of protection with very different latencies.

## The problem

A compromised API key, a misconfigured job, or a runaway service can rack up thousands of dollars in hours. GCP's native billing alerts have **up to 24 hours of latency** — by the time the alert fires, the damage is done.

## Solution: two-layer killswitch

```
Anomaly detected
      │
      ├─── Layer 1: Cloud Monitoring (request spike)
      │    Latency: ~5 minutes
      │    Trigger: API request count exceeds threshold in a 5-min window
      │
      └─── Layer 2: Budget alert (cost threshold)
           Latency: ~24 hours
           Trigger: monthly spend reaches $100 (configurable)
                                   │
                                   ▼
                    Cloud Function (Python)
                    reads project_id from Pub/Sub message
                    calls cloudbilling.projects.updateBillingInfo("")
                    → billing unlinked → services shut down
```

Either layer independently triggers the same Cloud Function, which immediately unlinks billing from the affected project.

> **Note**: When billing is disabled, GCP begins shutting down services within minutes to hours. Free-tier resources continue running; billable ones do not.

## Features

- **Dual-trigger architecture** — spike detection (~5 min) + budget backstop (~24h)
- **Multi-project** — one deployment protects all your projects; project ID is read dynamically from each alert
- **Simulation mode** — test the full pipeline without actually disabling billing (`SIMULATE_DEACTIVATION=true`)
- **Single command deploy** — one `bash deploy.sh` sets up Pub/Sub, Cloud Function, monitoring policies, and budgets

## Prerequisites

- `gcloud` CLI authenticated with an account that has `Project Owner` or `Editor` on the host project and all protected projects
- Python 3.11+

## Setup

### 1. Configure `deploy.sh`

Edit the variables at the top of `deploy.sh`:

```bash
HOST_PROJECT="your-host-project-id"        # Project where the function lives
BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"     # Your billing account ID
SPIKE_THRESHOLD=500                         # Requests per 5-min window before killswitch fires
PROJECTS=(                                  # All projects to protect
  "project-id-1"
  "project-id-2"
)
```

Find your billing account ID:
```bash
gcloud beta billing accounts list
```

### 2. Deploy

```bash
bash deploy.sh
```

This will:
1. Enable required APIs
2. Create a Pub/Sub topic (`billing-alerts`)
3. Deploy the Cloud Function
4. Create a Cloud Monitoring alerting policy per project (Layer 1)
5. Create a $100/month budget per project (Layer 2)

### 3. Done

`deploy.sh` creates a dedicated service account (`kill-billing-sa`) and automatically grants it `roles/billing.projectManager` on each protected project — no manual IAM steps required.

## Testing with simulation mode

Deploy in dry-run mode first — the function runs the full pipeline but logs `[SIMULATE]` instead of making billing changes:

```bash
# Deploy in simulation mode
bash deploy.sh --simulate

# Publish a fake billing alert
gcloud pubsub topics publish billing-alerts \
  --project=YOUR_HOST_PROJECT \
  --message='{"costAmount":150,"budgetAmount":100,"budgetDisplayName":"test","currencyCode":"USD"}' \
  --attribute="billing.googleapis.com/ProjectId=YOUR_PROJECT_ID"

# Check logs
gcloud functions logs read kill-billing --region=us-central1 --limit=20
```

You should see `[SIMULATE] Would have disabled billing for ...` in the logs.

When ready to arm: `bash deploy.sh` (without `--simulate`).

## Tuning the spike threshold

The default threshold of **500 requests in 5 minutes** suits low-traffic projects. For projects with regular high-volume API usage, raise it to avoid false positives:

```bash
# In deploy.sh, per-project override example:
SPIKE_THRESHOLD_agentbox=5000
SPIKE_THRESHOLD_default=500
```

Or adjust `SPIKE_THRESHOLD` globally in `deploy.sh`.

## What happens when it fires

1. Cloud Function calls `cloudbilling.projects.updateBillingInfo` with an empty `billingAccountName`
2. GCP unlinks the project from the billing account
3. Billable services begin shutting down (Compute Engine VMs, Cloud SQL, etc.)
4. Free-tier services and static resources remain intact
5. To re-enable: go to `Billing > My projects` in GCP Console and re-link the billing account

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         GCP Projects                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │ project1 │  │ project2 │  │ project3 │  │ projectN │       │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘       │
│       │              │              │              │             │
│  Budget &       Budget &       Budget &       Budget &           │
│  Monitoring     Monitoring     Monitoring     Monitoring         │
│       │              │              │              │             │
└───────┼──────────────┼──────────────┼──────────────┼────────────┘
        │              │              │              │
        └──────────────┴──────┬───────┴──────────────┘
                               │
                    Pub/Sub topic: billing-alerts
                    (hosted in HOST_PROJECT)
                               │
                    ┌──────────▼──────────┐
                    │   Cloud Function     │
                    │   kill-billing       │
                    │                      │
                    │  reads project_id    │
                    │  from message        │
                    │  disables billing    │
                    └─────────────────────┘
```

## Files

| File | Description |
|------|-------------|
| `main.py` | Cloud Function — handles both budget and monitoring alerts |
| `requirements.txt` | Python dependencies |
| `deploy.sh` | Full automated setup script |

## Comparison with similar projects

| Feature | This project | derailed-dash | dataslayermedia |
|---------|-------------|---------------|-----------------|
| Spike detection (~5 min) | ✅ | ❌ | ❌ |
| Budget backstop (~24h) | ✅ | ✅ | ✅ |
| Multi-project support | ✅ | ✅ | ❌ |
| Simulation / dry-run | ✅ | ✅ | ❌ |
| Single-command deploy | ✅ | Partial | ❌ |

## License

MIT
