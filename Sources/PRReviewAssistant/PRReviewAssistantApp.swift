import SwiftUI

@main
struct PRReviewAssistantApp: App {
    @AppStorage("appearance") private var appearance = AppAppearance.defaultTheme.rawValue
    @State private var store = ReviewStore()
    @State private var petWindowController = PetWindowController()

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .defaultTheme
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .preferredColorScheme(selectedAppearance.colorScheme)
                .tint(BrandColor.prPurple)
                .onAppear { petWindowController.update(store: store) }
                .onChange(of: store.petVisible) { _, _ in petWindowController.update(store: store) }
                .onChange(of: store.petSize) { _, _ in petWindowController.update(store: store) }
        }
        .defaultSize(width: 1220, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("새로 고침") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra("PR Review Assistant", systemImage: store.unreadCount == 0 ? "checkmark.circle" : "bell.badge") {
            MenuBarView(store: store)
        }

        Settings {
            SettingsView(store: store)
                .preferredColorScheme(selectedAppearance.colorScheme)
        }
    }
}
