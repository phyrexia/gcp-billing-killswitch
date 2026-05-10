import base64
import json
from googleapiclient import discovery


def kill_billing(event, context):
    """
    Cloud Function triggered by Pub/Sub.
    Handles two sources:
      1. Billing budget alerts  — fires when monthly cost >= budget (~24h latency)
      2. Cloud Monitoring alerts — fires on request spike (~5 min latency)
    Either one disables billing on the affected project immediately.
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
            print(f"Monitoring alert resolved/closed for {project_id}. No action.")
            return

        if not project_id:
            print(f"WARNING: No project_id in monitoring incident. Condition: {condition}")
            return

        print(f"MONITORING SPIKE: project={project_id} condition={condition}")
        print(f"KILLSWITCH TRIGGERED (spike): disabling billing for {project_id}")
        _disable_billing(project_id)
        return

    # --- Source 2: Billing budget alert ---
    project_id = attributes.get('billing.googleapis.com/ProjectId', '')
    cost = pubsub_data.get('costAmount', 0)
    budget = pubsub_data.get('budgetAmount', 0)
    budget_name = pubsub_data.get('budgetDisplayName', 'unknown')
    currency = pubsub_data.get('currencyCode', 'USD')

    if not project_id:
        print(f"WARNING: No project_id in message. Budget: {budget_name}")
        return

    print(f"Budget alert: project={project_id} cost={cost} {currency} budget={budget} {currency}")

    if cost >= budget:
        print(f"KILLSWITCH TRIGGERED (budget): {project_id} — {cost} >= {budget} {currency}")
        _disable_billing(project_id)
    else:
        print(f"OK: {project_id} — {cost} < {budget} {currency}. No action.")


def _disable_billing(project_id):
    billing = discovery.build('cloudbilling', 'v1', cache_discovery=False)
    request = billing.projects().updateBillingInfo(
        name=f'projects/{project_id}',
        body={'billingAccountName': ''}
    )
    response = request.execute()
    print(f"Billing disabled for {project_id}: {response}")
