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

- End-to-end cold-start latency for `api` (ACA cold start + CosmosDB/Redis connection warmup)
  after an idle period, and whether it's acceptable for iOS sync requests.
- Cold-start latency for `web`, relevant once Front Door (#367) is routing traffic to it.
- Confirming ACA's default HTTP scale rule actually triggers a scale-up promptly on real
  traffic patterns, not just that the Bicep omits a custom rule.

If either cold-start number turns out too high for iOS clients, revisit before assuming this
doc is stale — the fix path is likely a custom `Http` scale rule with a lower concurrency
threshold, not abandoning scale-to-zero.
