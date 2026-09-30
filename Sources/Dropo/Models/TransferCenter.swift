import AppKit
import DropoCore
import Observation

@MainActor @Observable
final class Transfer: Identifiable {
    enum Direction { case toMac, toPhone }
    enum State: Equatable { case running, finished, failed(String), cancelled }

    let id = UUID()
    let title: String
    let direction: Direction
    var done: UInt64 = 0
    var total: UInt64 = 0
    var state: State = .running
    var results: [URL] = []
    let startedAt = Date()
    @ObservationIgnored var progress: BatchProgress!

    init(title: String, direction: Direction) {
        self.title = title
        self.direction = direction
    }

    var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }
    var isRunning: Bool { state == .running }

    var detail: String {
        switch state {
        case .running:
            guard total > 0 else { return "Preparing…" }
            let bytes = ByteCountFormatter.string(fromByteCount: Int64(done), countStyle: .file)
            let totalBytes = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
            let elapsed = Date().timeIntervalSince(startedAt)
            guard elapsed > 2, done > 0 else { return "\(bytes) of \(totalBytes)" }
            let remaining = elapsed / Double(done) * Double(total - done)
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = 1
            return "\(bytes) of \(totalBytes) — about \(formatter.string(from: remaining) ?? "a moment") left"
        case .finished: return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        case .failed(let message): return message
        case .cancelled: return "Stopped"
        }
    }

    func cancel() { progress.cancel() }
}

@MainActor @Observable
final class TransferCenter {
    private(set) var transfers: [Transfer] = []

    var active: [Transfer] { transfers.filter(\.isRunning) }

    var overallFraction: Double? {
        let running = active
        let total = running.reduce(UInt64(0)) { $0 + $1.total }
        guard total > 0 else { return nil }
        return Double(running.reduce(UInt64(0)) { $0 + $1.done }) / Double(total)
    }

    func clearFinished() {
        transfers.removeAll { !$0.isRunning }
    }

    /// Runs `work` as a visible transfer. Progress callbacks arrive on libmtp's thread and are throttled to ~10 Hz.
    @discardableResult
    func run<T>(_ title: String, direction: Transfer.Direction, work: (BatchProgress) async throws -> T) async throws -> T {
        let transfer = Transfer(title: title, direction: direction)
        let throttle = Throttle()
        transfer.progress = BatchProgress { done, total in
            guard throttle.shouldFire(force: done == total) else { return }
            Task { @MainActor in
                transfer.done = done
                transfer.total = total
            }
        }
        transfers.insert(transfer, at: 0)
        do {
            let result = try await work(transfer.progress)
            transfer.done = transfer.total
            transfer.state = .finished
            if let urls = result as? [URL] { transfer.results = urls }
            return result
        } catch DropoError.cancelled {
            transfer.state = .cancelled
            throw DropoError.cancelled
        } catch {
            transfer.state = .failed(error.localizedDescription)
            throw error
        }
    }
}

private final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldFire(force: Bool) -> Bool {
        lock.withLock {
            let now = Date()
            guard force || now.timeIntervalSince(last) > 0.1 else { return false }
            last = now
            return true
        }
    }
}
