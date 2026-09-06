namespace Kuulla.Core.Services.Sync;

// docs/sync-conventions.md: the shape a domain's record must expose to participate in the
// generic sync-summary cache and reconciliation routine below.
public interface ISyncableRecord
{
    // Must be the same natural-key value the domain's SyncReconciler adapter uses in its
    // getChangeId delegate (see EpisodeStateService.SyncAsync) — the reconciler matches accepted
    // changes back against records by comparing this Id, so the two need to agree.
    string Id { get; }

    DateTimeOffset UpdatedAt { get; }
}
