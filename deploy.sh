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
  billingbudgets.googleapis.com \
  pubsub.googleapis.com \
  monitoring.googleapis.com \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  eventarc.googleapis.com \
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
  --condition=None --quiet

echo "==> Granting roles/eventarc.eventReceiver to SA on host project"
gcloud projects add-iam-policy-binding "$HOST_PROJECT" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/eventarc.eventReceiver" \
  --condition=None --quiet

echo "==> Granting roles/billing.admin to SA on billing account"
gcloud beta billing accounts add-iam-policy-binding "$BILLING_ACCOUNT" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/billing.admin" --quiet

echo "==> Granting roles/billing.projectManager to SA on each protected project"
for PROJECT in "${PROJECTS[@]}"; do
  echo "  -> $PROJECT"
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/billing.projectManager" \
    --condition=None --quiet
done

# Allow Eventarc service agent to create tokens for trigger SA
PROJECT_NUMBER=$(gcloud projects describe "$HOST_PROJECT" --format="value(projectNumber)")
EVENTARC_SA="service-${PROJECT_NUMBER}@gcp-sa-eventarc.iam.gserviceaccount.com"
echo "==> Granting iam.serviceAccountTokenCreator to Eventarc SA"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --member="serviceAccount:$EVENTARC_SA" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$HOST_PROJECT" --quiet

# ── Pub/Sub topic ────────────────────────────
echo "==> Creating Pub/Sub topic: $TOPIC"
gcloud pubsub topics create "$TOPIC" --project="$HOST_PROJECT" 2>/dev/null \
  || echo "    Topic already exists."

# Allow Cloud Run (Gen2 function trigger) to invoke the function
echo "==> Granting run.invoker to Pub/Sub SA and trigger SA"
PUBSUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"
# Note: run.invoker on the Cloud Run service is set after deploy (SA email known then)

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

# Grant run.invoker after deploy (Cloud Run service name is now known)
echo "==> Granting run.invoker for Pub/Sub and trigger SA on Cloud Run service"
for MEMBER in "serviceAccount:$PUBSUB_SA" "serviceAccount:$SA_EMAIL"; do
  gcloud run services add-iam-policy-binding "$FUNCTION" \
    --region="$REGION" \
    --project="$HOST_PROJECT" \
    --member="$MEMBER" \
    --role="roles/run.invoker" --quiet 2>/dev/null || true
done

# ── Cloud Monitoring spike alerts ────────────
echo "==> Creating Pub/Sub notification channel for Cloud Monitoring"
CHANNEL_NAME=$(
  gcloud beta monitoring channels create \
    --display-name="billing-killswitch-pubsub" \
    --type=pubsub \
    --channel-labels="topic=projects/$HOST_PROJECT/topics/$TOPIC" \
    --project="$HOST_PROJECT" \
    --format="value(name)" 2>/dev/null \
  || gcloud beta monitoring channels list \
    --filter="displayName=billing-killswitch-pubsub" \
    --project="$HOST_PROJECT" \
    --format="value(name)" | head -1
)
echo "    Channel: $CHANNEL_NAME"

echo "==> Creating request spike alerting policies..."
echo "    NOTE: Policies only cover projects in this monitoring scope."
echo "    To monitor other projects: Monitoring > Settings > Add GCP projects"
for PROJECT in "${PROJECTS[@]}"; do
  POLICY_NAME="killswitch-spike-$PROJECT"
  echo "  -> $PROJECT (>${SPIKE_THRESHOLD} req/${SPIKE_WINDOW_SECONDS}s)"

  EXISTING=$(gcloud monitoring policies list \
    --filter="displayName=$POLICY_NAME" \
    --project="$HOST_PROJECT" \
    --format="value(name)" 2>/dev/null | head -1)

  if [ -n "$EXISTING" ]; then
    echo "     Already exists, skipping."
    continue
  fi

  POLICY_FILE=$(mktemp /tmp/policy-XXXXXX.json)
  cat > "$POLICY_FILE" <<EOF
{
  "displayName": "$POLICY_NAME",
  "conditions": [{
    "displayName": "API spike in $PROJECT",
    "conditionThreshold": {
      "filter": "resource.type=\"consumed_api\" AND resource.labels.project_id=\"$PROJECT\" AND metric.type=\"serviceruntime.googleapis.com/api/request_count\"",
      "aggregations": [{"alignmentPeriod": "${SPIKE_WINDOW_SECONDS}s", "perSeriesAligner": "ALIGN_RATE"}],
      "comparison": "COMPARISON_GT",
      "thresholdValue": $SPIKE_THRESHOLD,
      "duration": "0s"
    }
  }],
  "alertStrategy": {"autoClose": "1800s"},
  "notificationChannels": ["$CHANNEL_NAME"],
  "combiner": "OR"
}
EOF
  gcloud monitoring policies create \
    --policy-from-file="$POLICY_FILE" \
    --project="$HOST_PROJECT" \
    --format="value(name)" 2>&1 \
  || echo "     WARNING: Policy creation failed (project may not be in monitoring scope)"
  rm -f "$POLICY_FILE"
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
    --filter-projects="projects/$PROJECT" \
    --format="value(name)" 2>/dev/null \
  || echo "     Already exists, skipping."
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
echo ""
echo "    MULTI-PROJECT SPIKE DETECTION:"
echo "    To enable spike alerts for projects outside HOST_PROJECT, add them"
echo "    to the monitoring metrics scope:"
echo "    https://console.cloud.google.com/monitoring/settings?project=$HOST_PROJECT"
