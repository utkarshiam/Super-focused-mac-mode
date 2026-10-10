import Foundation

extension SourceRef {
    /// `voice:<uuid>`: a voice note recorded on the Mac (phone recordings keep `phone:<envelope id>`).
    public static func voice(_ id: UUID) -> String { "voice:\(id.uuidString)" }
}

extension VoiceDebrief {
    /// The memory of the recording: kind audio, the transcript as its extracted text, and what the debrief
    /// found (title, summary, takeaways, people, projects, tags, moments).
    ///
    /// `processed`: the debrief came from AI, so the item is marked processed and the processor only embeds
    /// it (an item processed without a vector gets one, no second extraction call). Otherwise it stays
    /// pending, and AI works on the recording once there is a key. Attach the audio afterwards (or pass
    /// `attachments`).
    public func memoryItem(id: UUID = UUID(), sourceRef: String?, origin: MemoryOrigin, capturedFrom: String?,
                           attachments: [MemoryAttachment] = [], processed: Bool, now: Date = Date()) -> MemoryItem {
        let clean: ([String]) -> [String] = { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return MemoryItem(id: id, kind: .audio, origin: origin, sourceRef: sourceRef,
                          title: heading.isEmpty ? "Voice note, \(MemoryDates.prompt(recordedAt))" : heading,
                          summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                          extractedText: TextFold.cap(transcript.trimmingCharacters(in: .whitespacesAndNewlines), LinkFetcher.maxTextCharacters),
                          keyTakeaways: Array(clean(keyTakeaways).prefix(5)),
                          capturedFrom: capturedFrom,
                          people: TextFold.uniqueNames(people),
                          projects: TextFold.uniqueNames(projects, limit: 10),
                          tags: TextFold.uniqueNames(tags.map { $0.lowercased().replacingOccurrences(of: " ", with: "-") }, limit: 10),
                          moments: moments, attachments: attachments, createdAt: recordedAt,
                          processing: processed ? .processed : .pending, processedAt: processed ? now : nil)
    }
}
