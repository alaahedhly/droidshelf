import Foundation
import IOKit
import IOKit.usb

/// Calls `onChange` (on the main run loop) whenever any USB device is attached or detached.
public final class USBWatcher {
    private let onChange: () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)

        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching("IOUSBHostDevice"),
                { context, iterator in
                    guard let context else { return }
                    USBWatcher.drain(iterator)
                    Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue().onChange()
                },
                context, &iterator
            )
            guard result == KERN_SUCCESS else { continue }
            // Arms the notification; the devices already present are handled by the initial scan.
            Self.drain(iterator)
            iterators.append(iterator)
        }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        port.map(IONotificationPortDestroy)
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}
