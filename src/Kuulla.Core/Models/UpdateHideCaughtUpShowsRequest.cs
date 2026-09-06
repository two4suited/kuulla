namespace Kuulla.Core.Models;

// Body for PUT /api/settings/hide-caught-up-shows (#438 follow-up) — toggles whether the
// Library/Subscriptions shows list hides shows the user is caught up on.
public record UpdateHideCaughtUpShowsRequest(bool HideCaughtUpShows);
