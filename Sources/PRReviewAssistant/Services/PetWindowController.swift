import AppKit
import SwiftUI

@MainActor
final class PetWindowController: NSObject {
    private enum DefaultsKey {
        static let x = "desktopPet.position.x"
        static let y = "desktopPet.position.y"
    }

    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?

    func update(store: ReviewStore) {
        guard store.petVisible else {
            panel?.orderOut(nil)
            return
        }

        let size = CGFloat(store.petSize)
        let rootView = PetWindowView(store: store, activateMainWindow: activateMainWindow)
            .frame(width: size, height: size)

        if let panel {
            panel.contentView = NSHostingView(rootView: rootView)
            panel.setContentSize(NSSize(width: size, height: size))
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: restoredOrigin(for: size), size: NSSize(width: size, height: size)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = NSHostingView(rootView: rootView)
        panel.orderFrontRegardless()
        self.panel = panel
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.savePosition()
            }
        }
    }

    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0 != panel && $0.isVisible })?.makeKeyAndOrderFront(nil)
    }

    private func restoredOrigin(for size: CGFloat) -> NSPoint {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKey.x) != nil, defaults.object(forKey: DefaultsKey.y) != nil {
            return NSPoint(x: defaults.double(forKey: DefaultsKey.x), y: defaults.double(forKey: DefaultsKey.y))
        }
        let visibleFrame = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: visibleFrame.maxX - size - 24, y: visibleFrame.minY + 24)
    }

    private func savePosition() {
        guard let panel else { return }
        UserDefaults.standard.set(panel.frame.origin.x, forKey: DefaultsKey.x)
        UserDefaults.standard.set(panel.frame.origin.y, forKey: DefaultsKey.y)
    }
}
