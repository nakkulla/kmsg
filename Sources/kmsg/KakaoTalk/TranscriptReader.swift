import ApplicationServices.HIServices
import Foundation

struct TranscriptMessage: Encodable, Equatable, Sendable {
    let author: String?
    let timeRaw: String?
    let body: String
    let imageCount: Int
    let linkCount: Int
    let attachmentCount: Int
    let isSystem: Bool
    let logicalTimestamp: Date?
    /// Calendar date of the message ("YYYY-MM-DD"), read from the time
    /// label's AXHelp tooltip. nil when the tooltip was unavailable.
    let date: String?

    var hasImage: Bool {
        imageCount > 0
    }

    var hasAttachment: Bool {
        attachmentCount > 0
    }

    enum CodingKeys: String, CodingKey {
        case author
        case timeRaw = "time_raw"
        case body
        case date
        case hasImage = "has_image"
        case imageCount = "image_count"
        case linkCount = "link_count"
        case hasAttachment = "has_attachment"
        case attachmentCount = "attachment_count"
    }

    init(
        author: String?,
        timeRaw: String?,
        body: String,
        imageCount: Int = 0,
        linkCount: Int = 0,
        attachmentCount: Int = 0,
        isSystem: Bool,
        logicalTimestamp: Date?,
        date: String? = nil
    ) {
        self.author = author
        self.timeRaw = timeRaw
        self.body = body
        self.imageCount = max(0, imageCount)
        self.linkCount = max(0, linkCount)
        self.attachmentCount = max(0, attachmentCount)
        self.isSystem = isSystem
        self.logicalTimestamp = logicalTimestamp
        self.date = date
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(author ?? "(me)", forKey: .author)
        try container.encodeIfPresent(timeRaw, forKey: .timeRaw)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encode(hasImage, forKey: .hasImage)
        try container.encode(imageCount, forKey: .imageCount)
        try container.encode(linkCount, forKey: .linkCount)
        try container.encode(hasAttachment, forKey: .hasAttachment)
        try container.encode(attachmentCount, forKey: .attachmentCount)
    }
}

extension TranscriptMessage {
    /// Copy with `date`/`time_raw` replaced when a value is given.
    func withDateTime(date: String?, timeRaw: String?) -> TranscriptMessage {
        TranscriptMessage(
            author: author,
            timeRaw: timeRaw ?? self.timeRaw,
            body: body,
            imageCount: imageCount,
            linkCount: linkCount,
            attachmentCount: attachmentCount,
            isSystem: isSystem,
            logicalTimestamp: logicalTimestamp,
            date: date ?? self.date
        )
    }
}

struct TranscriptSnapshot: Sendable {
    let chat: String
    let fetchedAt: Date
    let messages: [TranscriptMessage]
    /// The newest end of the conversation was loaded and is inside the analyzed rows;
    /// nil when it was not checked (background-safe, no transcript table, unreadable state).
    var newestReached: Bool? = nil

    var count: Int {
        messages.count
    }
}

enum TranscriptReadError: LocalizedError {
    case transcriptContextUnavailable
    case noMessageRows
    case noReadableMessages

    var errorDescription: String? {
        switch self {
        case .transcriptContextUnavailable:
            return "Could not locate chat transcript area."
        case .noMessageRows:
            return "No message rows found in the chat transcript area."
        case .noReadableMessages:
            return "No message body text extracted from transcript container."
        }
    }
}

struct KakaoTalkTranscriptReader {
    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner
    private let interactionMode: ChatWindowInteractionMode

    init(
        kakao: KakaoTalkApp,
        runner: AXActionRunner,
        interactionMode: ChatWindowInteractionMode = .allowUIAutomation
    ) {
        self.kakao = kakao
        self.runner = runner
        self.interactionMode = interactionMode
    }

    func readSnapshot(
        from window: UIElement,
        fallbackChatTitle: String,
        limit: Int,
        includeSystemMessages: Bool = false,
        newestEnd: NewestEndOptions? = nil
    ) throws -> TranscriptSnapshot {
        let referenceDate = Date()
        let messageContextResolver = MessageContextResolver(
            kakao: kakao,
            runner: runner,
            interactionMode: interactionMode
        )
        guard let messageContext = messageContextResolver.resolve(in: window) else {
            throw TranscriptReadError.transcriptContextUnavailable
        }

        return try readSnapshot(
            from: messageContext,
            chatWindow: window,
            fallbackChatTitle: fallbackChatTitle,
            limit: limit,
            includeSystemMessages: includeSystemMessages,
            referenceDate: referenceDate,
            newestEnd: newestEnd
        )
    }

    func readSnapshot(
        from context: MessageTranscriptContext,
        chatWindow: UIElement,
        fallbackChatTitle: String,
        limit: Int,
        includeSystemMessages: Bool = false,
        referenceDate: Date = Date(),
        newestEnd: NewestEndOptions? = nil
    ) throws -> TranscriptSnapshot {
        let table = transcriptTable(in: context.transcriptRoot)
        // Without options (watch, background-safe) the newest end is neither loaded nor judged.
        var newestOutcome: NewestEndOutcome?
        if let newestEnd {
            if let table {
                newestOutcome = loadNewestEnd(
                    table: table,
                    transcriptRoot: context.transcriptRoot,
                    maxLoads: newestEnd.maxLoads,
                    deadline: newestEnd.deadline.addingTimeInterval(-Self.recentReadReserve),
                    onlyWhenSuspect: true
                )
            } else {
                runner.log("read-newest: transcript table unavailable; newest end not checked")
            }
        }
        var newestAnalyzed: OwnTimeLabel?
        var analysisDeadlineHit = false
        var readMarkerSeen = false

        // The transcript table gives the rows directly; collecting them by search and
        // analyzing every one of them is the slow path kept for a window without a table.
        if let table {
            let tableMessages = readRecentFromTable(
                table,
                context: context,
                limit: limit,
                includeSystemMessages: includeSystemMessages,
                referenceDate: referenceDate,
                deadline: newestEnd?.deadline,
                newestAnalyzed: &newestAnalyzed,
                readMarkerSeen: &readMarkerSeen,
                deadlineHit: &analysisDeadlineHit
            )
            // Past the deadline the row search, which has no deadline, would only run longer;
            // return what was read, even nothing.
            if tableMessages.count >= min(limit, Self.minimumTableMessages(limit: limit)) || analysisDeadlineHit {
                return TranscriptSnapshot(
                    chat: chatWindow.title ?? fallbackChatTitle,
                    fetchedAt: referenceDate,
                    messages: tableMessages,
                    newestReached: newestEnd == nil ? nil : judgeNewestReached(
                        newestOutcome,
                        analyzedNewest: newestAnalyzed,
                        analysisDeadlineHit: analysisDeadlineHit,
                        readMarkerSeen: readMarkerSeen
                    )
                )
            }
            runner.log("read: table path gave \(tableMessages.count) message(s); falling back to row search")
        }

        let frameCache = FrameCache()
        let messageRows = collectTranscriptRows(
            from: context.transcriptRoot,
            inputElement: context.inputElement,
            messageLimit: limit,
            frameCache: frameCache
        )
        guard !messageRows.isEmpty else {
            throw TranscriptReadError.noMessageRows
        }

        let displayMessages = extractMessages(
            from: messageRows,
            transcriptRoot: context.transcriptRoot,
            limit: limit,
            includeSystemMessages: includeSystemMessages,
            referenceDate: referenceDate,
            frameCache: frameCache,
            newestAnalyzed: &newestAnalyzed,
            readMarkerSeen: &readMarkerSeen
        )
        guard !displayMessages.isEmpty else {
            throw TranscriptReadError.noReadableMessages
        }

        return TranscriptSnapshot(
            chat: chatWindow.title ?? fallbackChatTitle,
            fetchedAt: referenceDate,
            messages: displayMessages,
            newestReached: newestEnd == nil ? nil : judgeNewestReached(
                newestOutcome,
                analyzedNewest: newestAnalyzed,
                analysisDeadlineHit: analysisDeadlineHit,
                readMarkerSeen: readMarkerSeen
            )
        )
    }

    private func collectTranscriptRows(
        from transcriptRoot: UIElement,
        inputElement: UIElement,
        messageLimit: Int,
        frameCache: FrameCache
    ) -> [UIElement] {
        let targetRowCount = max(messageLimit * 4, 50)
        var rows: [UIElement] = []

        rows.append(contentsOf: directRowChildren(from: transcriptRoot))

        let containerCandidates = transcriptRoot.findAll(where: { element in
            guard let role = element.role else { return false }
            return role == kAXTableRole || role == kAXOutlineRole || role == kAXListRole || role == kAXScrollAreaRole
        }, limit: 8, maxNodes: 900)

        for container in containerCandidates {
            rows.append(contentsOf: directRowChildren(from: container))
        }

        if rows.count < targetRowCount {
            let bfsRows = transcriptRoot.findAll(
                role: kAXRowRole,
                limit: max(targetRowCount * 3, 240),
                maxNodes: 3_000
            )
            rows.append(contentsOf: bfsRows)
        }

        if rows.isEmpty {
            let cells = transcriptRoot.findAll(role: kAXCellRole, limit: max(targetRowCount * 2, 160), maxNodes: 2_000)
            rows.append(contentsOf: cells.compactMap(\.parent))
        }

        let deduplicated = deduplicateElements(rows)
        var filtered = deduplicated
        if let inputFrame = inputElement.frame {
            filtered = deduplicated.filter { row in
                guard let rowFrame = frameCache.frame(of: row) else { return true }
                return rowFrame.maxY <= inputFrame.minY + 20
            }
        }

        let sorted = filtered.sorted { lhs, rhs in
            let lhsY = frameCache.frame(of: lhs)?.minY ?? .greatestFiniteMagnitude
            let rhsY = frameCache.frame(of: rhs)?.minY ?? .greatestFiniteMagnitude
            if lhsY == rhsY {
                let lhsX = frameCache.frame(of: lhs)?.minX ?? .greatestFiniteMagnitude
                let rhsX = frameCache.frame(of: rhs)?.minX ?? .greatestFiniteMagnitude
                return lhsX < rhsX
            }
            return lhsY < rhsY
        }

        let recentWindow = max(messageLimit * 6, 80)
        let recentRows = Array(sorted.suffix(recentWindow))
        runner.log("read: transcript rows raw=\(rows.count), unique=\(deduplicated.count), filtered=\(sorted.count), recent=\(recentRows.count)")
        return recentRows
    }

