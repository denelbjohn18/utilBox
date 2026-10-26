import Foundation

struct ScratchFrame: Equatable, Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct ScratchSession: Equatable, Codable {
    var isOpen: Bool
    var isPill: Bool
    var sidebarHidden: Bool
    var window: ScratchFrame?
    var pill: ScratchFrame?

    static let closed = ScratchSession(
        isOpen: false,
        isPill: false,
        sidebarHidden: false,
        window: nil,
        pill: nil
    )
}

struct ScratchNote: Equatable, Identifiable, Codable {
    var id: UUID
    var body: String
    var createdAt: Date
    var updatedAt: Date

    var title: String { ScratchTitle.from(body) }

    var isBlank: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ScratchTitle {
    static let placeholder = "Untitled"
    static let limit = 80

    static func from(_ body: String) -> String {
        for line in body.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.count <= limit { return String(trimmed) }
            let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
            return String(trimmed[..<end])
        }
        return placeholder
    }
}

private struct ScratchDisk: Codable {
    var version: Int
    var selectedID: UUID?
    var notes: [ScratchNote]
    var session: ScratchSession
}

final class ScratchStore {
    static let maxNotes = 200
    static let maxBodyCharacters = 200_000

    private let file: URL
    private(set) var notes: [ScratchNote] = []
    private(set) var selectedID: UUID?
    private(set) var session: ScratchSession = .closed

    init(directory: URL) throws {
        file = directory.appendingPathComponent("notes.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        load()
    }

    static func live() throws -> ScratchStore {
        try ScratchStore(directory: AppPaths.supportDirectory())
    }

    func note(_ id: UUID) -> ScratchNote? {
        notes.first { $0.id == id }
    }

    func selected() -> ScratchNote? {
        guard let selectedID else { return nil }
        return note(selectedID)
    }

    func filtered(query: String) -> [ScratchNote] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return notes }
        return notes.filter { note in
            note.title.localizedCaseInsensitiveContains(needle)
                || note.body.localizedCaseInsensitiveContains(needle)
        }
    }

    @discardableResult
    func create(now: Date = Date()) -> ScratchNote? {
        guard notes.count < Self.maxNotes else { return nil }
        let note = ScratchNote(id: UUID(), body: "", createdAt: now, updatedAt: now)
        notes.insert(note, at: 0)
        selectedID = note.id
        persist()
        return note
    }

    @discardableResult
    func updateBody(_ id: UUID, _ body: String, now: Date = Date()) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        if body.count > Self.maxBodyCharacters { return false }
        if notes[index].body == body { return true }
        notes[index].body = body
        notes[index].updatedAt = now
        persist()
        return true
    }

    func delete(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.remove(at: index)
        if selectedID == id {
            if notes.indices.contains(index) {
                selectedID = notes[index].id
            } else {
                selectedID = notes.last?.id
            }
        }
        persist()
    }

    func select(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        if selectedID == id { return }
        selectedID = id
        persist()
    }

    func setSession(_ session: ScratchSession) {
        self.session = session
        persist()
    }

    func flush() {
        persist()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let disk = try decoder.decode(ScratchDisk.self, from: data)
            guard disk.version == 1 else { throw StoreError.unsupportedVersion }
            var loaded = Array(disk.notes.prefix(Self.maxNotes))
            var trimmed = loaded.count != disk.notes.count
            for index in loaded.indices where loaded[index].body.count > Self.maxBodyCharacters {
                let end = loaded[index].body.index(
                    loaded[index].body.startIndex,
                    offsetBy: Self.maxBodyCharacters
                )
                loaded[index].body = String(loaded[index].body[..<end])
                trimmed = true
            }
            notes = loaded
            if let selected = disk.selectedID, loaded.contains(where: { $0.id == selected }) {
                selectedID = selected
            } else {
                selectedID = loaded.first?.id
            }
            if selectedID != disk.selectedID { trimmed = true }
            session = disk.session
            if trimmed { persist() }
        } catch {
            let broken = file.deletingLastPathComponent().appendingPathComponent("notes.broken.json")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: file, to: broken)
            notes = []
            selectedID = nil
            session = .closed
            Log.error("utilBox started a fresh scratchpad because the saved notes could not be read.")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            let disk = ScratchDisk(version: 1, selectedID: selectedID, notes: notes, session: session)
            let data = try encoder.encode(disk)
            try data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            Log.error("utilBox could not save notes.")
        }
    }
}
