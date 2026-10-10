import Combine
import Foundation

/// What one maintenance pass did.
public struct BrainMaintenanceReport: Equatable, Sendable {
    /// The pass didn't run (called again too soon, or one is in progress).
    public var skipped = false
    /// Ambiguous name pairs AI decided.
    public var resolvedPairs = 0
    public var organized = false
    public var pagesWritten = 0
    public var connectionsFound = 0
    public var digestWritten = false

    public init() {}
}

extension MemoryBrain {
    /// Everything the brain does in the background, each step only when due; safe to call often (a call within
    /// `maintenanceInterval` of the last one, or while one runs, returns at once):
    /// 1. `refresh()` (names, new items into topics; no AI);
    /// 2. ambiguous names to AI (one call, when there are new ones);
    /// 3. `organizeIfDue` (one naming call with AI; labels without);
    /// 4. `synthesizeStale` (up to `pageLimit` living pages, two at a time);
    /// 5. `refreshConnections` (daily);
    /// 6. last week's digest, written once (AI).
    /// Without AI, steps 2, 4 and 6 are skipped and the rest still work.
    @discardableResult
    public func runMaintenance(ai: MemoryAI?, pageLimit: Int = 3, force: Bool = false) async -> BrainMaintenanceReport {
        var report = BrainMaintenanceReport()
        let stamp = now()
        if !force, let last = lastMaintenance, stamp.timeIntervalSince(last) < maintenanceInterval { report.skipped = true; return report }
        guard !maintenanceRunning else { report.skipped = true; return report }
        maintenanceRunning = true
        lastMaintenance = stamp
        defer { maintenanceRunning = false }

        refresh()
        if let ai, !pendingCandidates.isEmpty {
            do {
                report.resolvedPairs = try await BrainOrganizer(brain: self, ai: ai).resolveAmbiguous()
            } catch {
                setError((error as? MemoryAIError) ?? .badResponse(error.localizedDescription))
            }
        }
        report.organized = await organizeIfDue(ai: ai)
        if let ai, lastError?.needsSettings != true {
            report.pagesWritten = await synthesizeStale(ai: ai, limit: pageLimit)
        }
        report.connectionsFound = await refreshConnections(ai: lastError?.isTransient == true ? nil : ai).count
        if let ai, lastError?.isTransient != true {
            let lastWeek = BrainInsights.week(of: stamp).start.addingTimeInterval(-86_400)
            let d = digest(for: lastWeek)
            if d.itemCount > 0 && !d.isWritten {
                report.digestWritten = (try? await writeDigest(for: lastWeek, ai: ai)) != nil
            }
        }
        return report
    }

    /// Wires the brain to the processor: extraction prompts get the brain's vocabulary, and maintenance runs
    /// whenever processing goes idle (with the processor's current AI). With `runNow`, a pass also starts now.
    /// Call once at launch (Mac). The phone doesn't run a brain; it reads `LibrarySnapshot.brain`.
    public func attach(to processor: MemoryProcessor, runNow: Bool = true) {
        processor.vocabulary = { [weak self] in self?.extractionVocabulary() }
        processorSubscription = processor.$processingCount
            .removeDuplicates()
            .scan((0, 0)) { ($0.1, $1) }
            .filter { $0.0 > 0 && $0.1 == 0 }
            .sink { [weak self, weak processor] _ in
                Task { @MainActor in
                    guard let self, let processor else { return }
                    await self.runMaintenance(ai: processor.ai)
                }
            }
        if runNow {
            Task { @MainActor [weak self, weak processor] in
                guard let self, let processor else { return }
                await self.runMaintenance(ai: processor.ai)
            }
        }
    }
}
