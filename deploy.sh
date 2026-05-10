#!/bin/bash
# GCP Billing Killswitch — setup and deploy
# Two-layer protection:
#   Layer 1: Cloud Monitoring request spike alert (~5 min latency)
#   Layer 2: Budget alert killswitch ($100/project/month, ~24h backstop)
#
# Usage: bash deploy.sh
#        bash deploy.sh --simulate    # deploy in dry-run mode (no billing changes)

set -e

# ─────────────────────────────────────────────
# CONFIGURE THESE VALUES
# ─────────────────────────────────────────────
HOST_PROJECT="your-host-project-id"       # Project where the function is deployed
BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"   # gcloud beta billing accounts list
BUDGET_AMOUNT="100USD"                    # Per-project monthly cap

# Spike threshold: requests per SPIKE_WINDOW_SECONDS before killswitch fires.
# 500 req/5min suits low-traffic projects. Raise for high-volume ones.
SPIKE_THRESHOLD=500
SPIKE_WINDOW_SECONDS=300

# All projects to protect (must share the billing account above)
PROJECTS=(
  "your-project-1"
  "your-project-2"
)
# ─────────────────────────────────────────────

TOPIC="billing-alerts"
FUNCTION="kill-billing"
SA_NAME="kill-billing-sa"
REGION="us-central1"
SA_EMAIL="$SA_NAME@$HOST_PROJECT.iam.gserviceaccount.com"

SIMULATE=false
if [[ "$1" == "--simulate" ]]; then
  SIMULATE=true
  echo "==> Simulation mode ON (SIMULATE_DEACTIVATION=true)"
fi

echo "==> Setting active project to $HOST_PROJECT"
gcloud config set project "$HOST_PROJECT"

echo "==> Enabling required APIs"
gcloud services enable \
  cloudfunctions.googleapis.com \
  cloudbilling.googleapis.com \
  pubsub.googleapis.com \
  monitoring.googleapis.com \
  --project="$HOST_PROJECT"

# ── Dedicated service account ────────────────
echo "==> Creating dedicated service account: $SA_EMAIL"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$HOST_PROJECT" &>/dev/null; then
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Billing Killswitch Function" \
    --project="$HOST_PROJECT"
  echo "    Created: $SA_EMAIL"
else
  echo "    Already exists: $SA_EMAIL"
fi

echo "==> Granting roles/logging.logWriter to SA on host project"
gcloud projects add-iam-policy-binding "$HOST_PROJECT" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/logging.logWriter" \
  --condition=None \
  --quiet

echo "==> Granting roles/billing.projectManager to SA on each protected project"
for PROJECT in "${PROJECTS[@]}"; do
  echo "  -> $PROJECT"
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/billing.projectManager" \
    --condition=None \
    --quiet
done

# ── Pub/Sub topic ────────────────────────────
echo "==> Creating Pub/Sub topic: $TOPIC"
gcloud pubsub topics create "$TOPIC" --project="$HOST_PROJECT" 2>/dev/null || echo "    Topic already exists."

# ── Cloud Function ───────────────────────────
echo "==> Deploying Cloud Function: $FUNCTION"
SIMULATE_ENV="false"
$SIMULATE && SIMULATE_ENV="true"

gcloud functions deploy "$FUNCTION" \
  --runtime=python311 \
  --trigger-topic="$TOPIC" \
  --entry-point=kill_billing \
  --region="$REGION" \
  --project="$HOST_PROJECT" \
  --service-account="$SA_EMAIL" \
  --set-env-vars="SIMULATE_DEACTIVATION=$SIMULATE_ENV" \
  --source=.

# ── Cloud Monitoring spike alerts ────────────
echo "==> Creating Pub/Sub notification channel for Cloud Monitoring"
CHANNEL_NAME=$(
  gcloud alpha monitoring channels create \
    --display-name="billing-killswitch-pubsub" \
    --type=pubsub \
    --channel-labels="topic=projects/$HOST_PROJECT/topics/$TOPIC" \
    --project="$HOST_PROJECT" \
    --format="value(name)" 2>/dev/null \
  || gcloud alpha monitoring channels list \
    --filter="displayName=billing-killswitch-pubsub" \
    --project="$HOST_PROJECT" \
    --format="value(name)" | head -1
)
echo "    Channel: $CHANNEL_NAME"

echo "==> Creating request spike alerting policies..."
for PROJECT in "${PROJECTS[@]}"; do
  POLICY_NAME="killswitch-spike-$PROJECT"
  echo "  -> $PROJECT (>${SPIKE_THRESHOLD} req/${SPIKE_WINDOW_SECONDS}s)"

  EXISTING=$(gcloud alpha monitoring policies list \
    --filter="displayName=$POLICY_NAME" \
    --project="$HOST_PROJECT" \
    --format="value(name)" 2>/dev/null | head -1)

  if [ -n "$EXISTING" ]; then
    echo "     Policy already exists, skipping."
    continue
  fi

  gcloud alpha monitoring policies create \
    --display-name="$POLICY_NAME" \
    --project="$HOST_PROJECT" \
    --notification-channels="$CHANNEL_NAME" \
    --condition-display-name="API spike in $PROJECT" \
    --condition-filter="resource.type=\"consumed_api\" AND resource.labels.project_id=\"$PROJECT\" AND metric.type=\"serviceruntime.googleapis.com/api/request_count\"" \
    --condition-threshold-value=$SPIKE_THRESHOLD \
    --condition-threshold-duration="${SPIKE_WINDOW_SECONDS}s" \
    --condition-threshold-comparison=COMPARISON_GT \
    --condition-threshold-aggregations-alignment-period="${SPIKE_WINDOW_SECONDS}s" \
    --condition-threshold-aggregations-per-series-aligner=ALIGN_RATE \
    2>/dev/null || echo "     WARNING: Could not create policy (check alpha API is enabled)"
done

# ── Budget alerts (backstop) ─────────────────
echo "==> Creating budget alerts ($BUDGET_AMOUNT/project)..."
for PROJECT in "${PROJECTS[@]}"; do
  echo "  -> $PROJECT"
  gcloud billing budgets create \
    --billing-account="$BILLING_ACCOUNT" \
    --display-name="killswitch-$PROJECT" \
    --budget-amount="$BUDGET_AMOUNT" \
    --threshold-rule=percent=1.0 \
    --notifications-rule-pubsub-topic="projects/$HOST_PROJECT/topics/$TOPIC" \
    --notifications-rule-disable-default-iam-recipients \
    2>/dev/null || echo "     Budget may already exist, skipping."
done

# ── Summary ──────────────────────────────────
echo ""
echo "==> Done."
echo ""
echo "    PROTECTION LAYERS:"
echo "    1. Spike alert  → ~5 min  (${SPIKE_THRESHOLD} req/${SPIKE_WINDOW_SECONDS}s per project)"
echo "    2. Budget alert → ~24h    ($BUDGET_AMOUNT/project/month)"
echo ""
if $SIMULATE; then
  echo "    MODE: SIMULATION (no billing will actually be disabled)"
  echo "    To arm: bash deploy.sh  (without --simulate)"
  echo ""
fi
echo "    Function:  https://console.cloud.google.com/functions/details/$REGION/$FUNCTION?project=$HOST_PROJECT"
echo "    Budgets:   https://console.cloud.google.com/billing/$BILLING_ACCOUNT/budgets"
echo "    Alerts:    https://console.cloud.google.com/monitoring/alerting?project=$HOST_PROJECT"