    private func extractMessages(
        from rows: [UIElement],
        transcriptRoot: UIElement,
        limit: Int,
        includeSystemMessages: Bool,
        referenceDate: Date,
        frameCache: FrameCache,
        newestAnalyzed: inout OwnTimeLabel?,
        readMarkerSeen: inout Bool
    ) -> [TranscriptMessage] {
        let analysisBudget = max(limit * 5, 60)
        let rowsToAnalyze = Array(rows.suffix(analysisBudget))
        let analyses = rowsToAnalyze.map {
            analyzeRow($0, transcriptRoot: transcriptRoot, referenceDate: referenceDate, frameCache: frameCache)
        }
        newestAnalyzed = Self.newestOwnLabel(newestFirst: analyses.reversed())
        readMarkerSeen = readMarkerSeen || Self.containsReadMarker(analyses)

        var messages = buildMessages(
            from: analyses,
            limit: limit,
            includeSystemMessages: includeSystemMessages,
            referenceDate: referenceDate
        ).map(\.message)

        runner.log("read: row parser messages=\(messages.count)")

        if messages.isEmpty || messages.count < max(3, min(limit / 2, 8)) {
            let fallback = extractFallbackMessages(from: transcriptRoot, limit: limit, referenceDate: referenceDate)
            runner.log("read: fallback messages=\(fallback.count)")
            messages.append(contentsOf: fallback)
        }

        return Array(deduplicateMessagesPreservingOrder(messages).suffix(limit))
    }

    /// Forward pass that turns row analyses (oldest first) into messages, carrying
    /// author/time/date anchors across rows. Each message keeps its analysis index.
    private func buildMessages(
        from analyses: [RowAnalysis],
        limit: Int,
        includeSystemMessages: Bool,
        referenceDate: Date
    ) -> [IndexedTranscriptMessage] {
        var messages: [IndexedTranscriptMessage] = []
        messages.reserveCapacity(min(analyses.count, limit * 2))
        var selectedLogs = 0
        var skippedLogs = 0
        var lastKnownTime: String?
        var lastTimeBySide: [MessageSide: String] = [:]
        var leftAnchorAuthor: String?
        var leftAnchorTimeRaw: String?
        var currentDateAnchor: Date?
        // AXHelp tooltip date ("YYYY-MM-DD") carried forward so consecutive
        // messages that share a single time label inherit the same day.
        var lastKnownDate: String?

        for (offset, analysis) in analyses.enumerated() {
            let side = analysis.side
            if side != .left || analysis.isSystemLikeRow {
                leftAnchorAuthor = nil
                leftAnchorTimeRaw = nil
            }

            if side == .left,
               let explicitAuthor = analysis.explicitAuthor,
               !analysis.isSystemLikeRow
            {
                leftAnchorAuthor = explicitAuthor
                leftAnchorTimeRaw = analysis.timeRaw
            }

            guard let bodyCandidate = analysis.bodyCandidate else {
                if skippedLogs < 10 {
                    if analysis.isSystemLikeRow {
                        runner.log("read: row[\(offset + 1)] skipped (system row)")
                    } else {
                        runner.log("read: row[\(offset + 1)] skipped (no body text)")
                    }
                    skippedLogs += 1
                }
                continue
            }

            if let parsedDate = parseSystemDate(from: bodyCandidate.body, relativeTo: referenceDate) {
                currentDateAnchor = parsedDate
            }

            if analysis.isSystemLikeRow, !includeSystemMessages {
                if skippedLogs < 10 {
                    runner.log("read: row[\(offset + 1)] skipped (system-like content)")
                    skippedLogs += 1
                }
                continue
            }

            if let axHelpDate = analysis.axHelpDate {
                lastKnownDate = axHelpDate
            }
            let resolvedDate = analysis.axHelpDate ?? lastKnownDate

            if analysis.isSystemLikeRow {
                let message = TranscriptMessage(
                    author: nil,
                    timeRaw: analysis.timeRaw,
                    body: bodyCandidate.body,
                    imageCount: analysis.imageCount,
                    linkCount: analysis.linkCount,
                    attachmentCount: analysis.attachmentCount,
                    isSystem: true,
                    logicalTimestamp: currentDateAnchor,
                    date: resolvedDate
                )
                messages.append(IndexedTranscriptMessage(analysisIndex: offset, message: message))
                continue
            }

            let resolvedAuthor = resolveAuthorInSegment(
                analysis: analysis,
                leftAnchorAuthor: leftAnchorAuthor,
                leftAnchorTimeRaw: leftAnchorTimeRaw
            )
            let author = resolvedAuthor.author

            let resolvedTime: String?
            if let explicitTime = analysis.timeRaw {
                resolvedTime = explicitTime
                lastKnownTime = explicitTime
                if side != .unknown {
                    lastTimeBySide[side] = explicitTime
                }
            } else if side != .unknown, let sideTime = lastTimeBySide[side] {
                resolvedTime = sideTime
            } else {
                resolvedTime = lastKnownTime
            }

            let message = TranscriptMessage(
                author: author,
                timeRaw: resolvedTime,
                body: bodyCandidate.body,
                imageCount: analysis.imageCount,
                linkCount: analysis.linkCount,
                attachmentCount: analysis.attachmentCount,
                isSystem: false,
                logicalTimestamp: logicalTimestamp(
                    for: resolvedTime,
                    dateAnchor: currentDateAnchor,
                    referenceDate: referenceDate
                ),
                date: resolvedDate
            )
            messages.append(IndexedTranscriptMessage(analysisIndex: offset, message: message))
            if selectedLogs < 10 {
                runner.log(
                    "read: row[\(offset + 1)] side=\(side.rawValue) author='\(author ?? "(me)")' source=\(resolvedAuthor.source) time='\(resolvedTime ?? "unknown")' body='\(bodyCandidate.body.prefix(60))'"
                )
                selectedLogs += 1
            }
        }

        return messages
    }

    private func directRowChildren(from element: UIElement) -> [UIElement] {
        element.children.filter { $0.role == kAXRowRole }
    }

