import Foundation

/// The user's role(s), chosen once (multi-select). A lens changes words, not data: what projects and
/// insights are called, what extraction pays attention to, which questions Ask suggests and which
/// one-click outputs are offered. Selection order matters: the first lens is the primary one and
/// names things (`Lens.vocabulary(for:)`).
public enum Lens: String, Codable, CaseIterable, Identifiable, Sendable {
    case founder, marketer, sales, engineer, manager, artist

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .founder: "Founder"
        case .marketer: "Marketer"
        case .sales: "Sales"
        case .engineer: "Engineer"
        case .manager: "Manager"
        case .artist: "Artist"
        }
    }

    /// One line for the onboarding card.
    public var blurb: String {
        switch self {
        case .founder: "Investors, hires, customers and the calls you make about the company."
        case .marketer: "Campaigns, audiences, channels and the copy that worked."
        case .sales: "Deals, buyers, objections and every next step you promised."
        case .engineer: "Systems, incidents, design decisions and the docs you'll need again."
        case .manager: "Your team, their goals, 1:1s and the commitments you made."
        case .artist: "Works in progress, references, collaborators and sparks of ideas."
        }
    }

    /// An SF Symbol name for the onboarding card.
    public var symbolName: String {
        switch self {
        case .founder: "flag"
        case .marketer: "megaphone"
        case .sales: "handshake"
        case .engineer: "chevron.left.forwardslash.chevron.right"
        case .manager: "person.3"
        case .artist: "paintpalette"
        }
    }

    // MARK: Vocabulary

    public var vocabulary: LensVocabulary {
        switch self {
        case .founder:
            LensVocabulary(project: "Initiative", projects: "Initiatives", people: "People", decisions: "Decisions",
                           promises: "Commitments", ideas: "Ideas", insights: "Learnings")
        case .marketer:
            LensVocabulary(project: "Campaign", projects: "Campaigns", people: "People", decisions: "Decisions",
                           promises: "Commitments", ideas: "Ideas", insights: "Swipe file")
        case .sales:
            LensVocabulary(project: "Deal", projects: "Deals", people: "Contacts", decisions: "Decisions",
                           promises: "Next steps", ideas: "Plays", insights: "Objections")
        case .engineer:
            LensVocabulary(project: "Service", projects: "Services", people: "People", decisions: "Decisions",
                           promises: "Commitments", ideas: "Ideas", insights: "References")
        case .manager:
            LensVocabulary(project: "Team goal", projects: "Team goals", people: "Team", decisions: "Decisions",
                           promises: "Commitments", ideas: "Ideas", insights: "Learnings")
        case .artist:
            LensVocabulary(project: "Work", projects: "Works", people: "Collaborators", decisions: "Choices",
                           promises: "Commitments", ideas: "Sketches", insights: "Inspiration")
        }
    }

    /// The words for a selection: the primary (first) lens names things; no lens → neutral words.
    public static func vocabulary(for lenses: [Lens]) -> LensVocabulary {
        lenses.first?.vocabulary ?? .neutral
    }

    // MARK: Extraction guidance

    /// What extraction should pay special attention to, written to the model. Added to the extraction,
    /// Ask and profile prompts.
    public var guidance: String {
        switch self {
        case .founder:
            """
            The user is a founder. Projects are company initiatives (fundraise, launch, hire, key customer, \
            partnership); name them as the user does ("Seed round", "EU launch"). Capture as decisions anything \
            about strategy, pricing, hiring, spend or priorities, with the reason when given. Capture as promises \
            what the user owes investors, customers, the team or the board, and what others owe them (intros, \
            term sheets, references, signed contracts), with dates. Insights are learnings about customers, the \
            market, competitors or fundraising. Record numbers exactly (ARR, burn, runway, valuation, headcount) \
            in takeaways. People: investors, customers, candidates, advisors and team members by full name, \
            with company when stated.
            """
        case .marketer:
            """
            The user is a marketer. Projects are campaigns, launches, content series and channels ("Q4 webinar \
            series", "Spring launch"). Capture as insights audience findings, positioning and messaging that \
            worked, and copy, headlines, hooks or creative worth keeping (quote them exactly: they form the swipe \
            file). Record metrics with their units and dates (CTR, CAC, conversion, open rate, spend) in \
            takeaways. Decisions: budget, channel, audience, positioning, timing. Promises: deliverables and \
            deadlines (assets, briefs, approvals, agency hand-offs). People: agencies, creators, stakeholders, \
            customers quoted.
            """
        case .sales:
            """
            The user is in sales. Projects are deals and accounts; name a deal after the customer company \
            ("Northwind renewal"). Capture as insights every objection or concern raised (price, timing, \
            security, competitor, authority) in the buyer's words, plus buying signals. Capture as promises the \
            next steps: who does what by when, on both sides (direction "mine" when the user owes it). \
            Decisions: deal stage changes, pricing or discount agreed, go/no-go. Record deal size, budget, \
            timeline, decision process, competitors and champion in takeaways. People: every contact with role \
            and company when stated.
            """
        case .engineer:
            """
            The user is an engineer. Projects are services, systems, repositories or features ("Billing API", \
            "iOS app"). Capture as decisions technical choices and their trade-offs (architecture, libraries, \
            data models, deprecations), like a short design record. Insights are references and lessons: root \
            causes of incidents, gotchas, benchmarks, commands or settings worth reusing. Keep exact identifiers \
            (error codes, versions, flags, endpoints, ticket ids) verbatim in takeaways. Promises: reviews, \
            fixes, migrations and on-call hand-offs with dates. People: owners, reviewers, stakeholders.
            """
        case .manager:
            """
            The user manages a team. Projects are team goals and initiatives (OKRs, roadmap items, hiring \
            plans). Capture as promises commitments made in 1:1s, standups and reviews, on both sides \
            (direction "mine" when the user owes it), with dates. Decisions: priorities, staffing, process and \
            scope changes, with the reason. Insights: feedback given or received, growth areas, risks, morale \
            signals and what helped. People: direct reports, peers and leadership, by name; note a person's \
            role when stated. Keep feedback factual and specific; never speculate about personal matters.
            """
        case .artist:
            """
            The user is an artist or creative. Projects are works and series (a piece, album, collection, show, \
            commission). Capture as ideas sketches, concepts, titles, motifs and "what if" thoughts, close to \
            the user's own words. Insights are inspiration and references: artists, works, techniques, \
            materials, palettes, sounds, with where they were seen. Decisions: creative choices (medium, \
            direction, cuts) and practical ones (pricing, venues, deadlines). Promises: commissions, \
            submissions, exhibition and delivery dates. People: collaborators, clients, galleries, curators.
            """
        }
    }

    /// The guidance for a selection, joined; a neutral line when none is chosen.
    public static func guidance(for lenses: [Lens]) -> String {
        guard !lenses.isEmpty else {
            return "The user hasn't said what they do. Extract what a thoughtful personal assistant would want to remember."
        }
        return lenses.map(\.guidance).joined(separator: "\n\n")
    }

    // MARK: Ask examples

    /// Four questions Ask suggests (shown when the Ask field is empty).
    public var askExamples: [String] {
        switch self {
        case .founder:
            ["What did investors push back on in the last month?",
             "Which intros did I promise and not send yet?",
             "Why did we decide on the current pricing?",
             "What have customers said about onboarding?"]
        case .marketer:
            ["Which subject lines got the best open rates?",
             "What did we learn from the last launch?",
             "What's in my swipe file about pricing pages?",
             "Which assets are still owed for the next campaign?"]
        case .sales:
            ["What objections came up on Northwind?",
             "Which next steps am I late on?",
             "Who is the champion on each open deal?",
             "What did buyers say about our competitors?"]
        case .engineer:
            ["Why did we pick Postgres over DynamoDB?",
             "What caused the last billing incident?",
             "Which reviews did I promise this week?",
             "What's the command to rotate the staging keys?"]
        case .manager:
            ["What did I commit to in 1:1s this month?",
             "What feedback have I given Alex lately?",
             "Which team goals are at risk?",
             "What did we decide about the on-call rota?"]
        case .artist:
            ["What ideas do I have for the next series?",
             "Which references did I save about colour?",
             "When are my submissions due?",
             "What did the gallery say about the show?"]
        }
    }

    /// Up to `limit` examples for a selection, taking turns between lenses so each is represented.
    public static func askExamples(for lenses: [Lens], limit: Int = 4) -> [String] {
        let lists = (lenses.isEmpty ? [] : lenses.map(\.askExamples))
        guard !lists.isEmpty else {
            return ["What did I decide last week?",
                    "What have I promised people and not done yet?",
                    "What do I know about Priya Shah?",
                    "What ideas have I saved recently?"].prefix(limit).map { $0 }
        }
        var out: [String] = []
        for i in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where i < list.count && !out.contains(list[i]) {
                out.append(list[i])
                if out.count == limit { return out }
            }
        }
        return out
    }

    // MARK: Outputs

    /// One-click outputs this lens offers (v2 builds them; v1 only defines them).
    public var outputs: [LensOutput] {
        switch self {
        case .founder:
            [LensOutput(id: "founder.investor-update", name: "Investor update", description: "Monthly update: highlights, numbers, asks and lowlights from recent memory."),
             LensOutput(id: "founder.decision-log", name: "Decision log", description: "Every company decision with its date, reason and who made it."),
             LensOutput(id: "founder.board-prep", name: "Board prep", description: "Open questions, risks and decisions to take to the next board meeting."),
             LensOutput(id: "founder.weekly-review", name: "Weekly review", description: "What moved, what's stuck and which promises are due next week."),
             LensOutput(id: "founder.customer-voice", name: "Customer voice", description: "What customers said, grouped by theme, with sources.")]
        case .marketer:
            [LensOutput(id: "marketer.campaign-brief", name: "Campaign brief", description: "Goal, audience, message, channels and dates for a campaign."),
             LensOutput(id: "marketer.swipe-file", name: "Swipe file", description: "Saved headlines, hooks and creative, grouped by angle."),
             LensOutput(id: "marketer.results-recap", name: "Results recap", description: "Metrics and learnings from a campaign, with what to repeat."),
             LensOutput(id: "marketer.content-ideas", name: "Content ideas", description: "Post and email ideas drawn from recent insights and customer quotes.")]
        case .sales:
            [LensOutput(id: "sales.account-brief", name: "Account brief", description: "People, history, objections and next steps for one account before a call."),
             LensOutput(id: "sales.follow-up-email", name: "Follow-up email", description: "A recap email of the last conversation with the agreed next steps."),
             LensOutput(id: "sales.objection-handbook", name: "Objection handbook", description: "Objections heard so far and the answers that worked."),
             LensOutput(id: "sales.pipeline-review", name: "Pipeline review", description: "Each open deal's stage, risk and overdue next steps.")]
        case .engineer:
            [LensOutput(id: "engineer.design-record", name: "Design record", description: "A decision record: context, options, decision and consequences."),
             LensOutput(id: "engineer.incident-summary", name: "Incident summary", description: "Timeline, root cause and follow-ups for an incident."),
             LensOutput(id: "engineer.handover-notes", name: "Handover notes", description: "What someone taking over a service needs to know."),
             LensOutput(id: "engineer.weekly-update", name: "Weekly update", description: "Shipped, in progress and blocked, for the team channel.")]
        case .manager:
            [LensOutput(id: "manager.one-on-one-prep", name: "1:1 prep", description: "Open commitments, recent feedback and topics for the next 1:1 with someone."),
             LensOutput(id: "manager.team-update", name: "Team update", description: "Progress on team goals, decisions and risks for leadership."),
             LensOutput(id: "manager.review-notes", name: "Review notes", description: "Evidence of impact and growth for a performance review, with sources."),
             LensOutput(id: "manager.commitments", name: "Commitments", description: "Everything promised to and by the team, by due date.")]
        case .artist:
            [LensOutput(id: "artist.artist-statement", name: "Artist statement", description: "A draft statement for a work or series from your notes and ideas."),
             LensOutput(id: "artist.mood-board", name: "Mood board", description: "Saved references and inspiration for a work, grouped by theme."),
             LensOutput(id: "artist.idea-digest", name: "Idea digest", description: "Recent sketches and ideas, with the ones worth developing first."),
             LensOutput(id: "artist.deadlines", name: "Deadlines", description: "Submissions, commissions and shows by date.")]
        }
    }

    /// Outputs for a selection, in lens order, without duplicates.
    public static func outputs(for lenses: [Lens]) -> [LensOutput] {
        var seen = Set<String>()
        return lenses.flatMap(\.outputs).filter { seen.insert($0.id).inserted }
    }
}

