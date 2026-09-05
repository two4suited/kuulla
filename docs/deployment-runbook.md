# Deployment runbook

Operational notes for the Azure Container Apps (ACA) deployment that aren't obvious from the
AppHost code alone. See [Kuulla.AppHost/AppHost.cs](../src/Kuulla.AppHost/AppHost.cs) for the
source of truth on what's actually configured.

## Scale-to-zero (issue #361)

Both `api` and `web` run on the ACA Consumption plan with `Template.Scale.MinReplicas = 0`,
set via a `PublishAsAzureContainerApp` infra callback (there's no dedicated builder method for
min replicas yet). This only applies in publish/deploy mode — local `aspire run`/`aspire start`
is unaffected.

**No custom scale rule is configured.** Leaving `Scale.Rules` empty means ACA applies its own
default HTTP concurrent-requests scale rule, which is what wakes a replica on the first inbound
request. This was confirmed by inspecting the generated Bicep (`aspire publish -o
azure-artifacts`): both `api/api.bicep` and `web/web.bicep` show `scale: { minReplicas: 0 }`
with no `rules` block.

**Readiness/liveness probes don't fight the scale-down window** — the AppHost doesn't configure
any custom ACA probes (no `WithHttpHealthCheck`-style annotations reach the container app
template), so there's nothing generated in the Bicep for `probes:`. ACA's own default TCP
startup probe against the container port is what's in effect, not `/health` or `/alive`
directly. Those `Kuulla.ServiceDefaults` endpoints (see
[Kuulla.ServiceDefaults](../src/Kuulla.ServiceDefaults)) still respond over HTTP on a
cold-started replica the same as any other request — they're just not wired into ACA's probe
config today.

### `web` scales to zero too — this is intentional

Decided during scoping, not an oversight: `web` runs Blazor Server interactivity, meaning open
SignalR circuits live on a specific replica. When that replica scales down to zero on idle,
anyone with the tab open sees a "reconnecting" banner and a fresh cold start on their next
interaction. This is an accepted cost-saving tradeoff, not a bug — don't "fix" it by pinning
`web`'s min replicas back to 1 without revisiting this decision first.

### Known gaps — needs a live deployment to close

The following can't be verified from a local dev environment and need to be measured against
the actual deployed `production` environment (see
[.github/workflows/deploy.yml](../.github/workflows/deploy.yml)):

- End-to-end cold-start latency for `api` (ACA cold start + CosmosDB connection warmup)
  after an idle period, and whether it's acceptable for iOS sync requests.
- Cold-start latency for `web`, relevant once Front Door (#367) is routing traffic to it.
- Confirming ACA's default HTTP scale rule actually triggers a scale-up promptly on real
  traffic patterns, not just that the Bicep omits a custom rule.

If either cold-start number turns out too high for iOS clients, revisit before assuming this
doc is stale — the fix path is likely a custom `Http` scale rule with a lower concurrency
threshold, not abandoning scale-to-zero.

## Production telemetry (issue #366)

`Kuulla.ServiceDefaults`' OpenTelemetry wiring (see
[Extensions.cs](../src/Kuulla.ServiceDefaults/Extensions.cs)) exports to two places depending on
environment:

- **Local `aspire run`/`aspire start`**: the Aspire dashboard, via the OTLP exporter Aspire wires
  up automatically. In-memory, capped retention — fine for local diagnostics, not for production.
- **Deployed**: an Azure Application Insights resource (`insights` in
  [AppHost.cs](../src/Kuulla.AppHost/AppHost.cs)), via `Azure.Monitor.OpenTelemetry.AspNetCore`.
  `WithReference(insights)` on `api` and `web` sets `APPLICATIONINSIGHTS_CONNECTION_STRING` on
  both, which `ConfigureOpenTelemetry` picks up automatically — no other code path changes.

This resource only provisions on an actual `aspire deploy`/`aspire publish`; in Run mode the
connection string stays unset and telemetry keeps flowing to the local dashboard as before.

### Alerting

Basic alerting on the scale-to-zero `api` (error rate, cold-start latency) isn't modeled in the
AppHost itself: Aspire's Azure Monitor hosting integration (`Azure.Provisioning.Monitor`, still
`1.0.0-beta.1` as of writing) generates invalid Bicep for `Microsoft.Insights/metricAlerts` — its
`MetricAlert.WindowSize` serializes to a bogus root-level `WindowSize` property instead of ARM's
actual `properties.windowSize`, which `az bicep build` rejects outright (`BCP037`). Revisit
folding this into the AppHost once that package fixes it.

Until then, run [scripts/setup-monitor-alerts.sh](../scripts/setup-monitor-alerts.sh) once after
each deploy to a new resource group (idempotent — safe to re-run):

```sh
./scripts/setup-monitor-alerts.sh <resource-group> <alert-email>
```

It finds the deployed `insights` Application Insights resource by its `aspire-resource-name` tag
and creates an action group plus two metric alerts scoped to it, filtered to the `api` cloud role
so `web`'s traffic doesn't skew the thresholds:

- **`kuulla-api-elevated-error-rate`** — more than 5 failed requests in a 5-minute window.
- **`kuulla-api-cold-start-latency-spike`** — average request duration over 5s in a 5-minute
  window (a cold start pays container start + Cosmos connection warmup on the first
  request, so this is the practical signal for #361's tradeoff going bad).

### Pulling logs directly from ACA

If Application Insights doesn't have what's needed (data not yet flushed, query scope too
narrow, etc.), pull container logs directly from Azure Container Apps as a fallback:

```sh
az containerapp logs show --name <api-or-web> --resource-group <resource-group> --follow
```