    private func analyzeRow(
        _ row: UIElement,
        transcriptRoot: UIElement,
        referenceDate: Date,
        frameCache: FrameCache
    ) -> RowAnalysis {
        let directCells = row.children.filter { $0.role == kAXCellRole }
        let containers = directCells.isEmpty ? [row] : directCells

        var bodyCandidates: [MessageBodyCandidate] = []
        var metadataTokensBuffer: [String] = []
        var buttonTitlesBuffer: [String] = []
        var imageFrames: [CGRect] = []
        var rowHelpDate: String?
        var labelDate: String?
        var labelTime: String?
        var linkElementCount = 0
        var urlTokenCount = 0
        var hasContent = false

        for container in containers {
            var textAreas: [UIElement] = []
            var staticTexts: [UIElement] = []
            var images: [UIElement] = []
            var buttons: [UIElement] = []
            var links: [UIElement] = []

            for child in container.children {
                switch child.role {
                case kAXTextAreaRole:
                    textAreas.append(child)
                case kAXStaticTextRole:
                    staticTexts.append(child)
                case kAXImageRole:
                    images.append(child)
                case kAXButtonRole:
                    buttons.append(child)
                case kAXLinkRole:
                    links.append(child)
                default:
                    break
                }
            }

            let missingRoles = [
                textAreas.isEmpty ? kAXTextAreaRole : nil,
                staticTexts.isEmpty ? kAXStaticTextRole : nil,
                images.isEmpty ? kAXImageRole : nil,
                buttons.isEmpty ? kAXButtonRole : nil,
                links.isEmpty ? kAXLinkRole : nil,
            ].compactMap { $0 }

            if !missingRoles.isEmpty {
                let found = container.findAll(
                    roles: Set(missingRoles),
                    roleLimits: [
                        kAXTextAreaRole: 4,
                        kAXStaticTextRole: 8,
                        kAXImageRole: 3,
                        kAXButtonRole: 6,
                        kAXLinkRole: 6,
                    ],
                    maxNodes: 140
                )
                if textAreas.isEmpty { textAreas = found[kAXTextAreaRole] ?? [] }
                if staticTexts.isEmpty { staticTexts = found[kAXStaticTextRole] ?? [] }
                if images.isEmpty { images = found[kAXImageRole] ?? [] }
                if buttons.isEmpty { buttons = found[kAXButtonRole] ?? [] }
                if links.isEmpty { links = found[kAXLinkRole] ?? [] }
            }

            if !(textAreas.isEmpty && staticTexts.isEmpty && images.isEmpty && buttons.isEmpty && links.isEmpty) {
                hasContent = true
            }

            for staticText in staticTexts {
                let rawValue = staticText.stringValue
                let ownTime = TranscriptTime.timeLabel(rawValue)
                let help = (rowHelpDate == nil || (labelTime == nil && ownTime != nil)) ? staticText.helpText : nil
                if rowHelpDate == nil, let help, let parsed = Self.parseHelpDate(help) {
                    rowHelpDate = parsed
                }
                // The message's own time label: its text is a bare time and its AXHelp is the date.
                if labelTime == nil, let ownTime, let help, let parsed = Self.parseHelpDate(help) {
                    labelTime = ownTime
                    labelDate = parsed
                }
                let normalized = normalizeBodyText(rawValue)
                guard !normalized.isEmpty else { continue }
                metadataTokensBuffer.append(contentsOf: metadataTokens(from: normalized))
                urlTokenCount += countURLTokens(in: normalized)
            }

            for button in buttons {
                let title = normalizeBodyText(button.title)
                guard !title.isEmpty else { continue }
                buttonTitlesBuffer.append(title)
                urlTokenCount += countURLTokens(in: title)
            }

            for image in images {
                if let frame = image.frame {
                    imageFrames.append(frame)
                }
            }

            linkElementCount += links.count

            for textArea in textAreas {
                let normalized = normalizeBodyText(textArea.stringValue)
                guard !normalized.isEmpty else { continue }
                urlTokenCount += countURLTokens(in: normalized)

                var resolved = normalized
                if shouldPromoteLinkTitle(for: normalized),
                   let fullLink = bestLinkTitle(from: textArea) ?? bestLinkTitle(from: container)
                {
                    if isURLOnlyText(normalized) {
                        resolved = fullLink
                    } else if !normalized.contains(fullLink) {
                        resolved = "\(normalized)\n\(fullLink)"
                    }
                    runner.log("read: link title used as fallback")
                }

                bodyCandidates.append(MessageBodyCandidate(body: resolved, frame: textArea.frame))
            }

            if textAreas.isEmpty, let linkOnlyText = bestLinkTitle(from: container) {
                bodyCandidates.append(MessageBodyCandidate(body: linkOnlyText, frame: container.frame))
                linkElementCount = max(linkElementCount, 1)
            }
        }

        let bestBody = deduplicateBodyCandidates(bodyCandidates).max { lhs, rhs in
            scoreBodyCandidate(lhs.body) < scoreBodyCandidate(rhs.body)
        }

        let uniqueMetadataTokens = deduplicatePreservingOrder(metadataTokensBuffer)
        let uniqueButtonTitles = deduplicatePreservingOrder(buttonTitlesBuffer)
        let metadata = parseRowMetadata(tokens: metadataTokensBuffer)
        let cachedRowFrame = frameCache.frame(of: row)
        let messageImageFrames = likelyMessageImageFrames(
            imageFrames,
            bodyFrame: bestBody?.frame,
            textFrames: bodyCandidates.compactMap(\.frame),
            rowFrame: cachedRowFrame
        )
        let imageCount = messageImageFrames.count
        let attachmentMetadataCount = uniqueMetadataTokens.filter(isLikelyAttachmentMetadataToken).count
        let attachmentActionCount = uniqueButtonTitles.filter(isLikelyAttachmentButtonTitle).count
        // Attachments are non-image files; images are reported separately via imageCount.
        let attachmentCount = attachmentMetadataCount + attachmentActionCount
        let side = inferMessageSide(
            bodyFrame: bestBody?.frame,
            imageFrames: imageFrames,
            rowFrame: cachedRowFrame,
            transcriptRoot: transcriptRoot
        )
        let systemLikeRow = isLikelySystemRow(
            metadataTokens: uniqueMetadataTokens,
            buttonTitles: uniqueButtonTitles,
            bodyCandidate: bestBody,
            referenceDate: referenceDate
        )
        return RowAnalysis(
            bodyCandidate: bestBody,
            explicitAuthor: metadata.author,
            timeRaw: metadata.timeRaw,
            side: side,
            rowFrame: cachedRowFrame,
            imageCount: imageCount,
            linkCount: max(linkElementCount, urlTokenCount),
            attachmentCount: attachmentCount,
            isSystemLikeRow: systemLikeRow,
            axHelpDate: rowHelpDate,
            labelDate: labelDate,
            labelTime: labelTime,
            hasContent: hasContent
        )
    }

    private func extractFallbackMessages(from transcriptRoot: UIElement, limit: Int, referenceDate: Date) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        let textAreas = transcriptRoot.findAll(role: kAXTextAreaRole, limit: max(limit * 80, 1_200), maxNodes: 6_000)
        let recentTextAreas = Array(sortElementsByReadingOrder(textAreas).suffix(max(limit * 20, 240)))
        for textArea in recentTextAreas {
            let normalized = normalizeBodyText(textArea.stringValue)
            guard !normalized.isEmpty else { continue }

            var resolved = normalized
            if shouldPromoteLinkTitle(for: normalized), let fullLink = bestLinkTitle(from: textArea) {
                if isURLOnlyText(normalized) {
                    resolved = fullLink
                } else if !normalized.contains(fullLink) {
                    resolved = "\(normalized)\n\(fullLink)"
                }
                runner.log("read: fallback link title used")
            }
            let row = firstAncestor(of: textArea, role: kAXRowRole, maxHops: 6)
            let metadata = row.map { extractRowMetadata(from: $0) } ?? RowMetadata(author: nil, timeRaw: nil)
            messages.append(
                TranscriptMessage(
                    author: metadata.author,
                    timeRaw: metadata.timeRaw,
                    body: resolved,
                    linkCount: countURLTokens(in: resolved),
                    isSystem: false,
                    logicalTimestamp: logicalTimestamp(
                        for: metadata.timeRaw,
                        dateAnchor: nil,
                        referenceDate: referenceDate
                    ),
                    date: row.flatMap { axHelpDate(in: $0) }
                )
            )
        }

        if messages.isEmpty {
            let links = transcriptRoot.findAll(where: { $0.role == kAXLinkRole }, limit: max(limit * 40, 320), maxNodes: 4_000)
            let recentLinks = Array(sortElementsByReadingOrder(links).suffix(max(limit * 10, 80)))
            for link in recentLinks {
                let title = normalizeBodyText(link.title ?? link.stringValue)
                if !title.isEmpty {
                    messages.append(
                        TranscriptMessage(
                            author: nil,
                            timeRaw: nil,
                            body: title,
                            linkCount: max(1, countURLTokens(in: title)),
                            isSystem: false,
                            logicalTimestamp: nil,
                            date: nil
                        )
                    )
                }
            }
        }

