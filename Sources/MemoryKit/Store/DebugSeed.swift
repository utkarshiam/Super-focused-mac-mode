import CoreGraphics
import Foundation
import ImageIO

extension MemoryLibrary {
    /// The model stamped on seeded vectors. A real key re-embeds them (different model).
    public static let debugSeedModel = "debug-seed"

    /// Replaces everything with ~16 realistic sample memories (all kinds, several lenses, people,
    /// projects, moments, one image file, a profile and fake vectors), dated relative to `now`, so
    /// screenshots and previews look real without a Gemini key. Names are generic; nothing is personal.
    public func debugSeed(now: Date = Date(), lenses: [Lens] = [.founder, .manager]) {
        let cal = Calendar.current
        func daysAgo(_ d: Int, hour: Int = 10) -> Date {
            let day = cal.date(byAdding: .day, value: -d, to: cal.startOfDay(for: now))!
            return cal.date(byAdding: .hour, value: hour, to: day)!
        }
        func dayFromNow(_ d: Int) -> Date { cal.date(byAdding: .day, value: d, to: cal.startOfDay(for: now))! }
        let oneYearAgo = cal.date(byAdding: .year, value: -1, to: daysAgo(0, hour: 15))!

        // Topic clusters for the fake vectors: items sharing a cluster come out related.
        enum C: Int, CaseIterable { case fundraising, pricing, billing, sales, team, product, art, hiring, marketing }

        var seeds: [(MemoryItem, [C])] = []
        func seed(_ item: MemoryItem, _ clusters: [C]) { seeds.append((item, clusters)) }

        seed(MemoryItem(kind: .note, title: "Seed round: investor feedback",
                        summary: "Notes from the partner meeting with Harbor Capital. Strong interest in the retention numbers; they want a clearer path to $1M ARR.",
                        body: "Met Priya Shah and Tom Becker at Harbor Capital.\n\nThey liked the 92% logo retention and the self-serve motion. Main pushback: CAC payback is unclear and the market slide feels too broad.\n\nAgreed to go with a SAFE rather than a priced round to keep the timeline short. Priya will send a draft term sheet.",
                        keyTakeaways: ["92% logo retention resonated", "Pushback on CAC payback and market size", "Going with a SAFE, target $2M"],
                        people: ["Priya Shah", "Tom Becker"], projects: ["Seed round"], topics: ["fundraising"], tags: ["investors"],
                        moments: [Moment(kind: .decision, text: "Raise the seed on a SAFE instead of a priced round to keep the timeline short."),
                                  Moment(kind: .promise, text: "Priya Shah sends a draft term sheet.", who: "Priya Shah", due: dayFromNow(3), direction: .theirs),
                                  Moment(kind: .insight, text: "Investors respond to retention more than to top-of-funnel growth.")],
                        createdAt: daysAgo(1, hour: 16)), [.fundraising])

        seed(MemoryItem(kind: .link, title: "What makes a pricing page convert",
                        summary: "A teardown of 40 SaaS pricing pages: three tiers, an anchored middle plan and outcome-led headlines convert best.",
                        extractedText: "Most pricing pages lead with features. The best ones lead with the outcome the buyer wants, anchor on a recommended middle tier and answer the top three objections right below the table.",
                        keyTakeaways: ["Lead with the outcome, not the feature list", "Highlight a recommended middle tier", "Answer objections under the table"],
                        url: "https://example.com/blog/pricing-pages", capturedFrom: "example.com",
                        projects: ["Pricing refresh"], topics: ["pricing", "conversion"], tags: ["swipe", "pricing"],
                        moments: [Moment(kind: .insight, text: "Outcome-led headlines beat feature lists on pricing pages.")],
                        createdAt: daysAgo(2, hour: 9)), [.pricing, .marketing])

        seed(MemoryItem(kind: .audio, title: "Idea: a weekly digest email",
                        summary: "Voice note proposing a Monday digest that shows each customer what changed in their account last week.",
                        extractedText: "Quick idea on the walk back. What if every Monday customers got a short digest: what changed, what's overdue, one tip. Could cut churn for the quiet accounts. Ask Maya if the events pipeline can feed it.",
                        capturedFrom: "iPhone", people: ["Maya Chen"], projects: ["Retention"], topics: ["product", "email"],
                        moments: [Moment(kind: .idea, text: "Send customers a Monday digest of what changed in their account."),
                                  Moment(kind: .promise, text: "Ask Maya Chen whether the events pipeline can feed the digest.", due: dayFromNow(1), direction: .mine)],
                        createdAt: daysAgo(0, hour: 8)).withOrigin(.phone), [.product])

        seed(MemoryItem(kind: .message, title: "Billing API incident follow-up",
                        summary: "Slack thread on Tuesday's double-charge incident: root cause was retried requests without idempotency keys.",
                        body: "Sam Rivera: Root cause confirmed, the mobile client retried charge requests on timeout and the API had no idempotency keys.\nSam Rivera: Proposal: require Idempotency-Key on POST /v1/charges.\nYou: Agreed, let's ship it this sprint. I'll write the postmortem.",
                        keyTakeaways: ["Root cause: client retries without idempotency keys", "Fix: require Idempotency-Key on POST /v1/charges"],
                        capturedFrom: "Slack · #eng-billing", people: ["Sam Rivera"], projects: ["Billing API"], topics: ["incident"], tags: ["postmortem"],
                        moments: [Moment(kind: .decision, text: "Require an Idempotency-Key header on POST /v1/charges.", who: "Sam Rivera"),
                                  Moment(kind: .promise, text: "Write the double-charge postmortem.", due: dayFromNow(2), direction: .mine)],
                        createdAt: daysAgo(3, hour: 14)).withRef(SourceRef.slack(channel: "C0BILLING", ts: "1700000000.000100")), [.billing])

        seed(MemoryItem(kind: .task, origin: .auto, title: "Send Q3 board deck to Alex Kim",
                        summary: "", body: "Completed task · Board", people: ["Alex Kim"], projects: ["Board"],
                        createdAt: daysAgo(4, hour: 17), lightweight: true), [.fundraising, .team])

        seed(MemoryItem(kind: .message, title: "Acme renewal: security questionnaire",
                        summary: "Jordan Lee at Acme needs a SOC 2 report before signing the renewal; procurement deadline is end of month.",
                        body: "Hi, before we can sign the renewal our security team needs your SOC 2 Type II report or a bridge letter. Procurement closes the quarter at the end of the month. — Jordan Lee, Acme",
                        keyTakeaways: ["Blocker: SOC 2 report or bridge letter", "Procurement deadline: end of month", "Renewal at $48k ARR"],
                        capturedFrom: "Gmail", people: ["Jordan Lee"], projects: ["Acme renewal"], topics: ["sales", "security"], tags: ["renewal"],
                        moments: [Moment(kind: .insight, text: "Acme won't sign without a SOC 2 report or a bridge letter.", who: "Jordan Lee"),
                                  Moment(kind: .promise, text: "Send Jordan Lee the SOC 2 bridge letter.", due: dayFromNow(4), direction: .mine)],
                        createdAt: daysAgo(5, hour: 11)).withRef(SourceRef.gmail(threadID: "18c2f0a9d1e3b7aa")), [.sales])

        seed(MemoryItem(kind: .note, title: "1:1 with Maya Chen",
                        summary: "Maya wants to own the events pipeline end to end and asked for more time with customers.",
                        body: "- Events pipeline is stable; Maya wants to own it end to end\n- Wants to join two customer calls a month\n- Feedback: her design reviews are thorough, could share drafts earlier\n- I'll set up the customer calls with Jordan",
                        keyTakeaways: ["Maya to own the events pipeline", "Two customer calls a month", "Share drafts earlier"],
                        people: ["Maya Chen", "Jordan Lee"], projects: ["Events pipeline"], topics: ["1:1", "growth"],
                        moments: [Moment(kind: .decision, text: "Maya Chen owns the events pipeline end to end from now on."),
                                  Moment(kind: .promise, text: "Set up two customer calls a month for Maya Chen.", due: dayFromNow(6), direction: .mine)],
                        createdAt: daysAgo(6, hour: 15)), [.team, .product])

        seed(MemoryItem(kind: .image, title: "Whiteboard: onboarding flow v2",
                        summary: "Photo of the whiteboard sketch for the new onboarding: import data first, invite the team second, skip the tour.",
                        extractedText: "Whiteboard with three boxes: 1. Import your data 2. Invite your team 3. First report. Arrow from 3 back to 1 labelled 'aha in 5 min'. 'Kill the product tour' circled.",
                        capturedFrom: "iPhone", people: ["Maya Chen"], projects: ["Onboarding v2"], topics: ["product", "onboarding"],
                        moments: [Moment(kind: .idea, text: "Drop the product tour and get people to a first report within five minutes.")],
                        createdAt: daysAgo(8, hour: 12)).withOrigin(.phone), [.product])

        seed(MemoryItem(kind: .pdf, title: "Market sizing: SMB bookkeeping",
                        summary: "Analyst report estimating 1.2M US small businesses outsourcing bookkeeping, growing 9% a year.",
                        extractedText: "Approximately 1.2 million US small businesses outsource bookkeeping. The segment grows 9% annually. Average spend is $4,800 per year.",
                        keyTakeaways: ["1.2M US SMBs outsource bookkeeping", "9% annual growth", "$4,800 average yearly spend"],
                        projects: ["Seed round"], topics: ["market", "research"], tags: ["tam"],
                        moments: [Moment(kind: .insight, text: "Bottom-up TAM: 1.2M businesses × $4,800 a year ≈ $5.8B.")],
                        createdAt: daysAgo(10, hour: 10)), [.fundraising, .marketing])

        seed(MemoryItem(kind: .link, title: "Designing an event pipeline that doesn't lose data",
                        summary: "Engineering post on at-least-once delivery, idempotent consumers and replayable logs.",
                        extractedText: "At-least-once delivery plus idempotent consumers gives you effectively-once processing. Keep a replayable log and version your event schemas.",
                        keyTakeaways: ["At-least-once + idempotent consumers", "Keep a replayable log", "Version event schemas"],
                        url: "https://example.org/engineering/event-pipelines", capturedFrom: "example.org",
                        projects: ["Events pipeline"], topics: ["architecture"], tags: ["reference"],
                        moments: [Moment(kind: .insight, text: "Idempotent consumers make at-least-once delivery safe.")],
                        createdAt: daysAgo(12, hour: 21)), [.billing, .product])

        seed(MemoryItem(kind: .note, title: "Series idea: Tidal maps",
                        summary: "A print series layering tide charts over hand-drawn coastlines, in two inks.",
                        body: "Tide tables as rhythm. Overlay the monthly curve on coastlines I've walked. Two inks only: ultramarine and warm grey. Risograph? Ask Nina about the studio's press.",
                        people: ["Nina Okafor"], projects: ["Tidal maps"], topics: ["printmaking"], tags: ["series"],
                        moments: [Moment(kind: .idea, text: "Overlay monthly tide curves on hand-drawn coastlines, printed in two inks."),
                                  Moment(kind: .insight, text: "Limit the palette to ultramarine and warm grey.")],
                        createdAt: daysAgo(18, hour: 19)), [.art])

        seed(MemoryItem(kind: .text, origin: .engram, title: "Notes on hiring senior engineers",
                        summary: "Work-sample interviews beat puzzles; sell the problem, not the perks; move from first call to offer in two weeks.",
                        body: "Saved in ENGRAM from a podcast.",
                        keyTakeaways: ["Work samples over puzzles", "Sell the problem", "Two weeks from first call to offer"],
                        capturedFrom: "ENGRAM", projects: ["Hiring"], topics: ["hiring"],
                        moments: [Moment(kind: .insight, text: "Candidates decide faster when the whole process takes under two weeks.")],
                        createdAt: daysAgo(30, hour: 7), lightweight: true).withRef(SourceRef.engram("seed-hiring-1")), [.hiring, .team])

        seed(MemoryItem(kind: .note, title: "Coffee with Leo Martins: partnerships",
                        summary: "Leo suggested a referral partnership with two accounting firms; worth a pilot next quarter.",
                        body: "Leo Martins (partnerships lead at a regional accounting group) thinks two of their firms would refer clients if we offered a shared dashboard. Pilot next quarter?",
                        people: ["Leo Martins"], projects: ["Partnerships"], topics: ["partnerships"],
                        moments: [Moment(kind: .idea, text: "Pilot a referral partnership with two accounting firms using a shared dashboard.")],
                        pinned: true, createdAt: daysAgo(41, hour: 9)), [.sales, .marketing])

        seed(MemoryItem(kind: .message, title: "Spring launch: campaign results",
                        summary: "Email campaign recap: 41% open rate, 6.2% click-through; the customer-story subject line won.",
                        body: "Spring launch recap from the marketing channel. Subject line A (feature list): 33% open. Subject line B (customer story): 41% open, 6.2% CTR. Webinar signups: 380.",
                        keyTakeaways: ["Customer-story subject line: 41% open", "6.2% click-through", "380 webinar signups"],
                        capturedFrom: "Slack · #marketing", projects: ["Spring launch"], topics: ["email", "campaigns"], tags: ["metrics"],
                        moments: [Moment(kind: .insight, text: "Customer-story subject lines beat feature lists (41% vs 33% opens).")],
                        createdAt: daysAgo(55, hour: 13)), [.marketing])

        seed(MemoryItem(kind: .note, title: "Offsite retro",
                        summary: "Team offsite retro: ship smaller, write decisions down, protect Thursday focus time.",
                        body: "What went well: the billing launch, customer calls. What didn't: big-bang releases, decisions lost in Slack. Changes: ship behind flags, a decision log, no-meeting Thursdays.",
                        people: ["Maya Chen", "Sam Rivera", "Alex Kim"], projects: ["Team rituals"], topics: ["retro"],
                        moments: [Moment(kind: .decision, text: "Keep a written decision log for every product and hiring decision."),
                                  Moment(kind: .decision, text: "Make Thursdays meeting-free.")],
                        createdAt: oneYearAgo), [.team])

        seed(MemoryItem(kind: .note, title: "Pricing: annual discount question",
                        body: "Should annual plans get 2 months free or 15% off? Check what the pricing teardown said.",
                        projects: ["Pricing refresh"], createdAt: daysAgo(0, hour: 11), processing: .skipped), [.pricing])

        // Replace everything.
        batch {
            remove(Set(items.map(\.id)))
            removeAllVectors()
            var stored: [(MemoryItem, [C])] = []
            for (item, clusters) in seeds {
                var item = item
                if item.processing == .pending { item.processing = .processed; item.processedAt = item.createdAt }
                stored.append((add(item), clusters))
            }
            // Fake but consistent vectors: one random direction per cluster, plus a little noise.
            var rng = SeedRandom(seed: 0xD0C)
            let dims = 768
            let bases = C.allCases.map { _ in (0..<dims).map { _ in rng.nextGaussian() } }
            for (item, clusters) in stored where item.processing == .processed {
                var v = [Float](repeating: 0, count: dims)
                for c in clusters { for i in 0..<dims { v[i] += bases[c.rawValue][i] } }
                for i in 0..<dims { v[i] += 0.35 * rng.nextGaussian() }
                setVector(v, for: item.id, model: Self.debugSeedModel)
            }
            // A real image for the whiteboard photo, so thumbnails and previews work.
            if let photo = stored.first(where: { $0.0.kind == .image })?.0, let png = Self.debugImagePNG() {
                _ = try? attachData(png, name: "whiteboard.png", to: photo.id)
            }

            var profile = MemoryProfile(refreshedAt: daysAgo(1), itemCountAtRefresh: seeds.count)
            profile.facts = [
                ProfileFact(text: "Co-founder and CEO of a 14-person B2B software startup for small businesses.", category: .role, pinned: true, source: .user),
                ProfileFact(text: "Raising a $2M seed round on a SAFE.", category: .project, source: .ai),
                ProfileFact(text: "Manages Maya Chen (events pipeline) and Sam Rivera (billing).", category: .person, source: .ai),
                ProfileFact(text: "Goal: reach $1M ARR with self-serve plus partnerships.", category: .goal, source: .ai),
                ProfileFact(text: "Prefers short, direct answers with numbers.", category: .style, source: .ai),
                ProfileFact(text: "Makes risograph prints on weekends.", category: .interest, source: .ai),
            ]
            setProfile(profile)
            setLenses(lenses)
        }
    }

