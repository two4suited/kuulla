import SwiftUI

// The single gear-icon entry point for the subscribed-shows display settings, shared by
// LibraryView and SubscriptionsView (#488). Replaces the old pair of toolbar items — an
// `arrow.up.arrow.down` sort menu and a separate `ShowIconSizeMenu` — with one `gearshape`
// menu holding all three controls:
//   • Sort order — inline Picker, so it reads as a checkmark list rather than a wheel.
//   • Hide caught-up shows — a Toggle.
//   • Icon size — inline Picker, bound straight to the device-local UserDefaults key.
//
// Sort order and hide-caught-up are passed in as bindings the host view already owns (with its
// optimistic-save + rollback wiring); icon size is device-local so it's handled here directly,
// matching how `ShowIconSizeMenu` used to.
struct ShowDisplaySettingsMenu: View {
    @Binding var sortOrder: SubscriptionSortOrder
    @Binding var hideCaughtUpShows: Bool
    var isDisabled: Bool

    @AppStorage(ShowIconSize.storageKey) private var iconSizeRaw = ShowIconSize.default.rawValue

    private var iconSize: Binding<ShowIconSize> {
        Binding(
            get: { ShowIconSize.current(iconSizeRaw) },
            set: { iconSizeRaw = $0.rawValue })
    }

    var body: some View {
        Menu {
            Picker("Sort order", selection: $sortOrder) {
                ForEach(SubscriptionSortOrder.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Toggle("Hide caught-up shows", isOn: $hideCaughtUpShows)

            Divider()

            Picker("Icon size", selection: iconSize) {
                ForEach(ShowIconSize.allCases) { size in
                    Label(size.label, systemImage: size.systemImage).tag(size)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Display settings")
        .disabled(isDisabled)
    }
}
