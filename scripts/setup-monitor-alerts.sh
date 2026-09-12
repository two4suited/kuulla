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

# A silent feed-poller sweep failure (#558): a Cosmos 429 (or any other unhandled error) that
# crashes the sweep still exits 0, so ACA marks the job execution Succeeded — nothing shows up as
# unhealthy unless something actively looks for the "Feed-poll sweep complete:" line the sweep
# logs on success (docs/feed-poller-runbook.md). Modeled as a Log Analytics scheduled query rule
# (not a metrics alert, since the condition is "line absent", not a numeric threshold on a metric)
# against the ACA environment's Log Analytics workspace, found the same way as the App Insights
# resource above — by its aspire-resource-name tag.
workspace_name=$(az resource list \
  --resource-group "$resource_group" \
  --resource-type "Microsoft.OperationalInsights/workspaces" \
  --query "[?tags.\"aspire-resource-name\"!=null].name | [0]" \
  --output tsv)

if [ -z "$workspace_name" ]; then
  echo "Could not find a Log Analytics workspace tagged aspire-resource-name in $resource_group — skipping feed-poller sweep alert." >&2
else
  workspace_id=$(az resource show \
    --resource-group "$resource_group" \
    --resource-type "Microsoft.OperationalInsights/workspaces" \
    --name "$workspace_name" \
    --query id --output tsv)
  workspace_location=$(az resource show \
    --resource-group "$resource_group" \
    --resource-type "Microsoft.OperationalInsights/workspaces" \
    --name "$workspace_name" \
    --query location --output tsv)

  # Cron is daily (0 3 * * *, docs/feed-poller-runbook.md): a 24h rolling window should contain
  # exactly one "Feed-poll sweep complete:" line, so 0 means that day's sweep either crashed or
  # never ran. Evaluated hourly so a missed day is caught well within the day, not just at the
  # boundary.
  az monitor scheduled-query create \
    --resource-group "$resource_group" \
    --name "kuulla-feed-poller-sweep-missing" \
    --description "feed-poller ACA job ran without logging a completed sweep (issue #558)." \
    --location "$workspace_location" \
    --scopes "$workspace_id" \
    --condition "count \"ContainerAppConsoleLogs_CL | where ContainerName_s == 'feed-poller' | where Log_s startswith 'Feed-poll sweep complete:'\" < 1" \
    --window-size 1d \
    --evaluation-frequency 1h \
    --severity 2 \
    --action-groups "$action_group_id" \
    --output none

  echo "Feed-poller sweep alert configured on $workspace_name in $resource_group."
fi

echo "Alerts configured on $insights_name in $resource_group, notifying $alert_email."
