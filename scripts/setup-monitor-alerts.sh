#!/usr/bin/env bash
# Basic alerting for the scale-to-zero `api` (issue #366): elevated error rate and cold-start
# latency spikes on the Application Insights resource added to the AppHost by that same issue,
# so #361's scale-to-zero tradeoff is monitored instead of just assumed acceptable.
#
# Not modeled in the AppHost itself: Aspire's Azure Monitor hosting integration
# (Azure.Provisioning.Monitor, still 1.0.0-beta.1 as of writing) generates invalid Bicep for
# Microsoft.Insights/metricAlerts — its MetricAlert.WindowSize serializes to a bogus root-level
# "WindowSize" property instead of ARM's actual properties.windowSize, which `az bicep build`
# rejects outright (BCP037). Revisit folding this into the AppHost once that package is fixed.
#
# Run manually after `aspire deploy`/`aspire publish` (needs `az login` and the resource group
# that deploy created). Both `az monitor action-group create` and `az monitor metrics alert
# create` are upserts by name, so re-running this is safe.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <resource-group> <alert-email> [app-insights-name]" >&2
  exit 1
fi

resource_group="$1"
alert_email="$2"
insights_name="${3:-}"

for dependency in az; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Missing dependency: $dependency" >&2
    exit 1
  fi
done

if [ -z "$insights_name" ]; then
  # The AppHost's `insights` resource gets a generated name (insights-<uniqueString>); find it by
  # the aspire-resource-name tag Aspire stamps on everything it provisions.
  insights_name=$(az resource list \
    --resource-group "$resource_group" \
    --resource-type "Microsoft.Insights/components" \
    --query "[?tags.\"aspire-resource-name\"=='insights'].name | [0]" \
    --output tsv)
fi

if [ -z "$insights_name" ]; then
  echo "Could not find an Application Insights resource tagged aspire-resource-name=insights in $resource_group" >&2
  echo "Pass its name explicitly as the third argument." >&2
  exit 1
fi

insights_id=$(az resource show \
  --resource-group "$resource_group" \
  --resource-type "Microsoft.Insights/components" \
  --name "$insights_name" \
  --query id --output tsv)

action_group_name="kuulla-api-alerts"

az monitor action-group create \
  --resource-group "$resource_group" \
  --name "$action_group_name" \
  --short-name "kuulla-api" \
  --action email oncall "$alert_email" \
  --output none

action_group_id=$(az monitor action-group show \
  --resource-group "$resource_group" \
  --name "$action_group_name" \
  --query id --output tsv)

# Failed-request count over 5 minutes, scoped to the "api" cloud role so web's traffic doesn't
# skew api's threshold — both apps share this one Application Insights resource.
az monitor metrics alert create \
  --resource-group "$resource_group" \
  --name "kuulla-api-elevated-error-rate" \
  --description "Elevated error rate on the api Container App (issue #366)." \
  --scopes "$insights_id" \
  --condition "count requests/failed where cloud/roleName includes 'api' > 5" \
  --window-size 5m \
  --evaluation-frequency 5m \
  --severity 2 \
  --action "$action_group_id" \
  --output none

# Average request duration over 5 minutes — a cold start (#361) drives this up sharply, since a
# scaled-to-zero replica's first request pays container start + Cosmos/Redis connection warmup.
az monitor metrics alert create \
  --resource-group "$resource_group" \
  --name "kuulla-api-cold-start-latency-spike" \
  --description "Cold-start latency spike on the api Container App (issue #366, #361)." \
  --scopes "$insights_id" \
  --condition "avg requests/duration where cloud/roleName includes 'api' > 5000" \
  --window-size 5m \
  --evaluation-frequency 5m \
  --severity 2 \
  --action "$action_group_id" \
  --output none

echo "Alerts configured on $insights_name in $resource_group, notifying $alert_email."
