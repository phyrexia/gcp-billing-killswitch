#!/bin/bash
# Billing Killswitch — setup and deploy
# Two-layer protection:
#   Layer 1: Cloud Monitoring request spike alert (~5 min latency)
#   Layer 2: Budget alert killswitch ($100/project, ~24h latency backstop)
#
# Run: bash deploy.sh

set -e

HOST_PROJECT="centroriente-06766"
BILLING_ACCOUNT="0151CA-77E33D-1CD57B"
TOPIC="billing-alerts"
FUNCTION="kill-billing"
REGION="us-central1"

# Spike threshold: total API requests across project in a 5-minute window.
# For low-usage projects, 500 req/5min is already a clear anomaly.
# Adjust per project if needed.
SPIKE_THRESHOLD=500
SPIKE_WINDOW_SECONDS=300   # 5 minutes

# Projects to protect
PROJECTS=(
  "centroriente-06766"
  "agentbox-490217"
  "rlone-new"
  "gen-lang-client-0825164862"
  "gen-lang-client-0316466314"
)

echo "==> Setting active project to $HOST_PROJECT"
gcloud config set project $HOST_PROJECT

echo "==> Enabling required APIs"
gcloud services enable \
  cloudfunctions.googleapis.com \
  cloudbilling.googleapis.com \
  pubsub.googleapis.com \
  monitoring.googleapis.com \
  --project=$HOST_PROJECT

echo "==> Creating Pub/Sub topic: $TOPIC"
gcloud pubsub topics create $TOPIC --project=$HOST_PROJECT 2>/dev/null || echo "Topic already exists."

echo "==> Deploying Cloud Function: $FUNCTION"
gcloud functions deploy $FUNCTION \
  --runtime=python311 \
  --trigger-topic=$TOPIC \
  --entry-point=kill_billing \
  --region=$REGION \
  --project=$HOST_PROJECT \
  --source=.

SA=$(gcloud functions describe $FUNCTION --region=$REGION --project=$HOST_PROJECT --format="value(serviceAccountEmail)")
echo "==> Function service account: $SA"

# Create Pub/Sub notification channel for Cloud Monitoring
echo "==> Creating Pub/Sub notification channel for Cloud Monitoring"
CHANNEL_NAME=$(gcloud alpha monitoring channels create \
  --display-name="billing-killswitch-pubsub" \
  --type=pubsub \
  --channel-labels="topic=projects/$HOST_PROJECT/topics/$TOPIC" \
  --project=$HOST_PROJECT \
  --format="value(name)" 2>/dev/null || \
  gcloud alpha monitoring channels list \
    --filter="displayName=billing-killswitch-pubsub" \
    --project=$HOST_PROJECT \
    --format="value(name)" | head -1)

echo "    Notification channel: $CHANNEL_NAME"

# Create Cloud Monitoring alerting policy per project
echo "==> Creating request spike alerting policies..."
for PROJECT in "${PROJECTS[@]}"; do
  POLICY_NAME="killswitch-spike-$PROJECT"
  echo "  -> Spike alert for $PROJECT (>${SPIKE_THRESHOLD} req/${SPIKE_WINDOW_SECONDS}s)"

  # Check if policy already exists
  EXISTING=$(gcloud alpha monitoring policies list \
    --filter="displayName=$POLICY_NAME" \
    --project=$HOST_PROJECT \
    --format="value(name)" 2>/dev/null | head -1)

  if [ -n "$EXISTING" ]; then
    echo "     Policy already exists, skipping."
    continue
  fi

  gcloud alpha monitoring policies create \
    --display-name="$POLICY_NAME" \
    --project=$HOST_PROJECT \
    --notification-channels="$CHANNEL_NAME" \
    --condition-display-name="API spike in $PROJECT" \
    --condition-filter="resource.type=\"consumed_api\" AND resource.labels.project_id=\"$PROJECT\" AND metric.type=\"serviceruntime.googleapis.com/api/request_count\"" \
    --condition-threshold-value=$SPIKE_THRESHOLD \
    --condition-threshold-duration="${SPIKE_WINDOW_SECONDS}s" \
    --condition-threshold-comparison=COMPARISON_GT \
    --condition-threshold-aggregations-alignment-period="${SPIKE_WINDOW_SECONDS}s" \
    --condition-threshold-aggregations-per-series-aligner=ALIGN_RATE \
    2>/dev/null || echo "     WARNING: Could not create monitoring policy for $PROJECT (may need alpha API enabled)"
done

# Create budget alerts (backstop layer)
echo "==> Creating budget killswitches (\$100/month per project)..."
for PROJECT in "${PROJECTS[@]}"; do
  echo "  -> Budget for $PROJECT"
  gcloud billing budgets create \
    --billing-account=$BILLING_ACCOUNT \
    --display-name="killswitch-$PROJECT" \
    --budget-amount=100USD \
    --threshold-rule=percent=1.0 \
    --notifications-rule-pubsub-topic="projects/$HOST_PROJECT/topics/$TOPIC" \
    --notifications-rule-disable-default-iam-recipients \
    2>/dev/null || echo "     Budget may already exist, skipping."
done

echo ""
echo "==> Done."
echo ""
echo "    LAYERS OF PROTECTION:"
echo "    1. Cloud Monitoring spike alert → killswitch (~5 min)"
echo "       Threshold: ${SPIKE_THRESHOLD} requests in ${SPIKE_WINDOW_SECONDS}s per project"
echo "    2. Budget alert → killswitch (\$100/project/month, ~24h backstop)"
echo ""
echo "    MANUAL STEP REQUIRED:"
echo "    Grant Billing Account Administrator to: $SA"
echo "    Go to: https://console.cloud.google.com/billing/$BILLING_ACCOUNT/manage"
echo "    > Add member > Role: Billing Account Administrator"
echo ""
echo "    Function logs: https://console.cloud.google.com/functions/details/$REGION/$FUNCTION?project=$HOST_PROJECT"
echo "    Budgets:        https://console.cloud.google.com/billing/$BILLING_ACCOUNT/budgets"
echo "    Alert policies: https://console.cloud.google.com/monitoring/alerting?project=$HOST_PROJECT"