        return Array(deduplicateMessagesPreservingOrder(messages).suffix(limit))
    }

    private func extractRowMetadata(from row: UIElement) -> RowMetadata {
        let cells = row.findAll(role: kAXCellRole, limit: 8, maxNodes: 180)
        let containers = cells.isEmpty ? [row] : cells

        var tokens: [String] = []
        for container in containers {
            let staticTexts = container.findAll(role: kAXStaticTextRole, limit: 12, maxNodes: 240)
            for staticText in staticTexts {
                let normalized = normalizeBodyText(staticText.stringValue)
                guard !normalized.isEmpty else { continue }
                tokens.append(contentsOf: metadataTokens(from: normalized))
            }
        }

        return parseRowMetadata(tokens: tokens)
    }

    private func parseRowMetadata(tokens: [String]) -> RowMetadata {
        let uniqueTokens = deduplicatePreservingOrder(tokens)
        var author: String?
        var timeRaw: String?

        for token in uniqueTokens {
            if let parsedTime = extractTimeToken(from: token) {
                timeRaw = parsedTime
                continue
            }

            if isLikelyCountToken(token)
                || isLikelySystemMetadataToken(token)
                || isLikelyAttachmentMetadataToken(token)
            {
                continue
            }

            if author == nil {
                author = token
            }
        }

        return RowMetadata(author: author, timeRaw: timeRaw)
    }

    private func metadataTokens(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func extractTimeToken(from token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let meridiemRange = trimmed.range(
            of: #"(오전|오후)\s*([1-9]|1[0-2]):[0-5][0-9]"#,
            options: .regularExpression
        ) {
            return String(trimmed[meridiemRange])
        }

        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        for part in parts {
            let normalized = String(part).trimmingCharacters(in: .punctuationCharacters)
            if normalized.range(
                of: #"^([01]?[0-9]|2[0-3]):[0-5][0-9]$"#,
                options: .regularExpression
            ) != nil {
                return normalized
            }
        }

        return nil
    }

    private func isLikelyCountToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private func isLikelySystemMetadataToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^\d{4}[./-]\d{1,2}[./-]\d{1,2}"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^\d{1,2}월\s*\d{1,2}일"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private func isLikelyAttachmentMetadataToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("expiry") || lowered.hasPrefix("size:") {
            return true
        }
        if lowered.contains("만료") || lowered.contains("용량") {
            return true
        }
        if trimmed == "·" {
            return true
        }
        if lowered.range(
            of: #"\.(pdf|png|jpe?g|gif|webp|zip|hwp|docx?|pptx?|xlsx?)$"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return false
    }

    private func isLikelyAttachmentButtonTitle(_ title: String) -> Bool {
        let lowered = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        if lowered == "save" || lowered == "save as" {
            return true
        }
        if lowered == "저장" || lowered == "다른 이름으로 저장" {
            return true
        }
        return false
    }

    private func likelyMessageImageFrames(
        _ imageFrames: [CGRect],
        bodyFrame: CGRect?,
        textFrames: [CGRect],
        rowFrame: CGRect?
    ) -> [CGRect] {
        imageFrames.filter { frame in
            isLikelyMessageImageFrame(
                frame,
                bodyFrame: bodyFrame,
                textFrames: textFrames,
                rowFrame: rowFrame
            )
        }
    }

    /// Judged from the row's own geometry only, so the answer does not depend on which
    /// rows the transcript is scrolled to.
    private func isLikelyMessageImageFrame(
        _ frame: CGRect,
        bodyFrame: CGRect?,
        textFrames: [CGRect],
        rowFrame: CGRect?
    ) -> Bool {
        guard frame.width >= 48, frame.height >= 48, frame.width * frame.height >= 2_304 else {
            return false
        }

        if let bodyFrame,
           frame.maxX + 10 < bodyFrame.minX,
           frame.width <= 72,
           frame.height <= 72
        {
            return false
        }

        if let rowFrame, !rowFrame.intersects(frame) {
            return false
        }

        // A text message's bubble background is an AXImage drawn around the message text.
        let bubbleBounds = frame.insetBy(dx: -2, dy: -2)
        if textFrames.contains(where: { bubbleBounds.contains($0) }) {
            return false
        }

        return true
    }

    private func isLikelySystemRow(
        metadataTokens: [String],
        buttonTitles: [String],
        bodyCandidate: MessageBodyCandidate?,
        referenceDate: Date
    ) -> Bool {
        if let body = bodyCandidate?.body, parseSystemDate(from: body, relativeTo: referenceDate) != nil {
            return true
        }
        let hasAttachmentMetadata = metadataTokens.contains(where: isLikelyAttachmentMetadataToken)
        let hasAttachmentActions = buttonTitles.contains(where: isLikelyAttachmentButtonTitle)
        if hasAttachmentMetadata && hasAttachmentActions {
            return true
        }
        if bodyCandidate == nil && (hasAttachmentMetadata || hasAttachmentActions) {
            return true
        }
        return false
    }

    private func inferMessageSide(
        bodyFrame: CGRect?,
        imageFrames: [CGRect],
        rowFrame: CGRect?,
        transcriptRoot: UIElement
    ) -> MessageSide {
        if let bodyF = bodyFrame {
            for imageFrame in imageFrames {
                if imageFrame.midX + 10 < bodyF.minX {
                    return .left
                }
                if imageFrame.midX > bodyF.maxX + 10 {
                    return .right
                }
            }
        }

        let referenceFrame = bodyFrame ?? rowFrame
        guard let candidateFrame = referenceFrame, let transcriptFrame = transcriptRoot.frame else {
            return .unknown
        }

        let ratio = (candidateFrame.midX - transcriptFrame.minX) / max(transcriptFrame.width, 1)
        if ratio <= 0.56 {
            return .left
        }
        if ratio >= 0.62 {
            return .right
        }
        return .unknown
    }

    private func resolveAuthorInSegment(
        analysis: RowAnalysis,
        leftAnchorAuthor: String?,
        leftAnchorTimeRaw: String?
    ) -> (author: String?, source: String) {
        if let explicitAuthor = analysis.explicitAuthor {
            return (explicitAuthor, "explicit")
        }

        if analysis.side == .right || analysis.side == .unknown {
            return (nil, "default-me")
        }

        guard let anchorAuthor = leftAnchorAuthor else {
            return (nil, "left-unresolved")
        }

        guard isForwardTimeProgress(anchorTimeRaw: leftAnchorTimeRaw, candidateTimeRaw: analysis.timeRaw) else {
            return (nil, "left-time-guard")
        }

        return (anchorAuthor, "left-chain")
    }

    private func isForwardTimeProgress(anchorTimeRaw: String?, candidateTimeRaw: String?) -> Bool {
        guard
            let anchorMinutes = minuteOfDay(from: anchorTimeRaw),
            let candidateMinutes = minuteOfDay(from: candidateTimeRaw)
        else {
            return true
        }

        return candidateMinutes >= anchorMinutes
    }

    private func minuteOfDay(from timeRaw: String?) -> Int? {
        TranscriptTime.minuteOfDay(from: timeRaw)
    }

    private func logicalTimestamp(for timeRaw: String?, dateAnchor: Date?, referenceDate: Date) -> Date? {
        guard let messageMinuteOfDay = minuteOfDay(from: timeRaw) else {
            return nil
        }

        let calendar = Calendar.current
        if let dateAnchor {
            let startOfDay = calendar.startOfDay(for: dateAnchor)
            return calendar.date(byAdding: .minute, value: messageMinuteOfDay, to: startOfDay)
        }

        guard let referenceMinuteOfDay = minuteOfDay(from: formattedTime(from: referenceDate)),
              messageMinuteOfDay <= referenceMinuteOfDay
        else {
            return nil
        }

        let startOfDay = calendar.startOfDay(for: referenceDate)
        return calendar.date(byAdding: .minute, value: messageMinuteOfDay, to: startOfDay)
    }

    private func formattedTime(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else {
            return ""
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    private func parseSystemDate(from text: String, relativeTo referenceDate: Date) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let calendar = Calendar.current
        let normalized = trimmed
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "/", with: "-")

        if let match = normalized.range(
            of: #"^(\d{4})-(\d{1,2})-(\d{1,2})(?:\s+\S+)?$"#,
            options: .regularExpression
        ) {
            let token = String(normalized[match])
            let parts = token.split(whereSeparator: { $0 == "-" || $0 == " " })
            guard parts.count >= 3,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let day = Int(parts[2])
            else {
                return nil
            }
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }

        if let match = trimmed.range(
            of: #"^(\d{1,2})월\s*(\d{1,2})일(?:\s+\S+)?$"#,
            options: .regularExpression
        ) {
            let token = String(trimmed[match])
            let numbers = token
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            guard numbers.count >= 2 else {
                return nil
            }

            let referenceYear = calendar.component(.year, from: referenceDate)
            let month = numbers[0]
            let day = numbers[1]
            guard var candidate = calendar.date(from: DateComponents(year: referenceYear, month: month, day: day)) else {
                return nil
            }

            if candidate.timeIntervalSince(referenceDate) > 86_400 * 2,
               let adjusted = calendar.date(byAdding: .year, value: -1, to: candidate)
            {
                candidate = adjusted
            }

            return candidate
        }

        return nil
    }

    /// Parse the AXHelp tooltip KakaoTalk attaches to a message's time label,
    /// e.g. "2026. 6. 2." -> "2026-06-02".
    private static func parseHelpDate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.range(
            of: #"(\d{4})\.\s*(\d{1,2})\.\s*(\d{1,2})\.?"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let numbers = trimmed[match]
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        guard numbers.count >= 3 else { return nil }
        return String(format: "%04d-%02d-%02d", numbers[0], numbers[1], numbers[2])
    }

    /// Scan a row's static texts for the first AXHelp date tooltip.
    /// Used by the fallback message path, which lacks the per-row analysis.
    private func axHelpDate(in row: UIElement) -> String? {
        let staticTexts = row.findAll(role: kAXStaticTextRole, limit: 12, maxNodes: 240)
        for staticText in staticTexts {
            if let help = staticText.helpText, let parsed = Self.parseHelpDate(help) {
                return parsed
            }
        }
        return nil
    }

    private func firstAncestor(of element: UIElement, role: String, maxHops: Int) -> UIElement? {
        var cursor: UIElement? = element
        var hops = 0

        while let current = cursor, hops <= maxHops {
            if current.role == role {
                return current
            }
            cursor = current.parent
            hops += 1
        }

        return nil
    }

    private func bestLinkTitle(from element: UIElement) -> String? {
        let links = element.findAll(where: { $0.role == kAXLinkRole }, limit: 4, maxNodes: 120)
        let titles = links.compactMap { link in
            normalizeBodyText(link.title ?? link.stringValue)
        }
        .filter { !$0.isEmpty }

        return titles.max { lhs, rhs in lhs.count < rhs.count }
    }

    private func normalizeBodyText(_ text: String?) -> String {
        guard let text else { return "" }
        let canonical = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = canonical
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let joined = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return joined
    }

    private func deduplicatePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(values.count)

        for value in values {
            guard !value.isEmpty else { continue }
            if seen.contains(value) { continue }
            seen.insert(value)
            unique.append(value)
        }

        return unique
    }

    private func deduplicateBodyCandidates(_ candidates: [MessageBodyCandidate]) -> [MessageBodyCandidate] {
        var seen = Set<String>()
        var unique: [MessageBodyCandidate] = []
        unique.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard !candidate.body.isEmpty else { continue }
            if seen.contains(candidate.body) { continue }
            seen.insert(candidate.body)
            unique.append(candidate)
        }

        return unique
    }

    private func deduplicateMessagesPreservingOrder(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
        var seen = Set<String>()
        var unique: [TranscriptMessage] = []
        unique.reserveCapacity(messages.count)

        for message in messages {
            let key = messageFingerprint(message)
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(message)
        }

        return unique
    }

    private func shouldPromoteLinkTitle(for text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("http://") || lower.contains("https://") else { return false }
        return text.contains("...")
    }

    private func isURLOnlyText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://\S+"#)

    private func countURLTokens(in text: String) -> Int {
        let range = NSRange(text.startIndex..., in: text)
        return Self.urlRegex.numberOfMatches(in: text, range: range)
    }

    private func scoreBodyCandidate(_ text: String) -> Int {
        var score = min(text.count * 10, 500)
        if text.contains("\n") {
            score += 60
        }
        if text.contains(" ") {
            score += 40
        }
        let lower = text.lowercased()
        if lower.contains("http://") || lower.contains("https://") {
            score += 180
        }
        return score
    }

    private func deduplicateElements(_ elements: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        unique.reserveCapacity(elements.count)

        var buckets: [CFHashCode: [UIElement]] = [:]
        for element in elements {
            let hash = CFHash(element.axElement)
            let alreadySeen = buckets[hash]?.contains(where: { existing in
                CFEqual(existing.axElement, element.axElement)
            }) ?? false
            if alreadySeen {
                continue
            }
            buckets[hash, default: []].append(element)
            unique.append(element)
        }

        return unique
    }

    private func sortElementsByReadingOrder(_ elements: [UIElement]) -> [UIElement] {
        elements.sorted { lhs, rhs in
            let lhsY = lhs.frame?.minY ?? .greatestFiniteMagnitude
            let rhsY = rhs.frame?.minY ?? .greatestFiniteMagnitude
            if lhsY == rhsY {
                let lhsX = lhs.frame?.minX ?? .greatestFiniteMagnitude
                let rhsX = rhs.frame?.minX ?? .greatestFiniteMagnitude
                return lhsX < rhsX
            }
            return lhsY < rhsY
        }
    }
}

