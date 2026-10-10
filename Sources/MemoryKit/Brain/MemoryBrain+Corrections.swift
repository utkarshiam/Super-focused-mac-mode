import Foundation

/// The user's corrections. Each one is remembered in brain.json (`BrainCorrections` and entity locks), so
/// later resolution and reorganising never undo it, and each is logged in the change log.
extension MemoryBrain {
    // MARK: Names

    /// Renames an entity and locks the name. The old name stays as an alias (so it still finds it), and for
    /// people, organisations and projects the new spelling is tied to this entity.
    public func rename(_ id: UUID, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let e = entity(id), e.name != name else { return }
        let old = e.name
        updateEntity(id) { x in
            if !x.aliases.contains(where: { TextFold.fold($0) == TextFold.fold(old) }) { x.aliases.append(old) }
            x.aliases.removeAll { TextFold.fold($0) == TextFold.fold(name) }
            x.aliases.insert(name, at: 0)
            x.name = name
            x.locks.name = true
            x.provisionalName = false
            x.updatedAt = now()
        }
        if e.kind.isExtracted {
            state.corrections.forced[EntityNames.scopedKey(name, kind: e.kind)] = .init(entityID: id, spelling: name)
        }
        logCorrection("Renamed \(old) to \(name)", [id])
        reindex(resolve: e.kind.isExtracted)
    }

    /// Adds a spelling to an entity ("Rohan ji" is Rohan Mehta). Returns false across kinds or for blank text.
    @discardableResult
    public func addAlias(_ alias: String, to id: UUID) -> Bool {
        let spelling = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spelling.isEmpty, let e = entity(id) else { return false }
        if e.kind.isExtracted {
            let key = EntityNames.scopedKey(spelling, kind: e.kind)
            state.corrections.forced[key] = .init(entityID: id, spelling: spelling)
            state.corrections.distinct.removeAll { $0.contains(key) }
        }
        updateEntity(id) { x in
            if !x.aliases.contains(where: { TextFold.fold($0) == TextFold.fold(spelling) }) { x.aliases.append(spelling) }
        }
        logCorrection("Added \(spelling) as another name for \(e.name)", [id])
        reindex(resolve: e.kind.isExtracted)
        return true
    }

    /// Merges `sourceID` into `targetID` (same kind only; returns false otherwise). People, organisations and
    /// projects: every spelling of the source now resolves to the target, for good. Topics and areas: items,
    /// sub-topics and aliases move to the target and the source goes away. The target keeps its page (the
    /// source's own facts are added); it is rewritten at the next synthesis.
    @discardableResult
    public func merge(_ sourceID: UUID, into targetID: UUID) -> Bool {
        guard sourceID != targetID, let source = entity(sourceID), let target = entity(targetID), source.kind == target.kind else { return false }
        let targetKeys = target.aliases.map { EntityNames.scopedKey($0, kind: target.kind) }
        if source.kind.isExtracted {
            for alias in source.aliases {
                let key = EntityNames.scopedKey(alias, kind: source.kind)
                state.corrections.forced[key] = .init(entityID: targetID, spelling: alias)
                for t in targetKeys {
                    let pk = EntityResolver.pairKey(key, t)
                    state.corrections.distinct.removeAll { $0 == pk }
                    state.corrections.decisions[pk] = nil
                }
            }
        } else {
            var t = state.taxonomy
            for item in t.members(of: sourceID) where !t.members(of: targetID).contains(item) {
                t.members[targetID.uuidString, default: []].append(item)
            }
            t.members[sourceID.uuidString] = nil
            for (item, topic) in t.primary where topic == sourceID { t.primary[item] = targetID }
            state.taxonomy = t
            for (item, topic) in state.corrections.primary where topic == sourceID { state.corrections.primary[item] = targetID }
            for (item, ids) in state.corrections.added { state.corrections.added[item] = ids.map { $0 == sourceID ? targetID : $0 } }
            for (item, ids) in state.corrections.excluded { state.corrections.excluded[item] = ids.filter { $0 != sourceID } }
            for i in state.entities.indices where state.entities[i].parentID == sourceID {
                // A sub-topic can't go under a sub-topic: it goes to the target's parent then.
                let targetIsSub = target.parentID.flatMap(entity)?.kind == .topic
                state.entities[i].parentID = targetIsSub ? target.parentID : targetID
            }
        }
        updateEntity(targetID) { x in
            for alias in source.aliases where !x.aliases.contains(where: { TextFold.fold($0) == TextFold.fold(alias) }) { x.aliases.append(alias) }
            x.keyFacts += source.keyFacts.filter(\.isKept)
            x.updatedAt = now()
        }
        if !source.kind.isExtracted { state.entities.removeAll { $0.id == sourceID } }
        logCorrection("Merged \(source.name) into \(target.name)", [targetID])
        reindex(resolve: source.kind.isExtracted)
        return true
    }

