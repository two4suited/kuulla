# Account & privacy settings

Spec for [#188](https://github.com/sheridan-apps/kuulla/issues/188)'s "Account &
Privacy" settings section, decided against
[settings-architecture.md](./settings-architecture.md)'s IA (section 11, placed
last since it holds the milestone's only destructive actions). Scoped tightly
around how Kuulla actually authenticates today — Google OAuth only, no
Kuulla-owned password or profile — rather than the issue's research notes, which
describe features (password management, email-link sign-in) that don't apply here.

## Research

- **Pocket Casts**: account email/password management, sign out of all devices,
  export/delete account data, paid-tier management.
- **Overcast**: email-link sign-in (no password), Premium management, data export.

## Existing state

Auth is Google OAuth end to end — `Kuulla.Web.Program.cs` uses
`AddGoogle`/cookie auth (no local password store), the API validates Google-issued
JWTs (`ConfigureGoogleOptions`), and iOS's `AuthManager` wraps Google Sign-In
(`GIDGoogleUser`), exposing `userEmail` and a `signOut()`. There's no Kuulla-owned
password, no email-change flow, and no existing data-export or account-deletion
endpoint.

The real sign-out sequence is more than `AuthManager.signOut()`: `ContentView.swift`
awaits `PushNotificationManager.shared.unregisterCurrentDevice()` first (so the APNs
token is removed before the local session clears), then calls
`authManager.signOut()`. Web's equivalent endpoint is `POST /Account/Logout`
(`Program.cs`), not `/signout`.

Every authenticated request re-runs `OnTokenValidated` →
`UserService.GetOrCreateUserAsync(subject, ...)` (`Program.cs`) — a valid Google JWT
transparently *recreates* the `users` document if it's missing. Auth is otherwise
fully stateless: there's no session/token registry, and nothing today rejects a
request just because its subject was previously deleted.

A user's data spans, per container:

| Container | Partition key | Contains |
|---|---|---|
| `users` | `UserId` (the Google subject) | Account record |
| `settings` | `UserId` for `UserSettings`; **`ShowSettings`'s own composite `id`** for per-show overrides (`SettingsService`'s `PartitionKey(updated.Id)` calls) — not `UserId` | Global settings + per-show overrides |
| `subscriptions` | `UserId` | Subscribed shows |
| `episodestates` | `UserId` | Playback/listened state |
| `playlists` | `UserId` | Up Next / custom playlists |
| `devicetokens` | `UserId` | APNs push tokens |

`ShowSettings` is the one exception to "single-partition query by `UserId`" — since
its documents are keyed by their own `show:{userId}:{showId}` id, finding all of one
user's `ShowSettings` rows needs a cross-partition query
(`WHERE c.type = 'ShowSettings' AND c.userId = @userId`) to enumerate them, not a
single-partition read.

Cosmos is the only per-user store — there is no cache tier. Sync summaries and every
other derived value are recomputed from Cosmos on demand, so a deletion that clears
the Cosmos rows leaves nothing else behind.

iOS's local SwiftData store (`KuullaApp.swift`'s `ModelContainer`, backing
`UserSettingsRecord`/`EpisodeStateRecord`/`Playlist`/`SyncCursor`/
`DownloadedEpisodeRecord`) is not scoped per signed-in account at all today — there's
no user id on any of its records, and sign-out doesn't clear it.

## Decisions

### Account profile & password

- No email/display-name/password fields in Kuulla's own UI — there's nothing
  Kuulla-owned to edit; identity, email, and password are entirely Google's. The
  settings screen shows the signed-in Google account's email (already available via
  `AuthManager.userEmail` / the Web auth cookie's claims) as read-only text, with a
  "Manage your Google Account" link out to Google's own account settings for anyone
  who wants to change their email or password.
- No in-app account creation/linking beyond the existing "Sign in with Google"
  flow — this section only surfaces the account already signed into, it doesn't
  change how sign-in itself works.