// MARK: - Time-bounded read (`read --since`)

struct TranscriptHistoryInfo: Sendable {
    let since: Date
    let pagesLoaded: Int
    /// The transcript stopped growing when paged up, i.e. the conversation start is loaded.
    let oldestReached: Bool
    /// The range back to `since` was not fully covered (page cap, time budget,
    /// disallowed page-up), `limit` dropped older messages, or the newest end was not
    /// confirmed loaded.
    let truncated: Bool
    /// Why the read ended; `.complete` exactly when `truncated` is false.
    let stopReason: TranscriptStopReason
}

enum TranscriptStopReason: String, Sendable, Encodable {
    case complete
    case pageCap = "page_cap"
    case deadline
    case limit
    /// The range back to `since` is covered, but the newest end was not confirmed loaded.
    case newestUnreached = "newest_unreached"
    case scrollFailed = "scroll_failed"
    /// Rows back to `since` were loaded but came back without content or time labels.
    case rowsUnreadable = "rows_unreadable"
    /// Older history could not be paged in (background-safe mode, no scrollable table).
    case pagingUnavailable = "paging_unavailable"
}

struct TranscriptSinceSnapshot: Sendable {
    let snapshot: TranscriptSnapshot
    let history: TranscriptHistoryInfo
}

private enum LoadedEdgeTime {
    case exact(Date)
    case day(Date)
}

private enum PagingStop {
    case edgeOlder
    case conversationStart
    case pageCap
    case deadline
    case scrollFailed
    case rowCountUnreadable
    case unavailable
}

private struct HistoryLoadOutcome {
    var pagesLoaded = 0
    var oldestReached = false
    var capped = false
    var stop: PagingStop = .unavailable
    /// Set once the transcript was scrolled up; the caller restores it after reading rows.
    var scrolledBar: UIElement?
}

/// How a recent-N read loads and judges the newest end of the conversation.
struct NewestEndOptions: Sendable {
    /// Cap on downward loads, separate from the older-history pages.
    let maxLoads: Int
    /// End of the whole read; loading stops earlier to leave time for reading rows.
    let deadline: Date
}

private struct OwnTimeLabel: Equatable {
    let date: String
    let time: String
}

private enum NewestEndStop: String {
    /// Scrolling to the bottom loaded nothing more.
    case unchanged
    case deadline
    case pageCap = "page_cap"
    case scrollFailed = "scroll_failed"
    /// The whole conversation fits; nothing below to load.
    case noScrollBar = "no_scroll_bar"
    /// A recent-N read whose initial table showed no sign of unloaded newer rows.
    case notSuspect = "not_suspect"
    /// No scroll area or readable row count.
    case unavailable
}

private struct NewestEndOutcome {
    var stop: NewestEndStop = .unavailable
    var loads = 0
    var scrollValue: Double?
    /// The newest own time label in the table when the stage stopped.
    var lastLabel: OwnTimeLabel?
}

extension KakaoTalkTranscriptReader {
    private static let pageGrowthTimeout: TimeInterval = 3.0
    /// Upper bound on each wait for a downward load to show; per-load latency is not pinned yet.
    private static let newestLoadTimeout: TimeInterval = pageGrowthTimeout
    /// Part of a recent-N read's budget kept for reading rows after the loading stage.
    private static let recentReadReserve: TimeInterval = 1.5
    private static let readMarkerText = "여기까지읽었습니다"
    private static let pagePollInterval: TimeInterval = 0.15
    private static let peekRowCount = 12
    private static let anchorContextRows = 8
    /// A lone empty row is KakaoTalk's spacer at either end; a longer stretch is unread content.
    private static let emptyStretchMinRows = 2

    /// Reads every message at or after `since`, paging older history into the
    /// transcript table first. Messages are returned oldest first; at most `limit`
    /// (newest) are kept.
    func readSince(
        from window: UIElement,
        fallbackChatTitle: String,
        since: Date,
        limit: Int,
        maxPages: Int,
        deadline: Date,
        allowPaging: Bool
    ) throws -> TranscriptSinceSnapshot {
        let referenceDate = Date()
        let sinceMinute = TranscriptTime.minuteFloor(since)
        let messageContextResolver = MessageContextResolver(
            kakao: kakao,
            runner: runner,
            interactionMode: interactionMode
        )
        guard let context = messageContextResolver.resolve(in: window) else {
            throw TranscriptReadError.transcriptContextUnavailable
        }

        let table = transcriptTable(in: context.transcriptRoot)
        var outcome = HistoryLoadOutcome()
        // nil: the newest end was not checked (background-safe or no table).
        var newestOutcome: NewestEndOutcome?
        if allowPaging, let table {
            // Leave half of the remaining budget for row analysis, which dominates the cost.
            let pagingBudget = max(0, deadline.timeIntervalSinceNow) / 2
            let pagingDeadline = Date().addingTimeInterval(pagingBudget)
            // The newest end takes half of the paging share, but at least one full confirm
            // wait when the share allows it; paging up then uses what is left.
            let newestBudget = max(pagingBudget / 2, min(pagingBudget, Self.newestLoadTimeout + 0.5))
            newestOutcome = loadNewestEnd(
                table: table,
                transcriptRoot: context.transcriptRoot,
                maxLoads: maxPages,
                deadline: min(Date().addingTimeInterval(newestBudget), pagingDeadline)
            )
            outcome = loadHistory(
                table: table,
                transcriptRoot: context.transcriptRoot,
                sinceMinute: sinceMinute,
                maxPages: maxPages,
                deadline: pagingDeadline
            )
        } else if allowPaging {
            runner.log("read-since: transcript table unavailable; reading loaded rows only")
        }
        // Rows are read before the scroll position is restored: back at the bottom,
        // KakaoTalk at times hands out the oldest loaded rows without any content.
        let scrolledBar = outcome.scrolledBar
        defer {
            if let scrolledBar {
                scrollToBottom(scrolledBar)
            }
        }

        // Analyze newest first and stop once a row is provably older than `since`,
        // then a few more rows so the forward pass has an author anchor.
        // Only rows with their own time label can cross `since`, and a crossing needs
        // two consecutive time-labelled rows older than `since`, so one out-of-order
        // label (e.g. a quoted or forwarded message) cannot cut the range short.
        let inputMinY = context.inputElement.frame?.minY
        var reversedAnalyses: [RowAnalysis] = []
        var crossedSince = false
        var crossReversedIndex: Int?
        var deadlineHit = false
        // Rows without any accessibility content, before `since` is crossed; the run is the
        // stretch of them at the oldest end.
        var emptyRows = 0
        var emptyRowRun = 0
        var rereadDone = false
        while true {
            let frameCache = FrameCache()
            let rows: [UIElement]
            if let table {
                rows = orderedRows(of: table, frameCache: frameCache)
            } else {
                rows = collectTranscriptRows(
                    from: context.transcriptRoot,
                    inputElement: context.inputElement,
                    messageLimit: 20,
                    frameCache: frameCache
                )
            }
            guard !rows.isEmpty else {
                throw TranscriptReadError.noMessageRows
            }
            runner.log("read-since: rows=\(rows.count) pages=\(outcome.pagesLoaded) oldestReached=\(outcome.oldestReached)")

            reversedAnalyses = []
            crossedSince = false
            crossReversedIndex = nil
            deadlineHit = false
            emptyRows = 0
            emptyRowRun = 0
            var pendingCross: Int?
            var contextRows = 0
            var rowsExhausted = true
            for row in rows.reversed() {
                if crossedSince, contextRows >= Self.anchorContextRows {
                    rowsExhausted = false
                    break
                }
                if Date() >= deadline {
                    deadlineHit = true
                    rowsExhausted = false
                    break
                }
                // Frames only place rows against the input field while the transcript sits at the bottom.
                if scrolledBar == nil, let inputMinY, let rowFrame = frameCache.frame(of: row), rowFrame.maxY > inputMinY + 20 {
                    continue
                }
                let analysis = analyzeRow(row, transcriptRoot: context.transcriptRoot, referenceDate: referenceDate, frameCache: frameCache)
                let reversedIndex = reversedAnalyses.count
                reversedAnalyses.append(analysis)
                let older = analysis.labelTimestamp.map { $0 < sinceMinute }
                if !crossedSince {
                    emptyRowRun = analysis.hasContent ? 0 : emptyRowRun + 1
                    emptyRows += analysis.hasContent ? 0 : 1
                }

                if crossedSince {
                    contextRows += 1
                } else if let older {
                    if !older {
                        pendingCross = nil
                    } else if let pending = pendingCross {
                        crossedSince = true
                        crossReversedIndex = pending
                    } else {
                        pendingCross = reversedIndex
                    }
                }
                runner.log(
                    "read-since: row[-\(reversedIndex + 1)] date=\(analysis.labelDate ?? analysis.axHelpDate ?? "-") time=\(analysis.labelTime ?? analysis.timeRaw ?? "-") ownLabel=\(analysis.labelTime != nil ? "yes" : "no") author=\(analysis.explicitAuthor != nil ? "yes" : "no") older=\(older.map { $0 ? "yes" : "no" } ?? "-") crossed=\(crossedSince ? "yes" : "no")"
                )
                if crossedSince, contextRows > 0, analysis.explicitAuthor != nil {
                    rowsExhausted = false
                    break
                }
            }
            // The oldest loaded time label is older than `since` with nothing older to confirm it.
            // Empty rows beyond it confirm nothing either way.
            if !crossedSince, rowsExhausted, emptyRowRun < Self.emptyStretchMinRows, let pending = pendingCross {
                crossedSince = true
                crossReversedIndex = pending
            }

            // Empty rows at the oldest end hide the stretch that should cross `since`:
            // scroll back up and read the rows once more before settling for a partial result.
            guard !crossedSince, !deadlineHit, emptyRowRun >= Self.emptyStretchMinRows, !rereadDone, let scrolledBar, Date() < deadline else {
                break
            }
            rereadDone = true
            runner.log("read-since: \(emptyRowRun) oldest row(s) came back empty; scrolling up and reading again")
            try? scrolledBar.setAttribute(kAXValueAttribute, value: NSNumber(value: 0.0))
            Thread.sleep(forTimeInterval: 1.0)
        }

        let analyses = Array(reversedAnalyses.reversed())
        // Time labels sit on the last row of a same-minute group, so everything after
        // the newest confirmed row older than `since` belongs to `since` or later.
        let cutIndex = crossReversedIndex.map { analyses.count - 1 - $0 }
        let indexed = buildMessages(
            from: analyses,
            limit: limit,
            includeSystemMessages: false,
            referenceDate: referenceDate
        )
        let firstKept = cutIndex.map { $0 + 1 } ?? 0
        let ownLabels = resolveOwnLabels(analyses, from: firstKept)
        var droppedBeforeSince = 0
        var messages: [TranscriptMessage] = []
        for entry in indexed where entry.analysisIndex >= firstKept {
            let label = ownLabels[entry.analysisIndex]
            if let label, let timestamp = TranscriptTime.localDate(date: label.date, timeRaw: label.time),
               timestamp < sinceMinute
            {
                droppedBeforeSince += 1
                continue
            }
            messages.append(entry.message.withDateTime(date: label?.date, timeRaw: label?.time))
        }
        if droppedBeforeSince > 0 {
            runner.log("read-since: dropped \(droppedBeforeSince) message(s) resolved before since")
        }

        var limitHit = false
        if messages.count > limit {
            messages = Array(messages.suffix(limit))
            limitHit = true
        }

        // Covered when a row older than `since` was seen, or every loaded row was
        // analyzed and the loaded rows reach back to the conversation start.
        // Empty rows at the oldest end hide whatever sits there, the conversation start included.
        let covered = crossedSince || (outcome.oldestReached && !deadlineHit && emptyRowRun < Self.emptyStretchMinRows)
        // Analysis runs newest first, so a deadline only cuts the oldest part; the label
        // comparison already fails when the newest rows were not analyzed.
        let newestReached = judgeNewestReached(
            newestOutcome,
            analyzedNewest: Self.newestOwnLabel(newestFirst: reversedAnalyses),
            analysisDeadlineHit: false,
            notCheckedReason: allowPaging ? "no_table" : "background_safe"
        )
        let truncated = limitHit || !covered || newestReached != true
        let stopReason: TranscriptStopReason
        if covered, newestReached != true {
            stopReason = .newestUnreached
        } else if covered {
            stopReason = limitHit ? .limit : .complete
        } else if deadlineHit {
            stopReason = .deadline
        } else {
            switch outcome.stop {
            case .pageCap: stopReason = .pageCap
            case .deadline: stopReason = .deadline
            case .scrollFailed: stopReason = .scrollFailed
            case .unavailable: stopReason = .pagingUnavailable
            case .edgeOlder, .conversationStart, .rowCountUnreadable: stopReason = .rowsUnreadable
            }
        }
        runner.log(
            "read-since: analyzed=\(analyses.count) messages=\(messages.count) crossed=\(crossedSince) deadlineHit=\(deadlineHit) limitHit=\(limitHit) pageCapped=\(outcome.capped) emptyRows=\(emptyRows) emptyOldestRun=\(emptyRowRun) stop=\(stopReason.rawValue)"
        )

        return TranscriptSinceSnapshot(
            snapshot: TranscriptSnapshot(
                chat: window.title ?? fallbackChatTitle,
                fetchedAt: referenceDate,
                messages: messages,
                newestReached: newestReached
            ),
            history: TranscriptHistoryInfo(
                since: since,
                pagesLoaded: outcome.pagesLoaded,
                oldestReached: outcome.oldestReached,
                truncated: truncated,
                stopReason: stopReason
            )
        )
    }