    /// Takes a spelling out of an entity. For people, organisations and projects the spelling becomes its own
    /// entity (returned) and the two are never merged again; for topics and areas the alias is just removed
    /// (returns nil).
    @discardableResult
    public func unmerge(alias: String, from id: UUID) -> UUID? {
        guard let e = entity(id) else { return nil }
        let fold = TextFold.fold(alias)
        guard TextFold.fold(e.name) != fold || e.aliases.count > 1 else { return nil }
        guard e.kind.isExtracted else {
            updateEntity(id) { $0.aliases.removeAll { TextFold.fold($0) == fold } }
            logCorrection("Removed \(alias) from \(e.name)", [id])
            reindex()
            return nil
        }
        let key = EntityNames.scopedKey(alias, kind: e.kind)
        let newID = UUID()
        state.corrections.forced[key] = .init(entityID: newID, spelling: alias)
        var pairs: [String] = []
        for other in e.aliases where TextFold.fold(other) != fold {
            let k = EntityNames.scopedKey(other, kind: e.kind)
            if k != key { pairs.append(EntityResolver.pairKey(key, k)) }
        }
        state.corrections.addDistinct(pairs)
        // If the alias was the name, the entity takes its next spelling.
        if TextFold.fold(e.name) == fold, let next = e.aliases.first(where: { TextFold.fold($0) != fold }) {
            updateEntity(id) { $0.name = next; $0.locks.name = false }
        }
        updateEntity(id) { $0.aliases.removeAll { TextFold.fold($0) == fold } }
        logCorrection("Split \(alias) from \(e.name)", [id, newID])
        reindex(resolve: true)
        return entity(newID) != nil ? newID : nil
    }

    /// Two entities are different things: resolution and AI will never merge them.
    public func markDistinct(_ a: UUID, _ b: UUID) {
        guard let x = entity(a), let y = entity(b), x.kind == y.kind, x.kind.isExtracted else { return }
        var pairs: [String] = []
        for p in x.aliases { for q in y.aliases {
            let kp = EntityNames.scopedKey(p, kind: x.kind), kq = EntityNames.scopedKey(q, kind: y.kind)
            if kp != kq { pairs.append(EntityResolver.pairKey(kp, kq)) }
        } }
        state.corrections.addDistinct(pairs)
        pendingCandidatesRemoveAll { c in pairs.contains(c.pairKey) }
        logCorrection("\(x.name) and \(y.name) are different", [a, b])
        reindex()
    }

    // MARK: Taxonomy

    /// Moves a topic under an area, under a top-level topic (as a sub-topic; only when it has none of its own),
    /// or to the top level (nil). Locks its parent. Returns false when the move isn't allowed.
    @discardableResult
    public func move(_ topicID: UUID, to parentID: UUID?) -> Bool {
        guard let topic = entity(topicID), topic.kind == .topic else { return false }
        if let parentID {
            guard parentID != topicID, let parent = entity(parentID), parent.kind.isTaxonomy else { return false }
            if parent.kind == .topic {
                // Max depth 3: the parent must be top-level and the topic must not have sub-topics.
                guard parent.parentID.flatMap(entity)?.kind != .topic, children(of: topicID).isEmpty else { return false }
            }
        }
        updateEntity(topicID) { $0.parentID = parentID; $0.locks.parent = true; $0.updatedAt = now() }
        let target = parentID.flatMap(entity)?.name ?? "the top level"
        logCorrection("Moved \(topic.name) to \(target)", [topicID])
        reindex()
        return true
    }

