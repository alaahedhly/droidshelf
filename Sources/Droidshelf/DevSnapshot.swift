import AppKit
import SwiftUI

/// Dev tooling: `DROIDSHELF_SNAPSHOT=/path/shot.png [DROIDSHELF_OPEN=DCIM/Camera] [DROIDSHELF_SELECT=name] [DROIDSHELF_CLICKS="x,y;x,y"] [DROIDSHELF_APPEARANCE=light|dark]
/// Droidshelf --demo <folder>` renders the first window to a PNG, prints the final selection, and quits. Lets UI be checked
/// from a shell without Screen Recording permission. Synthetic clicks reach SwiftUI gestures on content and table rows,
/// but not text inside table cells or empty space.
@MainActor
enum DevSnapshot {
    static func runIfRequested(browser: BrowserModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["DROIDSHELF_SNAPSHOT"] else { return }
        if let appearance = environment["DROIDSHELF_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if let path = environment["DROIDSHELF_OPEN"], let device = browser.app.devices.first, let storage = device.storages.first {
                browser.openFavorite(Favorite(deviceSerial: device.info.serial, storageID: storage.id, path: path.split(separator: "/").map(String.init)))
            }
            if let select = environment["DROIDSHELF_SELECT"] {
                try? await Task.sleep(for: .seconds(1))
                browser.selection = Set(browser.visibleItems.filter { $0.name == select }.map(\.id))
            }
            try? await Task.sleep(for: .seconds(1.5))
            // DROIDSHELF_CLICKS="x,y;x,y" — top-left window points, clicked in order.
            for click in (environment["DROIDSHELF_CLICKS"] ?? "").split(separator: ";") {
                let parts = click.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2, let window = NSApp.windows.first(where: \.isVisible) else { continue }
                let point = NSPoint(x: parts[0], y: window.frame.height - parts[1])
                func event(_ type: NSEvent.EventType) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                // Queue the mouse-up like a real click, so AppKit's drag-tracking loop (which reads the queue) receives it.
                if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
                if let down = event(.leftMouseDown) { window.sendEvent(down) }
                try? await Task.sleep(for: .seconds(0.8))
            }
            try? await Task.sleep(for: .seconds(1.5))
            FileHandle.standardError.write(Data("FINAL title=\(browser.title) selection: \(browser.selectedItems.map(\.name))\n".utf8))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView?.superview else { return }
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
            NSApp.terminate(nil)
        }
    }
}
