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

    // Tombstone marker (#400): a deleted record is kept in storage with Deleted = true and a
    // fresh server-stamped UpdatedAt, rather than hard-deleted, so the deletion propagates
    // through sync like any other change — SyncReconciler returns it in the delta and
    // SyncSummary folds its moved UpdatedAt into the hash. Client adapters apply an incoming
    // tombstone by removing the local record. A domain with no delete operation (episode state,
    // settings) never sets this, so it defaults to false and those records are unaffected.
    // Tombstones are GC'd by the domain adapter once they age past the sync retention window
    // (docs/sync-conventions.md).
    bool Deleted => false;
}