    /// Makes `topicID` the item's primary topic (adding it to the topic if needed).
    public func setPrimaryTopic(_ topicID: UUID, for itemID: UUID) {
        guard entity(topicID)?.kind == .topic, library.item(itemID) != nil else { return }
        let key = itemID.uuidString
        if !state.taxonomy.members(of: topicID).contains(itemID) {
            state.taxonomy.members[topicID.uuidString, default: []].append(itemID)
            state.corrections.added[key, default: []].append(topicID)
        }
        state.corrections.excluded[key]?.removeAll { $0 == topicID }
        state.taxonomy.primary[key] = topicID
        state.corrections.primary[key] = topicID
        state.taxonomy.unsorted.removeAll { $0 == itemID }
        logCorrection("Filed \(library.item(itemID)?.displayTitle ?? "an item") under \(entity(topicID)?.name ?? "a topic")", [topicID])
        reindex()
    }

    /// Adds an item to a topic (not as primary unless it had none).
    public func addItem(_ itemID: UUID, toTopic topicID: UUID) {
        guard entity(topicID)?.kind == .topic, library.item(itemID) != nil else { return }
        let key = itemID.uuidString
        guard !state.taxonomy.members(of: topicID).contains(itemID) else { return }
        state.taxonomy.members[topicID.uuidString, default: []].append(itemID)
        state.corrections.added[key, default: []].append(topicID)
        state.corrections.excluded[key]?.removeAll { $0 == topicID }
        if state.taxonomy.primary[key] == nil { state.taxonomy.primary[key] = topicID }
        state.taxonomy.unsorted.removeAll { $0 == itemID }
        logCorrection("Added \(library.item(itemID)?.displayTitle ?? "an item") to \(entity(topicID)?.name ?? "a topic")", [topicID])
        reindex()
    }

    /// Takes an item out of a topic for good (reorganising never puts it back there). With no other topic
    /// left it goes to Unsorted.
    public func removeItem(_ itemID: UUID, fromTopic topicID: UUID) {
        let key = itemID.uuidString
        guard state.taxonomy.members(of: topicID).contains(itemID) else { return }
        state.taxonomy.members[topicID.uuidString]?.removeAll { $0 == itemID }
        if state.taxonomy.members[topicID.uuidString]?.isEmpty == true { state.taxonomy.members[topicID.uuidString] = nil }
        if !(state.corrections.excluded[key]?.contains(topicID) ?? false) { state.corrections.excluded[key, default: []].append(topicID) }
        state.corrections.added[key]?.removeAll { $0 == topicID }
        if state.corrections.primary[key] == topicID { state.corrections.primary[key] = nil }
        if state.taxonomy.primary[key] == topicID {
            let other = state.taxonomy.members.sorted { $0.key < $1.key }.first { $0.value.contains(itemID) }.flatMap { UUID(uuidString: $0.key) }
            state.taxonomy.primary[key] = other
            if other == nil, !state.taxonomy.unsorted.contains(itemID) { state.taxonomy.unsorted.append(itemID) }
        }
        logCorrection("Took \(library.item(itemID)?.displayTitle ?? "an item") out of \(entity(topicID)?.name ?? "a topic")", [topicID])
        reindex()
    }

    /// Sets what's locked on an entity.
    public func setLocks(_ locks: EntityLocks, for id: UUID) {
        guard entity(id) != nil else { return }
        updateEntity(id) { $0.locks = locks }
        reindex()
    }

