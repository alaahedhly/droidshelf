import Foundation

public enum Naming {
    /// Finder's "Keep Both" naming: `photo.jpg` → `photo 2.jpg`, `photo 2.jpg` → `photo 3.jpg`.
    public static func unique(_ name: String, avoiding existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }

        let ext = (name as NSString).pathExtension
        var base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var counter = 2
        if let match = base.firstMatch(of: /^(.*) (\d+)$/), let number = Int(match.2) {
            base = String(match.1)
            counter = number + 1
        }
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }

    /// Names Android's MTP server rejects, or that would collide with path separators on either side.
    public static func validationError(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "The name can't be empty." }
        if trimmed == "." || trimmed == ".." { return "That name is reserved." }
        if name.contains("/") || name.contains("\0") { return "Names can't contain “/”." }
        if name.utf8.count > 255 { return "That name is too long." }
        return nil
    }
}
