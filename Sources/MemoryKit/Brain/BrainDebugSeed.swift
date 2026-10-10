import Foundation

extension MemoryBrain {
    /// Replaces the brain with a rich, realistic sample built on `MemoryLibrary.debugSeed` (seeding the library
    /// first when it doesn't hold the sample): six areas, eleven topics (Pricing with two sub-topics), people,
    /// organisations and projects resolved from the items (Acme and Acme Inc. merged, extra spellings for Priya
    /// Shah and Harbor Capital), living pages with [n] citations, a disagreement, open questions, three
    /// connections, a written digest for this week, a change log and a cached map layout. No network, no AI;
    /// dates are relative to `now`. Names are generic; nothing is personal.
    public func debugSeed(now: Date = Date()) {
        if !library.items.contains(where: { $0.title == "Seed round: investor feedback" }) {
            library.debugSeed(now: now, lenses: [.founder, .manager])
        }
        let cal = Calendar.current
        func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
        func item(_ prefix: String) -> MemoryItem? { library.items.first { $0.title.hasPrefix(prefix) } }
        func ids(_ prefixes: [String]) -> [UUID] { prefixes.compactMap { item($0)?.id } }
        func label(_ date: Date?) -> String { date.map { MemoryDates.label($0, now: now) } ?? "" }

        // 1. Start clean: entities resolved from the items (ids are stable for a fresh brain).
        replaceState(BrainState())
        var s = state
        func id(_ name: String, _ kind: EntityKind) -> UUID? { entity(named: name, kind: kind)?.id }

        // Spellings the user merged in.
        if let priya = id("Priya Shah", .person) {
            s.corrections.forced[EntityNames.scopedKey("Priya", kind: .person)] = .init(entityID: priya, spelling: "Priya")
            s.corrections.forced[EntityNames.scopedKey("P. Shah", kind: .person)] = .init(entityID: priya, spelling: "P. Shah")
        }
        if let harbor = id("Harbor Capital", .organisation) {
            s.corrections.forced[EntityNames.scopedKey("Harbor Capital Partners", kind: .organisation)] =
                .init(entityID: harbor, spelling: "Harbor Capital Partners")
        }

        // 2. Areas and topics.
        func stable(_ kind: String, _ name: String) -> UUID { BrainIDs.stable("debug-seed:\(kind):\(name)") }
        let areaNames: [(String, String)] = [
            ("Fundraising", "Raising the seed round: investors, numbers and the board."),
            ("Customers", "Accounts, renewals and the partners who send customers your way."),
            ("Product", "What you're building: pricing, onboarding, retention and reliability."),
            ("Team", "1:1s, rituals and hiring."),
            ("Marketing", "Campaigns and what made people open, click and sign up."),
            ("Personal", "Your own work outside the company."),
        ]
        var entities: [BrainEntity] = s.entities.filter { $0.kind.isExtracted }
        for (name, detail) in areaNames {
            entities.append(BrainEntity(id: stable("area", name), kind: .area, name: name, detail: detail, createdAt: daysAgo(9)))
        }
        struct TopicSeed {
            var name: String
            var area: String?
            var parent: String?
            var items: [String]
            var detail: String
            var created: Double
            var aliases: [String] = []
        }
        let topicSeeds: [TopicSeed] = [
            TopicSeed(name: "Seed round", area: "Fundraising", items: ["Seed round: investor", "Market sizing", "Q3 board deck"],
                      detail: "The $2M SAFE: investor feedback, market sizing and the board deck.", created: 9, aliases: ["Seed raise"]),
            TopicSeed(name: "Renewals", area: "Customers", items: ["Acme renewal"],
                      detail: "Acme's $48k renewal and the SOC 2 questionnaire blocking it.", created: 9),
            TopicSeed(name: "Referral partners", area: "Customers", items: ["Coffee with Leo"],
                      detail: "Accounting firms that could refer clients through a shared dashboard.", created: 9, aliases: ["Partnerships"]),
            TopicSeed(name: "Pricing", area: "Product", items: [],
                      detail: "How plans are priced and presented.", created: 9, aliases: ["Pricing strategy"]),
            TopicSeed(name: "Pricing page", parent: "Pricing", items: ["What makes a pricing page convert"],
                      detail: "What makes a pricing page convert.", created: 1),
            TopicSeed(name: "Annual discounts", parent: "Pricing", items: ["Pricing: annual discount"],
                      detail: "Whether annual plans get 2 months free or 15% off.", created: 1),
            TopicSeed(name: "Onboarding", area: "Product", items: ["Whiteboard: onboarding"],
                      detail: "Getting new accounts to a first report in five minutes.", created: 9),
            TopicSeed(name: "Retention ideas", area: "Product", items: ["Idea: a weekly digest"],
                      detail: "Ideas for keeping quiet accounts engaged.", created: 9, aliases: ["Retention"]),
            TopicSeed(name: "Billing reliability", area: "Product", items: ["Billing API incident", "Designing an event pipeline"],
                      detail: "The double-charge incident, idempotency and event delivery.", created: 9),
            TopicSeed(name: "1:1s and rituals", area: "Team", items: ["1:1 with Maya", "Offsite retro"],
                      detail: "Commitments from 1:1s and how the team works.", created: 9),
            TopicSeed(name: "Hiring engineers", area: "Team", items: ["Notes on hiring"],
                      detail: "How to hire senior engineers quickly.", created: 9, aliases: ["Hiring"]),
            TopicSeed(name: "Email campaigns", area: "Marketing", items: ["Spring launch", "Idea: a weekly digest"],
                      detail: "Email results and subject lines that worked.", created: 9, aliases: ["Campaigns", "Email"]),
            TopicSeed(name: "Printmaking", area: "Personal", items: ["Series idea: Tidal maps"],
                      detail: "Prints and series in progress.", created: 9),
        ]
        var members: [String: [UUID]] = [:]
        var primary: [String: UUID] = [:]
        for t in topicSeeds {
            let topicID = stable("topic", t.name)
            let parent = t.parent.map { stable("topic", $0) } ?? t.area.map { stable("area", $0) }
            entities.append(BrainEntity(id: topicID, kind: .topic, name: t.name, aliases: [t.name] + t.aliases, parentID: parent,
                                        detail: t.detail, createdAt: daysAgo(t.created)))
            let itemIDs = ids(t.items)
            if !itemIDs.isEmpty { members[topicID.uuidString] = itemIDs }
            for item in itemIDs where primary[item.uuidString] == nil { primary[item.uuidString] = topicID }
        }
        s.entities = entities
        s.taxonomy = BrainTaxonomy(members: members, primary: primary, unsorted: [], organizedAt: daysAgo(1),
                                   itemCountAtOrganize: library.count, newSinceOrganize: 0, similarityFloor: 0.3,
                                   space: "vectors:\(MemoryLibrary.debugSeedModel):768")

        // 3. Change log.
        s.changeLog = [
            BrainChange(date: daysAgo(1), kind: .organised, summary: "2 new topics: Pricing page, Annual discounts · merged Pricing strategy into Pricing",
                        details: ["2 new topics: Pricing page, Annual discounts", "merged Pricing strategy into Pricing"],
                        entityIDs: [stable("topic", "Pricing page"), stable("topic", "Annual discounts"), stable("topic", "Pricing")]),
            BrainChange(date: daysAgo(5), kind: .resolved, summary: "Merged Acme Inc. into Acme", details: ["Acme Inc. → Acme"],
                        entityIDs: [id("Acme", .organisation)].compactMap { $0 }),
            BrainChange(date: daysAgo(9), kind: .organised, summary: "Organised \(library.count) memories into 11 topics in 6 areas",
                        entityIDs: areaNames.map { stable("area", $0.0) }),
        ]
        replaceState(s)

        // 4. Living pages (citations point at real items).
        let seed = item("Seed round: investor"), market = item("Market sizing"), deck = item("Q3 board deck")
        let acme = item("Acme renewal"), oneOnOne = item("1:1 with Maya"), whiteboard = item("Whiteboard: onboarding")
        let digestIdea = item("Idea: a weekly digest"), pricingPage = item("What makes a pricing page convert")
        let annual = item("Pricing: annual discount"), incident = item("Billing API incident"), pipeline = item("Designing an event pipeline")
        func page(_ entityID: UUID?, summary: String, sources: [MemoryItem?], facts: [(String, [MemoryItem?])],
                  questions: [String] = [], disagreements: [(String, [MemoryItem?])] = []) {
            guard let entityID else { return }
            // Written after the newest change to its items, so it isn't due again.
            let latest = itemIDs(for: entityID).compactMap { library.item($0)?.updatedAt }.max() ?? now
            let writtenAt = max(now.addingTimeInterval(-3600), latest)
            updateEntity(entityID) { e in
                e.summary = summary
                e.summarySources = sources.compactMap { $0?.id }
                e.keyFacts = facts.map { CitedText(text: $0.0, itemIDs: $0.1.compactMap { $0?.id }) }
                e.openQuestions = questions
                e.disagreements = disagreements.map { CitedText(text: $0.0, itemIDs: $0.1.compactMap { $0?.id }) }
                e.synthesizedAt = writtenAt
                e.itemCountAtSynthesis = e.itemCount
            }
        }
        page(stable("topic", "Seed round"),
             summary: "You're raising a **$2M seed** on a SAFE rather than a priced round, to keep the timeline short [1]. Harbor Capital liked the 92% logo retention but pushed back on CAC payback and a market slide that felt too broad [1]; the bottom-up sizing puts the market at about $5.8B [2]. The Q3 board deck still showed a $1.5M target [3].",
             sources: [seed, market, deck],
             facts: [("Raising on a SAFE, target $2M", [seed]), ("92% logo retention", [seed]),
                     ("Bottom-up market: 1.2M US businesses × $4,800 a year ≈ $5.8B", [market]), ("18 months of runway in the board deck", [deck])],
             questions: ["How will you show a clear CAC payback?", "When does Priya Shah's draft term sheet arrive?"],
             disagreements: [("Seed target: $1.5M in the board deck (\(label(deck?.createdAt))) vs $2M after the Harbor Capital meeting (\(label(seed?.createdAt)))", [deck, seed])])
        let termSheetDue = seed?.moments.first { $0.kind == .promise }?.due
        page(id("Priya Shah", .person),
             summary: "Priya Shah is at Harbor Capital; you met her with Tom Becker for the seed round [1]. She's sending a draft term sheet for the SAFE, due \(label(termSheetDue)) [1].",
             sources: [seed],
             facts: [("Investor at Harbor Capital", [seed]), ("Owes you a draft term sheet by \(label(termSheetDue))", [seed])],
             questions: ["Has the draft term sheet arrived?"])
        page(id("Maya Chen", .person),
             summary: "Maya Chen now owns the **events pipeline** end to end and wants to join two customer calls a month [1]. She sketched onboarding v2: import data, invite the team, a first report within five minutes [2]. The Monday digest idea depends on whether her pipeline can feed it [3].",
             sources: [oneOnOne, whiteboard, digestIdea],
             facts: [("Owns the events pipeline end to end", [oneOnOne]), ("Joins two customer calls a month", [oneOnOne]),
                     ("Feedback: share design drafts earlier", [oneOnOne])],
             questions: ["Can the events pipeline feed the Monday digest?"])
        page(stable("topic", "Pricing"),
             summary: "Pricing pages convert best with three tiers, a recommended middle plan and outcome-led headlines [1]. Still undecided: whether annual plans get 2 months free or 15% off [2].",
             sources: [pricingPage, annual],
             facts: [("Lead with the outcome, not the feature list", [pricingPage]), ("Answer the top objections under the table", [pricingPage])],
             questions: ["Annual plans: 2 months free or 15% off?"])
        page(id("Acme", .organisation),
             summary: "Acme won't sign its **$48k renewal** without a SOC 2 Type II report or a bridge letter, and procurement closes at the end of the month [1]. Jordan Lee is your contact; Maya Chen will join customer calls with Jordan [1][2].",
             sources: [acme, oneOnOne],
             facts: [("Renewal worth $48k ARR", [acme]), ("Blocker: SOC 2 report or bridge letter", [acme])],
             questions: ["Will Acme accept a bridge letter instead of the SOC 2 report?"])
        page(stable("topic", "Billing reliability"),
             summary: "The double charges came from client retries without idempotency keys, so POST /v1/charges now requires an Idempotency-Key [1]. Idempotent consumers are what make at-least-once delivery safe in the events pipeline too [2].",
             sources: [incident, pipeline],
             facts: [("Root cause: retries without idempotency keys", [incident]), ("Keep a replayable log and version event schemas", [pipeline])],
             questions: ["Is the double-charge postmortem written?"])

        // 5. Connections and the digest.
        var connections: [BrainConnection] = []
        func connect(_ a: MemoryItem?, _ b: MemoryItem?, _ score: Double, _ reason: String, _ days: Double) {
            guard let a, let b else { return }
            connections.append(BrainConnection(id: BrainIDs.stable("debug-seed:connection:\(a.title)"), a: a.id, b: b.id, score: score,
                                               reason: reason, foundAt: daysAgo(days)))
        }
        connect(digestIdea, item("Spring launch"), 0.71, "The customer-story subject line that won 41% opens could headline the Monday digest.", 0.2)
        connect(market, item("Coffee with Leo"), 0.64, "Accounting-firm referrals reach the 1.2M businesses that already outsource bookkeeping.", 0.2)
        connect(pricingPage, acme, 0.58, "Answering objections under the pricing table could cover security, Acme's blocker.", 0.2)
        state.connections = connections
        state.connectionsAt = now.addingTimeInterval(-3600)
        state.seenPairs = connections.map(\.pairKey)

        var digest = BrainInsights.digest(week: now, items: library.items, topics: allTopics(), topicItems: { self.topicItems($0) },
                                          connections: connections, now: now, calendar: cal)
        let digestSources = [seed, acme, digestIdea, annual].compactMap { $0 }
        digest.text = """
        - Harbor Capital wants a clearer path to $1M ARR; you're raising **$2M on a SAFE** [1].
        - Acme's $48k renewal waits on a SOC 2 report or bridge letter before the end of the month [2].
        - New idea: a Monday digest for quiet accounts, if the events pipeline can feed it [3].
        - Still open: annual plans at 2 months free or 15% off [4].
        """
        digest.sources = digestSources.map(\.id)
        digest.generatedAt = now.addingTimeInterval(-1800)
        state.digests = digest.itemCount > 0 ? [digest] : []
        lastMaintenance = now
        didChange()
        _ = map()
        flushLayoutOnly()
    }

    /// Makes sure the cached layout is part of the next save.
    private func flushLayoutOnly() { didChangeQuietly() }
}