### Sign out

- A "Sign Out" action reusing the **exact existing sequence**, not a
  simplified version of it: iOS awaits
  `PushNotificationManager.shared.unregisterCurrentDevice()` first, then calls
  `authManager.signOut()` (`ContentView.swift`'s existing ordering); Web posts to
  the existing `POST /Account/Logout` endpoint. This is a Settings-screen entry
  point for that existing flow, not new sign-out behavior.
- **New requirement surfaced by adding this entry point**: because the local
  SwiftData store isn't scoped per account (see "Existing state"), sign-out must
  also clear it — every `UserSettingsRecord`/`EpisodeStateRecord`/`Playlist`/
  `SyncCursor`/`DownloadedEpisodeRecord` (deleting the backing downloaded files
  too, not just the metadata rows) — so a second Google account signing in on the
  same device doesn't see or silently merge with the previous account's local
  data. This is a pre-existing gap (today's sign-out doesn't do this either), not
  something new to this issue, but this is the issue that puts a "Sign Out" button
  in front of users deliberately, so it needs to actually be correct before
  shipping it as a first-class settings action.
- No "sign out of all devices": there's no server-side session registry to
  invalidate against (Google-issued JWTs are validated statelessly per request, and
  `DeviceToken` is a push-notification token registry, not an auth session list) —
  building one is a bigger authentication change than this settings-catalog
  milestone's scope. Deleting the account (below) is the mechanism that actually
  cuts off every device at once, by rejecting the shared identity itself rather
  than by enumerating sessions.

### Data export

- New "Request Data Export" action and a new API endpoint (e.g.
  `GET /api/account/export`) that reads the signed-in user's documents across
  `subscriptions`, `settings` (`UserSettings` + that user's `ShowSettings` rows —
  the latter via the cross-partition query described in "Existing state"),
  `episodestates`, and `playlists`, and returns them as one downloadable JSON
  file — synchronous, no background job/email-delivery pipeline, since a single
  user's data across these containers is small enough to serialize in one request.
- Excludes `users` (internal account record, not listening data) and `devicetokens`
  (push plumbing, not something a user needs a copy of).

### Account deletion

Deletion has to close the gap "delete the rows" leaves open: `GetOrCreateUserAsync`
silently recreates the `users` document the next time *any* still-valid Google JWT
for that subject hits the API, so a second signed-in device (or the same device,
still holding a valid token) would keep working — and keep writing new
subscriptions/episode state/etc. — as if nothing happened, unless something at the
auth layer actively rejects that identity going forward.

- **Tombstone, not a bare delete, for `users`**: deleting the account replaces the
  `users` document with a minimal tombstone record (`UserId`, `DeletedAt`) instead
  of removing it outright. `OnTokenValidated`'s existing
  `GetOrCreateUserAsync` call gains a check: if the resolved user is tombstoned,
  reject the request (`401`) instead of proceeding — this is the actual mechanism
  that revokes every device at once, immediately on that device's next request,
  without needing a session/token registry. (A real user-record delete would just
  get silently recreated by the next valid token, as described above — the
  tombstone is what makes deletion stick.)
- **Deletion order and idempotency**: because this spans multiple containers and
  can't be a single Cosmos transaction, the tombstone write happens *first* — it's
  the one step that must land before anything else, since it's what stops further
  writes to the account being deleted. Every subsequent step (deleting
  `subscriptions`/`episodestates`/`playlists`/`devicetokens`/`settings`) is a delete
  of something keyed by that `UserId`, which is naturally idempotent — deleting an
  already-deleted document is a no-op, not an error. `DELETE /api/account` is
  therefore safe to call again if a previous attempt only got partway through:
  retrying re-runs every step, and anything already deleted is skipped rather than
  failing. The endpoint's response only reports success once every step has
  completed; a client that gets an error or times out treats the deletion as
  **incomplete**, not done, and should retry rather than assuming partial progress
  means the account is gone.
- **Cosmos scope**: `subscriptions`, `episodestates`, `playlists`, `devicetokens`
  (each a single-partition delete-by-`UserId` query), plus `settings`'s
  `UserSettings` document (single-partition, by `UserId`) and every `ShowSettings`
  row for that user (the cross-partition-then-per-id delete described in "Existing
  state" — each `ShowSettings` row has its own partition key, so this can't be a
  single-partition operation the way the others are).
- **No cache tier to purge**: there is no Redis (or other) cache holding per-user
  data — sync summaries and every other derived value are recomputed from Cosmos on
  demand — so clearing the Cosmos rows above is the whole server-side deletion.
- **iOS local data**: the delete flow finishes with the same local-store clear
  "Sign Out" now performs (see above), not a separate implementation — deleting the
  account without also purging local SwiftData records would leave the exact same
  cross-account data-leak risk sign-out already has to close.
- A "Delete Account" action, behind a confirmation step (type the account's email
  to confirm, mirroring the weight of the action rather than a plain Yes/No dialog
  that's easy to tap through by accident).
- No soft-delete/grace-period undo window for this milestone — Pocket Casts and
  Overcast both perform account deletion immediately; adding a recovery window is
  its own design problem (where deleted-but-recoverable data lives, how long,
  whether it's still counted anywhere) that isn't needed to satisfy "let a user
  delete their data." (The tombstone record itself is not a recovery window — it
  carries no data to restore, only the fact that the identity is deleted.)

### Privacy: analytics & crash reporting

- No opt-out setting for either — Kuulla has no client-side analytics or crash
  reporting SDK today (the OpenTelemetry wired up via
  `Kuulla.ServiceDefaults`/`AddServiceDefaults()` is server-side request
  tracing/metrics for the API and Web services, not a user-analytics or
  crash-reporting product collecting client behavior). There's nothing to expose a
  toggle for; if client-side analytics or crash reporting is added later, that
  feature's own issue should add the opt-out alongside it rather than this issue
  speccing a control for a collection mechanism that doesn't exist.

### Paid tier

- Out of scope, as the issue itself notes — Kuulla has no paid tier today. No
  placeholder UI for one.

## Data model

No `UserSettings`/`ShowSettings` field changes — this section is entirely actions
(sign out, export, delete) and a read-only account-email display sourced from the
existing auth claims, not a settings toggle to persist or sync. `User` (the `users`
container's record) gains a new `DeletedAt : DateTimeOffset?` field for the
tombstone described above (`null` = active account).

Two new API endpoints, not modeled as settings-sync data:

```
GET    /api/account/export   → JSON bundle of the signed-in user's
                                subscriptions/settings (UserSettings + ShowSettings rows)/
                                episodestates/playlists documents
DELETE /api/account          → idempotent, retry-safe: tombstones the users document first
                                (DeletedAt set, checked by OnTokenValidated going forward),
                                then deletes Cosmos rows across
                                settings/subscriptions/episodestates/playlists/devicetokens
                                (no cache tier to purge);
                                the client then runs the same local-store clear as
                                "Sign Out" and signs out
```

## UI

- iOS `SettingsView.swift` / Web `Settings.razor`: an "Account & Privacy" section
  (position 11, last) with:
  - Signed-in account email (read-only) + "Manage your Google Account" link.
  - "Request Data Export" row, triggering the download.
  - "Sign Out" row.
  - "Delete Account" row, styled as destructive (SwiftUI `Button(role: .destructive)`
    / a red Web button — `SettingsView.swift`'s existing red `.foregroundStyle(.red)`
    text today is only ever used for save-error messages, not a button role, so this
    introduces the first destructive-action control in the file, not a reuse of an
    existing pattern), opening the type-to-confirm flow before calling the delete
    endpoint.
- No per-show override entry point — nothing in this section is a per-show setting.
