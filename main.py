import base64
import json
import os
from googleapiclient import discovery
from googleapiclient.errors import HttpError  # noqa: F401 used in _disable_billing

# Set SIMULATE_DEACTIVATION=true to test the full pipeline without actually
# disabling billing. Logs "[SIMULATE]" instead of making API changes.
SIMULATE = os.getenv("SIMULATE_DEACTIVATION", "false").lower() == "true"


def kill_billing(event, context):
    """
    Cloud Function triggered by Pub/Sub.
    Handles two alert sources:
      1. Cloud Monitoring incident (request spike) — ~5 min latency
      2. Billing budget alert (monthly cost threshold) — ~24h latency
    Either source triggers an immediate billing disable on the affected project.
    """
    attributes = event.get('attributes', {})
    pubsub_message = base64.b64decode(event['data']).decode('utf-8')
    pubsub_data = json.loads(pubsub_message)

    # --- Source 1: Cloud Monitoring incident alert ---
    if 'incident' in pubsub_data:
        incident = pubsub_data['incident']
        project_id = (
            incident.get('resource', {}).get('labels', {}).get('project_id') or
            incident.get('scoping_project_id', '')
        )
        condition = incident.get('condition_name', 'unknown condition')
        state = incident.get('state', '')

        if state != 'open':
            print(f"Monitoring alert closed/resolved for {project_id}. No action.")
            return

        if not project_id:
            print(f"WARNING: No project_id in monitoring incident. Condition: {condition}")
            return

        print(f"MONITORING SPIKE: project={project_id} condition={condition}")
        _disable_billing(project_id)
        return

    # --- Source 2: Billing budget alert ---
    project_id = attributes.get('billing.googleapis.com/ProjectId', '')
    cost = pubsub_data.get('costAmount', 0)
    budget = pubsub_data.get('budgetAmount', 0)
    budget_name = pubsub_data.get('budgetDisplayName', 'unknown')
    currency = pubsub_data.get('currencyCode', 'USD')

    if not project_id:
        print(f"WARNING: No project_id in message attributes. Budget: {budget_name}")
        return

    print(f"Budget alert: project={project_id} cost={cost} {currency} / {budget} {currency} ({budget_name})")

    if cost >= budget:
        print(f"KILLSWITCH: {project_id} — {cost} >= {budget} {currency}")
        _disable_billing(project_id)
    else:
        print(f"OK: {project_id} — {cost} < {budget} {currency}. No action.")


def _disable_billing(project_id):
    if SIMULATE:
        print(f"[SIMULATE] Would have disabled billing for {project_id}. "
              f"Set SIMULATE_DEACTIVATION=false (or unset it) to arm the killswitch.")
        return

    billing = discovery.build('cloudbilling', 'v1', cache_discovery=False)
    try:
        # updateBillingInfo with empty billingAccountName unlinks the project.
        # Idempotent: if billing is already disabled it returns the current state.
        response = billing.projects().updateBillingInfo(
            name=f'projects/{project_id}',
            body={'billingAccountName': ''}
        ).execute()
        if response.get('billingEnabled', False):
            print(f"WARNING: billing still enabled for {project_id} after update: {response}")
        else:
            print(f"Billing disabled for {project_id}.")
    except HttpError as e:
        if e.resp.status == 403:
            print(
                f"ERROR: Permission denied disabling billing for {project_id}. "
                f"Ensure the function SA has roles/billing.admin on the billing account."
            )
        else:
            raise
