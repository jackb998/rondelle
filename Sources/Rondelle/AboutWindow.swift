import AppKit
import SwiftUI

/// «Informazioni su Rondelle» from the menu bar icon: a small window with the icon, the version and the build.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: AboutView())
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.rondelleStyle()
            window.title = L("Informazioni su Rondelle")
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AboutView: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        VStack(spacing: 6) {
            AppIconImage()
                .frame(width: 72, height: 72)
                .padding(.bottom, 4)
            Text(L("Rondelle")).font(.title3.weight(.semibold))
            Text(L("Versione %@", info["CFBundleShortVersionString"] as? String ?? "—"))
                .font(.callout)
            Text(L("Build %@", info["CFBundleVersion"] as? String ?? "—"))
                .font(.caption).foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.open(Website.url)
            } label: {
                Label(L("Sito web di Rondelle"), systemImage: "safari")
            }
            .rondelleButton()
            .padding(.top, 8)
            if let copyright = info["NSHumanReadableCopyright"] as? String {
                Text(copyright).font(.caption2).foregroundStyle(.tertiary).padding(.top, 6)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 44)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(minWidth: 240)
    }
}