    /// Date and time for each analysis at or after `start`, from own time labels only.
    /// KakaoTalk shows the time on the last bubble of a same-minute group, so an
    /// unlabelled row takes the nearest newer labelled row; rows after the last label
    /// take the nearest older label at or after `start` (never one across the cut).
    private func resolveOwnLabels(_ analyses: [RowAnalysis], from start: Int) -> [Int: (date: String, time: String)] {
        guard start < analyses.count else { return [:] }
        var resolved: [Int: (date: String, time: String)] = [:]
        var newer: (date: String, time: String)?
        for index in stride(from: analyses.count - 1, through: start, by: -1) {
            if let date = analyses[index].labelDate, let time = analyses[index].labelTime {
                newer = (date, time)
            }
            if let newer {
                resolved[index] = newer
            }
        }
        var older: (date: String, time: String)?
        for index in start..<analyses.count {
            if let label = resolved[index] {
                if analyses[index].labelTime != nil {
                    older = label
                }
            } else if let older {
                resolved[index] = older
            }
        }
        return resolved
    }

    private func isWholeDayBefore(_ day: Date?, sinceMinute: Date) -> Bool {
        guard let day, let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) else {
            return false
        }
        return nextDay <= sinceMinute
    }

    // MARK: Paging

    private func loadHistory(
        table: UIElement,
        transcriptRoot: UIElement,
        sinceMinute: Date,
        maxPages: Int,
        deadline: Date
    ) -> HistoryLoadOutcome {
        var outcome = HistoryLoadOutcome()
        guard let scrollArea = enclosingScrollArea(of: table, transcriptRoot: transcriptRoot) else {
            runner.log("read-since: transcript scroll area unavailable; reading loaded rows only")
            return outcome
        }
        guard let scrollBarElement: AXUIElement = scrollArea.attributeOptional(kAXVerticalScrollBarAttribute) else {
            // Nothing to scroll: the whole conversation fits in the loaded rows.
            runner.log("read-since: no vertical scroll bar; treating loaded rows as complete")
            outcome.oldestReached = true
            outcome.stop = .conversationStart
            return outcome
        }
        let scrollBar = UIElement(scrollBarElement)
        guard var rowCount = rowCount(of: table), rowCount > 0 else {
            runner.log("read-since: row count unavailable; skipping page-up")
            outcome.capped = true
            outcome.stop = .rowCountUnreadable
            return outcome
        }

        while true {
            if let edge = peekOldestLoadedTime(in: table), isEdgeOlder(edge, sinceMinute: sinceMinute) {
                runner.log("read-since: oldest loaded row is older than since after \(outcome.pagesLoaded) page(s)")
                outcome.stop = .edgeOlder
                break
            }
            if outcome.pagesLoaded >= maxPages {
                runner.log("read-since: page cap reached pages=\(outcome.pagesLoaded)")
                outcome.capped = true
                outcome.stop = .pageCap
                break
            }
            if Date() >= deadline {
                runner.log("read-since: paging time budget used up pages=\(outcome.pagesLoaded)")
                outcome.capped = true
                outcome.stop = .deadline
                break
            }

            do {
                try scrollBar.setAttribute(kAXValueAttribute, value: NSNumber(value: 0.0))
                outcome.scrolledBar = scrollBar
            } catch {
                runner.log("read-since: failed to scroll transcript up: \(error)")
                outcome.capped = true
                outcome.stop = .scrollFailed
                break
            }

            let waitUntil = min(Date().addingTimeInterval(Self.pageGrowthTimeout), deadline)
            var grownCount: Int?
            var lastObserved: Int?
            while Date() < waitUntil {
                Thread.sleep(forTimeInterval: Self.pagePollInterval)
                lastObserved = self.rowCount(of: table)
                if let observed = lastObserved, observed > rowCount {
                    grownCount = observed
                    break
                }
            }

            guard let grownCount else {
                if Date() >= deadline {
                    // The wait was cut short, so an unchanged count says nothing about the start.
                    runner.log("read-since: paging time budget used up while waiting for page \(outcome.pagesLoaded + 1)")
                    outcome.capped = true
                    outcome.stop = .deadline
                } else if let lastObserved, lastObserved > 0 {
                    runner.log("read-since: row count stayed at \(lastObserved); conversation start reached")
                    outcome.oldestReached = true
                    outcome.stop = .conversationStart
                } else {
                    runner.log("read-since: row count unreadable while paging; stopping")
                    outcome.capped = true
                    outcome.stop = .rowCountUnreadable
                }
                break
            }

            outcome.pagesLoaded += 1
            runner.log("read-since: page \(outcome.pagesLoaded) rows \(rowCount) -> \(grownCount)")
            rowCount = grownCount
        }

        return outcome
    }

    private func scrollToBottom(_ scrollBar: UIElement) {
        do {
            try scrollBar.setAttribute(kAXValueAttribute, value: NSNumber(value: 1.0))
        } catch {
            runner.log("read-since: failed to restore scroll position: \(error)")
            return
        }
        let settleUntil = Date().addingTimeInterval(2.0)
        repeat {
            Thread.sleep(forTimeInterval: 0.2)
            if let value = scrollBar.value as? NSNumber, value.doubleValue >= 0.99 {
                break
            }
        } while Date() < settleUntil
    }

    private func isEdgeOlder(_ edge: LoadedEdgeTime, sinceMinute: Date) -> Bool {
        switch edge {
        case let .exact(date):
            return date < sinceMinute
        case let .day(day):
            return isWholeDayBefore(day, sinceMinute: sinceMinute)
        }
    }

    /// Cheap look at the oldest loaded rows, no body analysis. Uses only rows' own
    /// time labels (bare time text whose AXHelp is the date); the newer of the first
    /// two labels is the edge, so one out-of-order label cannot stop paging early.
    /// A date separator label counts only when no time label is found.
    private func peekOldestLoadedTime(in table: UIElement) -> LoadedEdgeTime? {
        guard let rows = tableRows(of: table) else { return nil }
        let ordered = isReversedOrder(rows, frameCache: FrameCache()) ? Array(rows.reversed()) : rows
        var labelled: [Date] = []
        var separatorDay: Date?
        for row in ordered.prefix(Self.peekRowCount) {
            for text in row.findAll(role: kAXStaticTextRole, limit: 10, maxNodes: 60) {
                let value = text.stringValue
                if let ownTime = TranscriptTime.timeLabel(value) {
                    if let help = text.helpText,
                       let date = Self.parseHelpDate(help),
                       let exact = TranscriptTime.localDate(date: date, timeRaw: ownTime)
                    {
                        labelled.append(exact)
                        break
                    }
                } else if separatorDay == nil, labelled.isEmpty, let day = TranscriptTime.separatorDay(value) {
                    separatorDay = day
                }
            }
            if labelled.count >= 2 {
                break
            }
        }
        runner.log("read-since: peek labels=\(labelled.map { SinceParser.format($0) }) separator=\(separatorDay.map { SinceParser.format($0) } ?? "-")")
        if let edge = labelled.max() {
            return .exact(edge)
        }
        if let separatorDay {
            return .day(separatorDay)
        }
        return nil
    }

    // MARK: Newest end

    /// Scrolls the transcript to the bottom until KakaoTalk loads no newer rows. A chat
    /// opened at the unread boundary holds only the rows around it, and each step to the
    /// bottom loads the next batch of newer rows. With `onlyWhenSuspect` the stage runs only
    /// when the initial table is not at the bottom or shows the read marker row.
    private func loadNewestEnd(
        table: UIElement,
        transcriptRoot: UIElement,
        maxLoads: Int,
        deadline: Date,
        onlyWhenSuspect: Bool = false
    ) -> NewestEndOutcome {
        var outcome = NewestEndOutcome()
        guard let scrollArea = enclosingScrollArea(of: table, transcriptRoot: transcriptRoot) else {
            runner.log("read-newest: transcript scroll area unavailable")
            return outcome
        }
        guard let scrollBarElement: AXUIElement = scrollArea.attributeOptional(kAXVerticalScrollBarAttribute) else {
            runner.log("read-newest: no vertical scroll bar; nothing below to load")
            outcome.stop = .noScrollBar
            return outcome
        }
        let scrollBar = UIElement(scrollBarElement)
        guard var rowCount = rowCount(of: table), rowCount > 0 else {
            runner.log("read-newest: row count unavailable; newest end not checked")
            return outcome
        }

        if onlyWhenSuspect {
            let initialValue = scrollValue(of: scrollBar)
            let suspectReason: String?
            // Scanning every loaded row for the read marker cost about 5 s on a 52-row table,
            // past the MCP limit; the marker is checked on the analyzed rows instead.
            if let initialValue, initialValue >= 0.99 {
                suspectReason = nil
            } else {
                suspectReason = initialValue == nil ? "scroll_unreadable" : "scroll_below_end"
            }
            runner.log("read-newest: initial rows=\(rowCount) scroll=\(Self.describe(initialValue)) suspect=\(suspectReason ?? "no")")
            guard suspectReason != nil else {
                outcome.stop = .notSuspect
                outcome.scrollValue = initialValue
                return outcome
            }
        }

        let stageStarted = Date()
        var label = peekNewestOwnLabel(in: table)
        var step = 0
        while true {
            if Date() >= deadline {
                runner.log("read-newest: time budget used up after \(outcome.loads) load(s)")
                outcome.stop = .deadline
                break
            }
            step += 1
            let stepStarted = Date()
            do {
                // Already at the bottom, setting 1.0 again is no scroll; step up a little first.
                if let current = scrollValue(of: scrollBar), current >= 0.99 {
                    try scrollBar.setAttribute(kAXValueAttribute, value: NSNumber(value: 0.95))
                    Thread.sleep(forTimeInterval: Self.pagePollInterval)
                }
                try scrollBar.setAttribute(kAXValueAttribute, value: NSNumber(value: 1.0))
            } catch {
                runner.log("read-newest: failed to scroll transcript down: \(error)")
                outcome.stop = .scrollFailed
                break
            }

            let fullWaitEnd = Date().addingTimeInterval(Self.newestLoadTimeout)
            let waitClipped = deadline < fullWaitEnd
            let waitUntil = min(fullWaitEnd, deadline)
            var observedCount: Int?
            var observedLabel: OwnTimeLabel?
            var changed = false
            while Date() < waitUntil {
                Thread.sleep(forTimeInterval: Self.pagePollInterval)
                observedCount = self.rowCount(of: table)
                observedLabel = peekNewestOwnLabel(in: table)
                let countChanged = observedCount.map { $0 != rowCount } ?? false
                let labelChanged = observedLabel.map { $0 != label } ?? false
                if countChanged || labelChanged {
                    changed = true
                    break
                }
            }
            runner.log(
                "read-newest: step \(step) rows \(rowCount) -> \(observedCount.map(String.init) ?? "-") label \(Self.describe(label)) -> \(Self.describe(observedLabel)) scroll=\(Self.describe(scrollValue(of: scrollBar))) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(stepStarted)))s changed=\(changed)"
            )

            guard changed else {
                // A wait cut short by the deadline says nothing about the newest end.
                outcome.stop = waitClipped ? .deadline : .unchanged
                break
            }
            outcome.loads += 1
            rowCount = observedCount ?? rowCount
            label = observedLabel ?? label
            if outcome.loads >= maxLoads {
                runner.log("read-newest: load cap reached loads=\(outcome.loads)")
                outcome.stop = .pageCap
                break
            }
        }

        outcome.scrollValue = scrollValue(of: scrollBar)
        outcome.lastLabel = newestRowLabel(in: table, transcriptRoot: transcriptRoot)
        runner.log(
            "read-newest: stage stop=\(outcome.stop.rawValue) loads=\(outcome.loads) scroll=\(Self.describe(outcome.scrollValue)) label=\(Self.describe(outcome.lastLabel)) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(stageStarted)))s"
        )
        return outcome
    }

    /// `newest_reached` for a read: nil when the newest end was not checked or cannot be
    /// judged, true only when the stage stopped at the bottom with nothing more to load and
    /// the newest labelled row it saw is the newest labelled row the read analyzed.
    private func judgeNewestReached(
        _ outcome: NewestEndOutcome?,
        analyzedNewest: OwnTimeLabel?,
        analysisDeadlineHit: Bool,
        readMarkerSeen: Bool = false,
        notCheckedReason: String = "no_table"
    ) -> Bool? {
        var reached: Bool?
        var reason: String
        if let outcome {
            switch outcome.stop {
            case .notSuspect where readMarkerSeen:
                // Opened at the bottom of the loaded rows, yet at the read marker: newer
                // rows may not be loaded.
                reached = false
                reason = "read_marker_at_bottom"
            case .notSuspect, .noScrollBar:
                reached = true
                reason = outcome.stop.rawValue
            case .unavailable:
                reached = nil
                reason = outcome.stop.rawValue
            case .deadline, .pageCap, .scrollFailed:
                reached = false
                reason = outcome.stop.rawValue
            case .unchanged:
                if let value = outcome.scrollValue {
                    if value < 0.99 {
                        reached = false
                        reason = "scroll_below_end"
                    } else if outcome.lastLabel == nil {
                        reached = false
                        reason = "no_labelled_row"
                    } else if let recorded = outcome.lastLabel, recorded != analyzedNewest,
                              case let mismatch = Self.labelMismatchReason(recorded: recorded, analyzed: analyzedNewest),
                              mismatch != "analyzed_newer"
                    {
                        reached = false
                        reason = mismatch
                    } else {
                        reached = true
                        reason = outcome.stop.rawValue
                    }
                } else {
                    reached = nil
                    reason = "scroll_unreadable"
                }
            }
        } else {
            reached = nil
            reason = notCheckedReason
        }
        if analysisDeadlineHit, reached == true {
            reached = false
            reason = "analysis_deadline"
        }
        runner.log(
            "read-newest: newest_reached=\(reached.map { String($0) } ?? "null") reason=\(reason) loads=\(outcome?.loads ?? 0) recorded=\(Self.describe(outcome?.lastLabel)) analyzed=\(Self.describe(analyzedNewest))"
        )
        return reached
    }

    /// The own time label of the newest labelled row, read the way `analyzeRow` reads it.
    private func peekNewestOwnLabel(in table: UIElement) -> OwnTimeLabel? {
        guard let rows = tableRows(of: table) else { return nil }
        let newestFirst = isReversedOrder(rows, frameCache: FrameCache()) ? rows : Array(rows.reversed())
        for row in newestFirst.prefix(Self.peekRowCount) {
            for text in row.findAll(role: kAXStaticTextRole, limit: 10, maxNodes: 60) {
                if let time = TranscriptTime.timeLabel(text.stringValue),
                   let help = text.helpText,
                   let date = Self.parseHelpDate(help)
                {
                    return OwnTimeLabel(date: date, time: time)
                }
            }
        }
        return nil
    }

    /// The label recorded when the stage stops goes through `analyzeRow`, the same reading
    /// the analyzed side uses, so both sides of the comparison agree on a row's label.
    private func newestRowLabel(in table: UIElement, transcriptRoot: UIElement) -> OwnTimeLabel? {
        let frameCache = FrameCache()
        let rows = orderedRows(of: table, frameCache: frameCache)
        for row in rows.reversed().prefix(Self.peekRowCount) {
            let analysis = analyzeRow(row, transcriptRoot: transcriptRoot, referenceDate: Date(), frameCache: frameCache)
            if let date = analysis.labelDate, let time = analysis.labelTime {
                return OwnTimeLabel(date: date, time: time)
            }
        }
        return nil
    }

    /// Tells a newer analyzed label (a message arrived after the stage; the confirmed newest
    /// row is still inside the analyzed range) from an older one (the newest rows were not
    /// analyzed).
    private static func labelMismatchReason(recorded: OwnTimeLabel, analyzed: OwnTimeLabel?) -> String {
        guard let analyzed,
              let recordedDate = TranscriptTime.localDate(date: recorded.date, timeRaw: recorded.time),
              let analyzedDate = TranscriptTime.localDate(date: analyzed.date, timeRaw: analyzed.time)
        else {
            return "newest_not_analyzed"
        }
        return analyzedDate > recordedDate ? "analyzed_newer" : "analyzed_older"
    }

    /// KakaoTalk's read marker row ("여기까지 읽었습니다") among already analyzed rows.
    private static func containsReadMarker(_ analyses: [RowAnalysis]) -> Bool {
        analyses.contains { analysis in
            analysis.bodyCandidate.map { $0.body.filter { !$0.isWhitespace }.contains(readMarkerText) } ?? false
        }
    }

    private static func newestOwnLabel<S: Sequence>(newestFirst analyses: S) -> OwnTimeLabel? where S.Element == RowAnalysis {
        for analysis in analyses {
            if let date = analysis.labelDate, let time = analysis.labelTime {
                return OwnTimeLabel(date: date, time: time)
            }
        }
        return nil
    }

    private func scrollValue(of scrollBar: UIElement) -> Double? {
        (scrollBar.value as? NSNumber)?.doubleValue
    }

    private static func describe(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "-"
    }

    private static func describe(_ label: OwnTimeLabel?) -> String {
        label.map { "\($0.date) \($0.time)" } ?? "-"
    }

    // MARK: Table access

    /// Below this many messages the table path is taken as failed, as the row search
    /// path judges its own result.
    fileprivate static func minimumTableMessages(limit: Int) -> Int {
        max(3, min(limit / 2, 8))
    }

    /// The latest `limit` messages read the way `readSince` reads them: rows straight from
    /// the transcript table, newest first, analyzed only until `limit` messages and an
    /// author anchor are in hand, with time and date from each row's own label. Both reads
    /// then give the same message the same time.
    fileprivate func readRecentFromTable(
        _ table: UIElement,
        context: MessageTranscriptContext,
        limit: Int,
        includeSystemMessages: Bool,
        referenceDate: Date,
        deadline: Date?,
        newestAnalyzed: inout OwnTimeLabel?,
        readMarkerSeen: inout Bool,
        deadlineHit: inout Bool
    ) -> [TranscriptMessage] {
        let frameCache = FrameCache()
        let rows = orderedRows(of: table, frameCache: frameCache)
        guard !rows.isEmpty else { return [] }

        let inputMinY = context.inputElement.frame?.minY
        var reversedAnalyses: [RowAnalysis] = []
        var collected = 0
        var contextRows = 0
        for row in rows.reversed() {
            if collected >= limit, contextRows >= Self.anchorContextRows {
                break
            }
            if let deadline, Date() >= deadline {
                runner.log("read: time budget used up after \(reversedAnalyses.count) analyzed row(s)")
                deadlineHit = true
                break
            }
            if let inputMinY, let rowFrame = frameCache.frame(of: row), rowFrame.maxY > inputMinY + 20 {
                continue
            }
            let analysis = analyzeRow(row, transcriptRoot: context.transcriptRoot, referenceDate: referenceDate, frameCache: frameCache)
            reversedAnalyses.append(analysis)
            if collected >= limit {
                // Past the limit a row only serves as the author anchor of the oldest kept message.
                contextRows += 1
                if analysis.explicitAuthor != nil {
                    break
                }
            } else if analysis.bodyCandidate != nil, includeSystemMessages || !analysis.isSystemLikeRow {
                collected += 1
            }
        }

        newestAnalyzed = Self.newestOwnLabel(newestFirst: reversedAnalyses)
        readMarkerSeen = Self.containsReadMarker(reversedAnalyses)
        let analyses = Array(reversedAnalyses.reversed())
        let indexed = buildMessages(
            from: analyses,
            limit: limit,
            includeSystemMessages: includeSystemMessages,
            referenceDate: referenceDate
        )
        let ownLabels = resolveOwnLabels(analyses, from: 0)
        let messages = indexed.map { entry -> TranscriptMessage in
            let label = ownLabels[entry.analysisIndex]
            return entry.message.withDateTime(date: label?.date, timeRaw: label?.time)
        }
        runner.log("read: table rows=\(rows.count) analyzed=\(analyses.count) messages=\(messages.count)")
        return Array(messages.suffix(limit))
    }

    private func transcriptTable(in transcriptRoot: UIElement) -> UIElement? {
        if transcriptRoot.role == kAXTableRole {
            return transcriptRoot
        }
        return transcriptRoot.findAll(role: kAXTableRole, limit: 1, maxNodes: 200).first
    }

    private func enclosingScrollArea(of table: UIElement, transcriptRoot: UIElement) -> UIElement? {
        var cursor: UIElement? = table
        for _ in 0..<4 {
            guard let current = cursor else { break }
            if current.role == kAXScrollAreaRole {
                return current
            }
            cursor = current.parent
        }
        if transcriptRoot.role == kAXScrollAreaRole {
            return transcriptRoot
        }
        return transcriptRoot.findAll(role: kAXScrollAreaRole, limit: 1, maxNodes: 200).first
    }

    private func rowCount(of table: UIElement) -> Int? {
        var count: CFIndex = 0
        let error = AXUIElementGetAttributeValueCount(table.axElement, kAXRowsAttribute as CFString, &count)
        if error == .success {
            return count
        }
        return tableRows(of: table)?.count
    }

    private func tableRows(of table: UIElement) -> [UIElement]? {
        if let axRows: [AXUIElement] = table.attributeOptional(kAXRowsAttribute) {
            return axRows.map { UIElement($0) }
        }
        let rows = directRowChildren(from: table)
        return rows.isEmpty ? nil : rows
    }

    /// Rows in visual (top-to-bottom) order without sorting every row by frame.
    private func orderedRows(of table: UIElement, frameCache: FrameCache) -> [UIElement] {
        guard let rows = tableRows(of: table) else { return [] }
        return isReversedOrder(rows, frameCache: frameCache) ? Array(rows.reversed()) : rows
    }

    private func isReversedOrder(_ rows: [UIElement], frameCache: FrameCache) -> Bool {
        guard rows.count > 1,
              let first = frameCache.frame(of: rows[0]),
              let last = frameCache.frame(of: rows[rows.count - 1])
        else {
            return false
        }
        return first.minY > last.minY
    }
}

