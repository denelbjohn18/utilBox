import Foundation

struct PinChange: Equatable {
    var pinned: Bool
    var evicted: [ClipItem]
}

struct History {
    private(set) var items: [ClipItem]

    init(items: [ClipItem] = []) {
        self.items = items.filter(\.isDisplayable)
        capPins()
        _ = evict()
    }

    func match(_ clip: CapturedClip, imageSHA: String?) -> ClipItem? {
        items.first { item in
            switch (item.kind, clip.payload) {
            case let (.text(body), .text(string, _, _)):
                return body.string == string
            case let (.image(body), .image(_, _, _)):
                return imageSHA != nil && body.sha256 == imageSHA
            case let (.files(body), .files(paths)):
                return body.paths == paths
            default:
                return false
            }
        }
    }

    mutating func insert(_ item: ClipItem) -> [ClipItem] {
        guard item.isDisplayable else { return [] }
        insertInSection(item)
        return evict()
    }

    mutating func promote(_ id: UUID, sourceApp: String?, now: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.createdAt = now
        if let sourceApp {
            item.sourceApp = sourceApp
        }
        insertInSection(item)
    }

    mutating func togglePin(_ id: UUID) -> PinChange? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        if !items[index].pinned && pinnedCount >= Limits.maxPinned {
            return nil
        }
        var item = items.remove(at: index)
        item.pinned.toggle()
        insertInSection(item)
        let evicted = item.pinned ? [] : evict()
        return PinChange(pinned: item.pinned, evicted: evicted)
    }

    mutating func delete(_ id: UUID) -> ClipItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    mutating func clearUnpinned() -> [ClipItem] {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        return removed
    }

    func filtered(query: String) -> [ClipItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.matchesSearch(needle) }
    }

    private var pinnedCount: Int {
        items.reduce(into: 0) { count, item in
            if item.pinned { count += 1 }
        }
    }

    private mutating func insertInSection(_ item: ClipItem) {
        if item.pinned {
            items.insert(item, at: 0)
        } else {
            let index = items.firstIndex(where: { !$0.pinned }) ?? items.endIndex
            items.insert(item, at: index)
        }
    }

    private mutating func capPins() {
        var kept = 0
        for index in items.indices where items[index].pinned {
            kept += 1
            if kept > Limits.maxPinned {
                items[index].pinned = false
            }
        }
        let pins = items.filter(\.pinned)
        let rest = items.filter { !$0.pinned }
        items = pins + rest
    }

    private mutating func evict() -> [ClipItem] {
        let unpinnedIndexes = items.indices.filter { !items[$0].pinned }
        let overflow = unpinnedIndexes.count - Limits.maxUnpinned
        guard overflow > 0 else { return [] }
        let doomedIDs = Set(unpinnedIndexes.suffix(overflow).map { items[$0].id })
        let doomed = items.filter { doomedIDs.contains($0.id) }
        items.removeAll { doomedIDs.contains($0.id) }
        return doomed
    }
}
