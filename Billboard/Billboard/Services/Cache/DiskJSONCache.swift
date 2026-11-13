import Foundation

enum DiskJSONCache {
    nonisolated private static var directoryName: String { "BillboardJSONCache" }

    nonisolated static func data(forKey key: String) -> Data? {
        if let data = readData(forKey: key) {
            return data
        }

        // Migrate large cached blobs out of UserDefaults the first time we touch them.
        let defaults = UserDefaults.standard
        guard let legacyData = defaults.data(forKey: key) else { return nil }
        store(legacyData, forKey: key)
        defaults.removeObject(forKey: key)
        return legacyData
    }

    /// Writes `data` atomically. Returns false when it could not be written (the previous file, if
    /// any, is left as it was).
    @discardableResult
    nonisolated static func store(_ data: Data, forKey key: String) -> Bool {
        guard let fileURL = fileURL(forKey: key) else { return false }
        do {
            try ensureDirectoryExists(at: fileURL.deletingLastPathComponent())
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            #if DEBUG
            print("[DiskJSONCache] Failed to write \(key): \(error.localizedDescription)")
            #endif
            return false
        }
    }

    nonisolated static func removeData(forKey key: String) {
        UserDefaults.standard.removeObject(forKey: key)
        guard let fileURL = fileURL(forKey: key) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The size of the file stored for `key`, or nil when there is none (never written, removed, or
    /// purged with the rest of Caches). Reads the file's attributes, not its contents.
    nonisolated static func byteCount(forKey key: String) -> Int? {
        guard let fileURL = fileURL(forKey: key),
              let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return nil
        }
        return values.fileSize
    }

    nonisolated private static func readData(forKey key: String) -> Data? {
        guard let fileURL = fileURL(forKey: key) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    nonisolated private static func fileURL(forKey key: String) -> URL? {
        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        return cachesDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(safeFileName(for: key))
            .appendingPathExtension("json")
    }

    nonisolated private static func ensureDirectoryExists(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }

    nonisolated private static func safeFileName(for key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let characters = key.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(characters)
        return sanitized.isEmpty ? "cache" : sanitized
    }
}
