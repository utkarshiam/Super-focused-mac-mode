import Foundation

extension MemoryBrain {
    /// Tasks don't belong in memory: forgets every item auto-captured from a task (a `task:` ref). Returns how
    /// many went.
    @discardableResult
    public func forgetTaskMemories() -> Int {
        let ids = Set(library.items.filter { $0.sourceRef?.hasPrefix("task:") == true }.map(\.id))
        forget(ids)
        return ids.count
    }

    /// Removes items from the library and tidies what they leave behind, at once rather than on the next refresh:
    /// their memberships go, people, organisations and projects only they mentioned go, and so do topics (then
    /// areas) that had items and now have none, unless the user made or locked them. Connections through them go
    /// too. Used for the one-time clean-up that took auto-captured tasks out of memory.
    public func forget(_ ids: Set<UUID>) {
        let present = ids.filter { library.item($0) != nil }
        guard !present.isEmpty else { return }
        // Topics whose every item is going, and the areas above them.
        let emptied = Set(state.entities.filter { e in
            let members = state.taxonomy.members(of: e.id)
            return e.kind == .topic && !e.locks.any && !members.isEmpty && members.allSatisfy(present.contains)
        }.map(\.id))
        let parents = Set(state.entities.filter { emptied.contains($0.id) }.compactMap(\.parentID))

        library.remove(present)
        refresh()

        var gone = Set<UUID>()
        for id in emptied {
            guard let e = entity(id), e.itemCount == 0, children(of: id).isEmpty else { continue }
            gone.insert(id)
        }
        // An area (or parent topic) left with nothing under it and nothing of its own.
        for id in parents {
            guard let e = entity(id), !e.locks.any, e.itemCount == 0,
                  children(of: id).allSatisfy({ gone.contains($0.id) }), state.taxonomy.members(of: id).isEmpty else { continue }
            gone.insert(id)
        }
        let connections = state.connections.filter { !present.contains($0.a) && !present.contains($0.b) }
        guard !gone.isEmpty || connections.count != state.connections.count else { return }
        state.entities.removeAll { gone.contains($0.id) }
        for id in gone { state.taxonomy.members[id.uuidString] = nil }
        state.connections = connections
        reindex()
    }
}
