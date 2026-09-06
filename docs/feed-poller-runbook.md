# Feed poller runbook

How the subscribed-podcast episode pull runs, and how to operate it. Milestone
[#38 "Feed polling as a scheduled job"](https://github.com/two4suited/kuulla/milestone/38).

## What it does

Every subscribed show's RSS feed is refetched on a fixed interval and any new episodes are
cached (and, where APNs is configured, pushed to subscribers). This is the only path that caches
a new episode for a subscriber who never opens the app — every other feed fetch is client-driven
(`EpisodeService.GetEpisodesAsync` refetches only when someone opens that show).

The sweep logic lives in `Kuulla.Core` (`FeedPollingService.PollOnceAsync`), shared by:

- **`Kuulla.FeedPoller`** — the worker that owns the sweep. `FeedPollingWorker` is a
  `BackgroundService`.
- **`POST /dev/poll-feeds`** on the API — a dev-only endpoint that runs one sweep on demand
  (loopback + `Development` + `DEBUG` only). Handy for local testing without waiting out an
  interval.

The API itself no longer polls — `FeedPollingBackgroundService` was removed in #415, so the
sweep runs once per tick instead of once per API replica.

## Where it runs

| Environment | Shape |
| --- | --- |
| Local (`aspire run`) | `feed-poller` resource — a long-lived `PeriodicTimer` loop. Sweeps once on startup, then every `FeedPolling:IntervalMinutes`. |
| Local, one-shot | `feed-poller-job` resource — same worker with `FeedPolling__RunOnceThenExit=true` and explicit-start. Hit **Start** in the Aspire dashboard to run one sweep and exit, mirroring a production cron tick. |
| Production | `feed-poller` — an Azure Container Apps **scheduled job** (`Microsoft.App/jobs`), cron `*/15 * * * *`, `parallelism` and `replicaCompletionCount` both `1`. `FeedPolling__RunOnceThenExit=true`, so the container runs one sweep and exits. `replicaTimeout` 1800s. |

The job's managed identity gets Cosmos **Built-in Data Contributor** (read+write) automatically
from the AppHost's `.WithReference(cosmos)` — see `feed-poller-roles-cosmos` in the generated
bicep.

## Schedule / interval

- **Production cadence** is the ACA job's cron: `*/15 * * * *`. Change it in
  `AppHost.cs` (`feedPollerCron`) and redeploy.
- **`FeedPolling:IntervalMinutes`** (env `FeedPolling__IntervalMinutes`) is only read on the
  local `feed-poller` timer loop — default 15, a non-positive or unparsable value falls back to
  15. It has no effect on the production job (the cron is the schedule there) or on
  `feed-poller-job` / `RunOnceThenExit` (single sweep, no timer). Set it low on the
  `feed-poller` resource for a fast local loop.

## Trigger a run manually (production)

```sh
az containerapp job start --name feed-poller --resource-group kuulla-production
```

Then watch it:

```sh
az containerapp job execution list --name feed-poller --resource-group kuulla-production \
  --query "reverse(sort_by([].{name:name,status:properties.status,start:properties.startTime}, &start))" -o table
```

A run should reach `Succeeded` in ~1 minute.

## Logs

Console output goes to the Container Apps environment's Log Analytics workspace
(`ContainerAppConsoleLogs_CL`). **Gotcha:** for *jobs* the `ContainerAppName_s` column is empty —
filter on `ContainerName_s` (or `ContainerGroupName_s`, which is `feed-poller-<execution>-<replica>`),
not `ContainerAppName_s == 'feed-poller'` the way you would for `api` / `web`.

```kusto
ContainerAppConsoleLogs_CL
| where ContainerName_s == "feed-poller" and TimeGenerated > ago(2h)
| order by TimeGenerated asc
| project TimeGenerated, ContainerGroupName_s, Log_s
```

Or straight from ACA (latest execution):

```sh
az containerapp job logs show --name feed-poller --resource-group kuulla-production \
  --container feed-poller --tail 100
```

Each sweep bookends itself with a summary line:

```
Feed-poll sweep starting: <N> subscribed show(s)
Feed-poll sweep complete: <N> show(s), <M> unreachable/malformed, <ms>ms
```

Per-show feed failures log a `warn:` line and are counted in `<M>`; they don't fail the run.
Framework categories (`System.Net.Http.HttpClient`, `Polly`, `Azure.Identity`, `Azure.Core`) are
turned down to `Warning` in the worker's `appsettings.json` so the summary lines aren't buried.

## Verifying the single-sweep guarantee

The point of the cutover (#38) is exactly one sweep per interval regardless of API replica count.
To confirm after a deploy, with `api` scaled past 1 replica:

```kusto
ContainerAppConsoleLogs_CL
| where ContainerName_s == "feed-poller"
| where Log_s startswith "Feed-poll sweep complete:"
| summarize sweeps = count() by bin(TimeGenerated, 15m)
```

Expect one row per 15-minute bin. `api` and `web` console logs should carry no
`Feed-poll sweep` lines at all.

## Deploy notes

- The job revision is provisioned by `aspire deploy` (via `deploy.yml` on a release tag). A green
  deploy doesn't prove the new job image is what runs — check the job's
  `properties.template.containers[0].image` tag (`aspire-deploy-<timestamp>`) and that a fresh
  execution ran on it. This is the job-shaped version of the "ACA revision not promoted" gotcha
  (#404).
- Benign on ACA: `Azure.Identity` IMDS `/metadata/instance` probe errors at startup — the
  credential falls through to the managed identity and succeeds.
