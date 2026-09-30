import DropoCore
import SwiftUI

enum SidebarItem: Hashable {
    case storage(deviceID: String, storageID: UInt32)
    case favorite(UUID)
}

struct SidebarView: View {
    let app: AppModel
    let browser: BrowserModel

    var body: some View {
        List(selection: selection) {
            let favorites = app.devices.flatMap { app.favorites(for: $0) }
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { favorite in
                        Label(favorite.name, systemImage: "folder")
                            .tag(SidebarItem.favorite(favorite.id))
                            .contextMenu {
                                Button("Remove from Sidebar") { app.removeFavorite(favorite) }
                            }
                    }
                }
            }

            Section("Locations") {
                ForEach(app.devices) { device in
                    ForEach(Array(device.storages.enumerated()), id: \.element.id) { index, storage in
                        StorageRow(app: app, device: device, storage: storage, isPrimary: index == 0)
                            .tag(SidebarItem.storage(deviceID: device.id, storageID: storage.id))
                    }
                }
                if app.isConnecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Connecting…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<SidebarItem?> {
        Binding {
            guard let location = browser.location else { return nil }
            if location.path.isEmpty {
                return .storage(deviceID: location.deviceID, storageID: location.storageID)
            }
            let names = location.path.map(\.name)
            let serial = browser.device?.info.serial
            return app.favorites
                .first { $0.deviceSerial == serial && $0.storageID == location.storageID && $0.path == names }
                .map { .favorite($0.id) }
        } set: { item in
            switch item {
            case .storage(let deviceID, let storageID):
                guard let device = app.device(deviceID), let storage = device.storage(storageID) else { return }
                browser.openStorage(storage, on: device)
            case .favorite(let id):
                guard let favorite = app.favorites.first(where: { $0.id == id }) else { return }
                browser.openFavorite(favorite)
            case nil:
                break
            }
        }
    }
}

/// A phone with one storage reads as just the phone; extra storages (SD cards) get their own rows.
private struct StorageRow: View {
    let app: AppModel
    let device: ConnectedDevice
    let storage: Storage
    let isPrimary: Bool

    var body: some View {
        HStack {
            Label {
                Text(isPrimary ? device.info.displayName : storage.name).lineLimit(1)
            } icon: {
                Image(systemName: isPrimary ? "smartphone" : "sdcard")
            }
            Spacer()
            if isPrimary {
                Button {
                    app.eject(device)
                } label: {
                    Image(systemName: "eject.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Disconnect \(device.info.displayName)")
            }
        }
        .padding(.leading, isPrimary ? 0 : 14)
        .help(helpText)
    }

    private var helpText: String {
        var parts = ["\(storage.name): \(ByteCountFormatter.string(fromByteCount: Int64(storage.freeSpace), countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: Int64(storage.capacity), countStyle: .file))"]
        if let battery = device.info.batteryPercent { parts.append("Battery \(battery)%") }
        return parts.joined(separator: " — ")
    }
}
