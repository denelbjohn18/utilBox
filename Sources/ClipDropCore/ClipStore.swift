import Foundation

enum IngestEffect: Equatable {
    case ignored
    case inserted(UUID)
    case promoted(UUID)
}

enum StoreError: Error {
    case unreadable
    case unsupportedVersion
}

enum AppPaths {
    static func supportDirectory() -> URL {
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("utilBox-fallback", isDirectory: true)
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fallback
        }
        let preferred = base.appendingPathComponent("utilBox", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)
            return preferred
        } catch {
            return fallback
        }
    }
}

private struct DiskFile: Codable {
    var version: Int
    var items: [ClipItem]
}

final class ClipStore {
    private let directory: URL
    private let blobs: URL
    private let file: URL
    private var history: History
    var onChange: (() -> Void)?

    var items: [ClipItem] { history.items }

    init(directory: URL) throws {
        self.directory = directory
        blobs = directory.appendingPathComponent("blobs", isDirectory: true)
        file = directory.appendingPathComponent("history.json")
        history = History()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blobs.path)
        load()
    }

    static func live() throws -> ClipStore {
        try ClipStore(directory: AppPaths.supportDirectory())
    }

    func filtered(query: String) -> [ClipItem] {
        history.filtered(query: query)
    }

    func item(_ id: UUID) -> ClipItem? {
        history.items.first { $0.id == id }
    }

    func ingest(_ clip: CapturedClip, armedID: UUID?, now: Date = Date()) -> IngestEffect {
        let digest = imageSHA(of: clip)
        if let existing = history.match(clip, imageSHA: digest) {
            if existing.id == armedID {
                return .ignored
            }
            history.promote(existing.id, sourceApp: clip.sourceApp, now: now)
            commit()
            return .promoted(existing.id)
        }

        let id = UUID()
        do {
            let item = try makeItem(clip, id: id, sha: digest, now: now)
            let evicted = history.insert(item)
            for old in evicted {
                deleteBlobs(of: old)
            }
            commit()
            return .inserted(id)
        } catch {
            Log.error("utilBox could not store a clip.")
            return .ignored
        }
    }

    @discardableResult
    func togglePin(_ id: UUID) -> Bool {
        guard let change = history.togglePin(id) else { return false }
        for item in change.evicted {
            deleteBlobs(of: item)
        }
        commit()
        return true
    }

    func delete(_ id: UUID) {
        guard let item = history.delete(id) else { return }
        deleteBlobs(of: item)
        commit()
    }

    func clearUnpinned() {
        let removed = history.clearUnpinned()
        for item in removed {
            deleteBlobs(of: item)
        }
        commit()
    }

    func blob(_ name: String) -> Data? {
        guard isSafeBlobName(name) else { return nil }
        return try? Data(contentsOf: blobs.appendingPathComponent(name))
    }

    func flush() {
        persist()
    }

    private func imageSHA(of clip: CapturedClip) -> String? {
        guard case .image(let png, _, _) = clip.payload else { return nil }
        return SHA256.hex(png)
    }

    private func makeItem(_ clip: CapturedClip, id: UUID, sha: String?, now: Date) throws -> ClipItem {
        var written: [String] = []
        do {
            let kind = try materialize(clip, id: id, sha: sha, written: &written)
            return ClipItem(
                id: id,
                createdAt: now,
                pinned: false,
                sourceApp: clip.sourceApp,
                kind: kind
            )
        } catch {
            for name in written where isSafeBlobName(name) {
                try? FileManager.default.removeItem(at: blobs.appendingPathComponent(name))
            }
            throw error
        }
    }

    private func materialize(
        _ clip: CapturedClip,
        id: UUID,
        sha: String?,
        written: inout [String]
    ) throws -> ClipKind {
        switch clip.payload {
        case .text(let string, let rtf, let html):
            var rtfName: String?
            var htmlName: String?
            if let rtf, !rtf.isEmpty {
                let name = "\(id.uuidString).rtf"
                try writeBlob(rtf, name: name)
                written.append(name)
                rtfName = name
            }
            if let html, !html.isEmpty {
                let name = "\(id.uuidString).html"
                try writeBlob(html, name: name)
                written.append(name)
                htmlName = name
            }
            return .text(TextBody(string: string, rtfFile: rtfName, htmlFile: htmlName))
        case .image(let png, let width, let height):
            let name = "\(id.uuidString).png"
            try writeBlob(png, name: name)
            written.append(name)
            return .image(ImageBody(
                file: name,
                width: width,
                height: height,
                sha256: sha ?? SHA256.hex(png)
            ))
        case .files(let paths):
            return .files(FileBody(paths: paths))
        }
    }

    private func writeBlob(_ data: Data, name: String) throws {
        guard isSafeBlobName(name) else { throw StoreError.unreadable }
        let url = blobs.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func deleteBlobs(of item: ClipItem) {
        for name in item.blobNames where isSafeBlobName(name) {
            try? FileManager.default.removeItem(at: blobs.appendingPathComponent(name))
        }
    }

    private func isSafeBlobName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.contains("..")
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let disk = try decoder.decode(DiskFile.self, from: data)
            guard disk.version == 1 else { throw StoreError.unsupportedVersion }
            history = History(items: disk.items)
            if history.items != disk.items {
                persist()
            }
            cleanupOrphans()
        } catch {
            let broken = directory.appendingPathComponent("history.broken.json")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: file, to: broken)
            history = History()
            Log.error("utilBox started a new history because the saved one could not be read.")
        }
    }

    private func cleanupOrphans() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: nil
        ) else { return }
        let referenced = Set(history.items.flatMap(\.blobNames))
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func commit() {
        persist()
        onChange?()
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(DiskFile(version: 1, items: history.items))
            try data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            Log.error("utilBox could not save history.")
        }
    }
}