    /// A topic the user makes (name locked). Returns its id.
    @discardableResult
    public func createTopic(named name: String, in parentID: UUID? = nil) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parentID, entity(parentID)?.kind.isTaxonomy != true { return nil }
        let e = BrainEntity(kind: .topic, name: trimmed, parentID: parentID, createdAt: now(),
                            locks: EntityLocks(name: true, parent: parentID != nil, membership: false))
        state.entities.append(e)
        logCorrection("New topic \(trimmed)", [e.id])
        reindex()
        return e.id
    }

    /// An area the user makes (name locked, kept even while empty). Returns its id.
    @discardableResult
    public func createArea(named name: String) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = entity(named: trimmed, kind: .area) { return existing.id }
        let e = BrainEntity(kind: .area, name: trimmed, createdAt: now(), locks: EntityLocks(name: true, parent: false, membership: false))
        state.entities.append(e)
        logCorrection("New area \(trimmed)", [e.id])
        reindex()
        return e.id
    }

    /// Deletes a topic or area. Its sub-topics move up to its parent; items with no other topic go to Unsorted.
    public func deleteTopic(_ id: UUID) {
        guard let e = entity(id), e.kind.isTaxonomy else { return }
        for i in state.entities.indices where state.entities[i].parentID == id { state.entities[i].parentID = e.parentID }
        let items = state.taxonomy.members(of: id)
        state.taxonomy.members[id.uuidString] = nil
        for item in items where state.taxonomy.primary[item.uuidString] == id {
            let other = state.taxonomy.members.sorted { $0.key < $1.key }.first { $0.value.contains(item) }.flatMap { UUID(uuidString: $0.key) }
            state.taxonomy.primary[item.uuidString] = other
            if other == nil { state.taxonomy.unsorted.append(item) }
        }
        state.entities.removeAll { $0.id == id }
        logCorrection("Deleted \(e.name)", [])
        reindex()
    }

    // MARK: Pages

    /// Replaces the summary with the user's text (kept from then on); nil hands it back to AI.
    public func editSummary(_ id: UUID, text: String?) {
        guard entity(id) != nil else { return }
        updateEntity(id) { x in
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                x.summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
                x.summarySources = []
                x.summaryEditedByUser = true
            } else {
                x.summaryEditedByUser = false
                x.synthesizedAt = nil
            }
            x.updatedAt = now()
        }
        didChange()
    }

    /// Adds the user's own key fact (always kept).
    @discardableResult
    public func addFact(_ text: String, to id: UUID, itemIDs: [UUID] = []) -> CitedText? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, entity(id) != nil else { return nil }
        let fact = CitedText(text: trimmed, itemIDs: itemIDs, pinned: true, author: .user)
        updateEntity(id) { $0.keyFacts.insert(fact, at: 0) }
        didChange()
        return fact
    }

    /// Pins (keeps through re-synthesis) or unpins a key fact or disagreement.
    public func setFactPinned(_ factID: UUID, in id: UUID, _ pinned: Bool) {
        updateEntity(id) { x in
            if let i = x.keyFacts.firstIndex(where: { $0.id == factID }) { x.keyFacts[i].pinned = pinned }
            if let i = x.disagreements.firstIndex(where: { $0.id == factID }) { x.disagreements[i].pinned = pinned }
        }
        didChange()
    }

    /// Removes a key fact, disagreement or (by text) an open question.
    public func removeFact(_ factID: UUID, from id: UUID) {
        updateEntity(id) { x in
            x.keyFacts.removeAll { $0.id == factID }
            x.disagreements.removeAll { $0.id == factID }
        }
        didChange()
    }

    public func removeOpenQuestion(_ question: String, from id: UUID) {
        updateEntity(id) { $0.openQuestions.removeAll { $0 == question } }
        didChange()
    }

    // MARK: Helpers

    func logCorrection(_ summary: String, _ ids: [UUID]) {
        state.log(BrainChange(date: now(), kind: .correction, summary: summary, details: [summary], entityIDs: ids))
    }
}