func messageFingerprint(_ message: TranscriptMessage) -> String {
    "\(message.author ?? "")\u{1F}\(message.timeRaw ?? "")\u{1F}\(message.body)"
}

private struct IndexedTranscriptMessage {
    let analysisIndex: Int
    let message: TranscriptMessage
}

private struct RowMetadata {
    let author: String?
    let timeRaw: String?
}

private struct MessageBodyCandidate {
    let body: String
    let frame: CGRect?
}

private struct RowAnalysis {
    let bodyCandidate: MessageBodyCandidate?
    let explicitAuthor: String?
    let timeRaw: String?
    let side: MessageSide
    let rowFrame: CGRect?
    let imageCount: Int
    let linkCount: Int
    let attachmentCount: Int
    let isSystemLikeRow: Bool
    let axHelpDate: String?
    /// Date and time from the row's own time label only (see `TranscriptTime.timeLabel`).
    let labelDate: String?
    let labelTime: String?
    /// False when the row exposed no text, image, button, or link element at all.
    let hasContent: Bool

    var labelTimestamp: Date? {
        TranscriptTime.localDate(date: labelDate, timeRaw: labelTime)
    }

    var referenceFrame: CGRect? {
        bodyCandidate?.frame ?? rowFrame
    }
}

private enum MessageSide: String, Hashable {
    case left
    case right
    case unknown
}

private final class FrameCache {
    private var entries: [(element: AXUIElement, frame: CGRect?)] = []
    private var buckets: [CFHashCode: [Int]] = [:]

    func frame(of element: UIElement) -> CGRect? {
        let hash = CFHash(element.axElement)
        if let indices = buckets[hash] {
            for idx in indices {
                if CFEqual(entries[idx].element, element.axElement) {
                    return entries[idx].frame
                }
            }
        }
        let frame = element.frame
        let idx = entries.count
        entries.append((element: element.axElement, frame: frame))
        buckets[hash, default: []].append(idx)
        return frame
    }
}
