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

- `gcloud` CLI authenticated with an account that has:
  - `Project Owner` or `Editor` on the host project
  - `Billing Account Administrator` on the billing account (needed to grant the function's SA)
- `gh` CLI (only needed to create the repo, not for deployment)
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

### 3. Grant IAM (manual step — required)

The script will print the function's service account. You must grant it **Billing Account Administrator** on your billing account — this cannot be done via `gcloud` CLI without org-level permissions.

Go to: `https://console.cloud.google.com/billing/YOUR_BILLING_ACCOUNT_ID/manage`  
→ **Add member** → paste the service account → **Billing Account Administrator**

Without this, the function will run but fail to disable billing.

## Testing with simulation mode

Before going live, verify the full pipeline without risk:

```bash
# Redeploy with simulation mode enabled
gcloud functions deploy kill-billing \
  --set-env-vars SIMULATE_DEACTIVATION=true \
  --region=us-central1 \
  --project=YOUR_HOST_PROJECT

# Manually publish a fake billing alert to the topic
gcloud pubsub topics publish billing-alerts \
  --project=YOUR_HOST_PROJECT \
  --message='{"costAmount":150,"budgetAmount":100,"budgetDisplayName":"test","currencyCode":"USD"}' \
  --attribute="billing.googleapis.com/ProjectId=YOUR_PROJECT_ID"

# Check the function logs
gcloud functions logs read kill-billing --region=us-central1 --limit=20
```

You should see `[SIMULATE]` in the logs instead of actual billing changes.

When ready for production, redeploy without the env var (or set it to `false`).

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