/// What things are called under a lens.
public struct LensVocabulary: Hashable, Codable, Sendable {
    /// Singular and plural of "project" ("Deal" / "Deals").
    public var project: String
    public var projects: String
    public var people: String
    public var decisions: String
    public var promises: String
    public var ideas: String
    /// What insights are called ("Learnings", "Objections", "Swipe file").
    public var insights: String

    public init(project: String, projects: String, people: String, decisions: String, promises: String, ideas: String, insights: String) {
        self.project = project
        self.projects = projects
        self.people = people
        self.decisions = decisions
        self.promises = promises
        self.ideas = ideas
        self.insights = insights
    }

    public static let neutral = LensVocabulary(project: "Project", projects: "Projects", people: "People", decisions: "Decisions",
                                               promises: "Promises", ideas: "Ideas", insights: "Insights")

    /// The plural label for a moment kind.
    public func label(for kind: MomentKind) -> String {
        switch kind {
        case .decision: decisions
        case .promise: promises
        case .idea: ideas
        case .insight: insights
        }
    }
}

/// A one-click output a lens offers ("Investor update").
public struct LensOutput: Identifiable, Hashable, Codable, Sendable {
    /// Stable id ("founder.investor-update").
    public var id: String
    public var name: String
    /// One line on what it produces.
    public var description: String

    public init(id: String, name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }
}
