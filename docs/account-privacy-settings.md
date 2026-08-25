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
(`GIDGoogleUser`), exposing `userEmail` and a `signOut()` that clears the local
session. There's no Kuulla-owned password, no email-change flow, and no existing
data-export or account-deletion endpoint. A user's data lives across the `users`,
`settings`, `subscriptions`, `episodestates`, `playlists`, and `devicetokens` Cosmos
containers (`Kuulla.Api.Program.cs`'s container wiring), all partitioned/keyed by
`UserId` (`devicetokens` per `DeviceToken`'s own container-partitioning comment).

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

- A "Sign Out" action reusing the existing per-device flow (`AuthManager.signOut()`
  on iOS, the Web `/signout` cookie-clear endpoint in `Program.cs`) — not new
  behavior, just a Settings-screen entry point alongside the destructive actions
  below instead of wherever it's triggered from today.
- No "sign out of all devices": there's no server-side session registry to
  invalidate against (Google-issued JWTs are validated statelessly per request, and
  `DeviceToken` is a push-notification token registry, not an auth session list) —
  building one is a bigger authentication change than this settings-catalog
  milestone's scope. Deleting the account (below) is the actual way to revoke every
  device at once, since it deletes the `DeviceToken` rows those devices' pushes
  depend on along with everything else.

### Data export

- New "Request Data Export" action and a new API endpoint (e.g.
  `GET /api/account/export`) that reads the signed-in user's documents across
  `subscriptions`, `settings` (`UserSettings` + that user's `ShowSettings` rows),
  `episodestates`, and `playlists` (all already partitioned/keyed by `UserId`, so
  each is a single-partition query) and returns them as one downloadable JSON
  file — synchronous, no background job/email-delivery pipeline, since a single
  user's data across these containers is small enough to serialize in one request.
- Excludes `users` (internal account record, not listening data) and `devicetokens`
  (push plumbing, not something a user needs a copy of).

### Account deletion

- New "Delete Account" action, behind a confirmation step (type the account's email
  to confirm, mirroring the weight of the action rather than a plain Yes/No dialog
  that's easy to tap through by accident) and a new API endpoint (e.g.
  `DELETE /api/account`) that deletes the user's documents from every container
  listed under "Existing state" — `users`, `settings` (both `UserSettings` and all
  of that user's `ShowSettings` rows), `subscriptions`, `episodestates`,
  `playlists`, `devicetokens` — then signs the device out locally the same way the
  "Sign Out" action above does.
- No soft-delete/grace-period undo window for this milestone — Pocket Casts and
  Overcast both perform account deletion immediately; adding a recovery window is
  its own design problem (where deleted-but-recoverable data lives, how long,
  whether it's still counted anywhere) that isn't needed to satisfy "let a user
  delete their data."

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
existing auth claims, not a settings toggle to persist or sync.

Two new API endpoints, not modeled as settings-sync data:

```
GET    /api/account/export   → JSON bundle of the signed-in user's
                                subscriptions/settings/episodestates/playlists documents
DELETE /api/account          → deletes the signed-in user's documents across
                                users/settings/subscriptions/episodestates/playlists/devicetokens,
                                then the client signs out locally
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