    /// A small whiteboard-like PNG (three boxes and arrows), drawn with CoreGraphics.
    static func debugImagePNG(width: Int = 640, height: Int = 420) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setStrokeColor(CGColor(red: 0.15, green: 0.2, blue: 0.45, alpha: 1))
        ctx.setLineWidth(5)
        let box = CGSize(width: 150, height: 90)
        let xs: [CGFloat] = [50, 245, 440]
        for x in xs { ctx.stroke(CGRect(origin: CGPoint(x: x, y: 230), size: box)) }
        for x in xs.dropLast() {
            ctx.move(to: CGPoint(x: x + box.width + 8, y: 275))
            ctx.addLine(to: CGPoint(x: x + 195 - 8, y: 275))
        }
        ctx.move(to: CGPoint(x: 515, y: 222))
        ctx.addCurve(to: CGPoint(x: 125, y: 222), control1: CGPoint(x: 470, y: 90), control2: CGPoint(x: 170, y: 90))
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 0.75, green: 0.2, blue: 0.15, alpha: 1))
        ctx.strokeEllipse(in: CGRect(x: 230, y: 40, width: 180, height: 60))
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

private extension MemoryItem {
    func withOrigin(_ origin: MemoryOrigin) -> MemoryItem { var c = self; c.origin = origin; return c }
    func withRef(_ ref: String) -> MemoryItem { var c = self; c.sourceRef = ref; return c }
}

/// A tiny deterministic generator (SplitMix64) so seeded vectors are the same every run.
struct SeedRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Standard normal (Box–Muller).
    mutating func nextGaussian() -> Float {
        let u1 = max(nextUnit(), 1e-12), u2 = nextUnit()
        return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
    }
}
