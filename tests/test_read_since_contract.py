import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources" / "kmsg"
READ_COMMAND = SOURCES / "Commands" / "ReadCommand.swift"
CHATS_COMMAND = SOURCES / "Commands" / "ChatsCommand.swift"
MCP_SERVER_COMMAND = SOURCES / "Commands" / "MCPServerCommand.swift"
CHAT_LIST_SCANNER = SOURCES / "KakaoTalk" / "ChatListScanner.swift"
TRANSCRIPT_READER = SOURCES / "KakaoTalk" / "TranscriptReader.swift"
TRANSCRIPT_TIME = SOURCES / "KakaoTalk" / "TranscriptTime.swift"
USAGE = REPO_ROOT / "USAGE.md"
README_KO = REPO_ROOT / "README.md"
README_EN = REPO_ROOT / "README.en.md"
SKILL = REPO_ROOT / "skills" / "kmsg" / "SKILL.md"


class ChatsUnreadCountContractTests(unittest.TestCase):
    def test_chat_entry_encodes_unread_count_as_explicit_null(self) -> None:
        source = CHAT_LIST_SCANNER.read_text(encoding="utf-8")

        self.assertIn('case unreadCount = "unread_count"', source)
        self.assertIn('case unreadCountCapped = "unread_count_capped"', source)
        self.assertIn("try container.encode(unreadCount, forKey: .unreadCount)", source)
        self.assertIn('$0.identifier == "Count Label"', source)
        self.assertIn("UnreadBadgeParser.parse", source)

    def test_badge_parser_strips_plus_and_commas(self) -> None:
        source = TRANSCRIPT_TIME.read_text(encoding="utf-8")

        self.assertIn("enum UnreadBadgeParser", source)
        self.assertIn('$0 != "+" && $0 != ","', source)
        self.assertIn('trimmed.contains("+")', source)

    def test_chats_text_output_appends_unread_count(self) -> None:
        source = CHATS_COMMAND.read_text(encoding="utf-8")

        self.assertIn("unreadCount: snapshot.discovery.unreadCount", source)
        self.assertIn("if let unread = chat.unreadCount", source)


class ReadSinceContractTests(unittest.TestCase):
    def test_read_command_exposes_since_options_with_defaults(self) -> None:
        source = READ_COMMAND.read_text(encoding="utf-8")

        self.assertIn("var since: String?", source)
        self.assertIn("var maxPages: Int = 40", source)
        self.assertIn("var timeoutSec: Double?", source)
        self.assertIn("let budgetSec = timeoutSec ?? (sinceDate != nil ? Self.defaultSinceTimeoutSec : Self.defaultRecentTimeoutSec)", source)
        self.assertIn("static let defaultRecentTimeoutSec = 6.0", source)
        self.assertIn("static let defaultLimit = 20", source)
        self.assertIn("static let defaultSinceLimit = 2_000", source)
        self.assertIn("static let defaultSinceTimeoutSec = 180.0", source)
        self.assertIn("allowPaging: !backgroundSafe", source)

    def test_read_json_adds_since_fields_only_for_since_reads(self) -> None:
        source = READ_COMMAND.read_text(encoding="utf-8")

        self.assertIn("let since: String?", source)
        self.assertIn('case oldestReached = "oldest_reached"', source)
        self.assertIn("case truncated", source)
        self.assertIn('case pagesLoaded = "pages_loaded"', source)
        self.assertIn('case stopReason = "stop_reason"', source)

    def test_read_json_reports_newest_reached_in_both_modes(self) -> None:
        source = READ_COMMAND.read_text(encoding="utf-8")

        self.assertIn('case newestReached = "newest_reached"', source)
        # Explicit null (not an absent key) when the newest end was not checked.
        self.assertIn("try container.encode(newestReached, forKey: .newestReached)", source)
        self.assertIn("newestReached: snapshot.newestReached,", source)
        self.assertIn(
            "newestEnd: backgroundSafe ? nil : NewestEndOptions(maxLoads: maxPages, deadline: deadline)",
            source,
        )
        self.assertIn("if let timeoutSec, timeoutSec <= 0 {", source)

    def test_since_read_names_why_it_stopped(self) -> None:
        reader = TRANSCRIPT_READER.read_text(encoding="utf-8")

        self.assertIn("enum TranscriptStopReason: String, Sendable, Encodable", reader)
        for value in ('"page_cap"', '"scroll_failed"', '"rows_unreadable"', '"paging_unavailable"'):
            self.assertIn(value, reader)
        for case in ("case complete", "case deadline", "case limit"):
            self.assertIn(case, reader)
        self.assertIn("stopReason = limitHit ? .limit : .complete", reader)

    def test_since_read_reports_newest_unreached_after_incomplete_reasons(self) -> None:
        reader = TRANSCRIPT_READER.read_text(encoding="utf-8")
        read_since = reader.split("func readSince(", 1)[1].split("private func resolveOwnLabels(", 1)[0]

        self.assertIn('case newestUnreached = "newest_unreached"', reader)
        self.assertIn("let truncated = limitHit || !covered || newestReached != true", read_since)
        # Uncovered-range reasons win, then newest_unreached, then limit, then complete.
        chain = read_since[read_since.index("let stopReason: TranscriptStopReason"):]
        newest = chain.index("if covered, newestReached != true {\n            stopReason = .newestUnreached")
        limit = chain.index("} else if covered {\n            stopReason = limitHit ? .limit : .complete")
        deadline = chain.index("} else if deadlineHit {\n            stopReason = .deadline")
        self.assertLess(newest, limit)
        self.assertLess(limit, deadline)
        # complete only when truncated is false.
        self.assertIn("/// Why the read ended; `.complete` exactly when `truncated` is false.", reader)

    def test_reads_load_the_newest_end_before_reading_rows(self) -> None:
        reader = TRANSCRIPT_READER.read_text(encoding="utf-8")
        read_since = reader.split("func readSince(", 1)[1].split("private func resolveOwnLabels(", 1)[0]
        stage = reader.split("private func loadNewestEnd(", 1)[1].split("private func judgeNewestReached(", 1)[0]

        self.assertIn("NSNumber(value: 0.95)", stage)
        self.assertIn("current >= 0.99", stage)
        self.assertIn("let fullWaitEnd = Date().addingTimeInterval(Self.newestLoadTimeout)", stage)
        self.assertIn("private static let newestLoadTimeout: TimeInterval = pageGrowthTimeout", reader)
        self.assertIn("if outcome.loads >= maxLoads {", stage)
        self.assertNotIn("pagesLoaded", stage)
        self.assertIn('"read-newest: step \\(step) rows', stage)
        # since: the stage takes its share of the paging budget before paging up.
        self.assertLess(read_since.index("newestOutcome = loadNewestEnd("), read_since.index("outcome = loadHistory("))
        self.assertIn("deadline: min(Date().addingTimeInterval(newestBudget), pagingDeadline)", read_since)
        # recent-N: only when suspect, before both the table path and the row search.
        snapshot = reader.split("referenceDate: Date = Date(),\n        newestEnd: NewestEndOptions? = nil", 1)[1]
        snapshot = snapshot.split("private func collectTranscriptRows(", 1)[0]
        self.assertLess(snapshot.index("onlyWhenSuspect: true"), snapshot.index("let tableMessages = readRecentFromTable("))
        self.assertIn('static let readMarkerText = "여기까지읽었습니다"', reader)
        # The marker is looked for in analyzed rows only; a full-table scan cost ~5 s.
        self.assertIn("readMarkerSeen = Self.containsReadMarker(reversedAnalyses)", reader)
        self.assertIn("case .notSuspect where readMarkerSeen:", reader)
        self.assertIn('reason = "read_marker_at_bottom"', reader)
        self.assertNotIn("hasReadMarkerRow", reader)
        # Past the recent-N deadline the table result stands; the row search has no deadline.
        self.assertIn("|| analysisDeadlineHit {", reader)

    def test_newest_reached_compares_the_recorded_and_analyzed_labels(self) -> None:
        reader = TRANSCRIPT_READER.read_text(encoding="utf-8")
        judge = reader.split("private func judgeNewestReached(", 1)[1].split("private func peekNewestOwnLabel(", 1)[0]

        self.assertIn("case .notSuspect, .noScrollBar:", judge)
        self.assertIn("case .deadline, .pageCap, .scrollFailed:", judge)
        self.assertIn("} else if outcome.lastLabel == nil {", judge)
        self.assertIn("} else if let recorded = outcome.lastLabel, recorded != analyzedNewest,", judge)
        self.assertIn('mismatch != "analyzed_newer"', judge)
        self.assertIn("outcome.lastLabel = newestRowLabel(in: table, transcriptRoot: transcriptRoot)", reader)
        self.assertIn("outcome.stop = waitClipped ? .deadline : .unchanged", reader)
        self.assertIn('"read-newest: newest_reached=', judge)

    def test_since_read_analyzes_rows_before_restoring_scroll(self) -> None:
        reader = TRANSCRIPT_READER.read_text(encoding="utf-8")

        # Back at the bottom KakaoTalk empties the oldest loaded rows, so paging must
        # leave the transcript scrolled up and readSince restores it after the analysis.
        load_history = reader.split("private func loadHistory(", 1)[1].split("private func scrollToBottom(", 1)[0]
        self.assertNotIn("scrollToBottom(", load_history)
        self.assertIn("outcome.scrolledBar = scrollBar", load_history)
        read_since = reader.split("func readSince(", 1)[1].split("private func resolveOwnLabels(", 1)[0]
        self.assertIn("scrollToBottom(scrolledBar)", read_since)
        self.assertIn("emptyRowRun >= Self.emptyStretchMinRows, !rereadDone", read_since)
        self.assertIn("emptyRowRun < Self.emptyStretchMinRows", read_since)

    def test_chat_id_open_reads_only_rows_with_the_chat_name(self) -> None:
        resolver = (SOURCES / "KakaoTalk" / "ChatWindowResolver.swift").read_text(encoding="utf-8")
        scanner = CHAT_LIST_SCANNER.read_text(encoding="utf-8")

        self.assertIn("onlyNormalizedTitle: normalizedName,", resolver)
        self.assertIn("stopAfter: sameNameRecords == 1 ? 1 : nil,", resolver)
        self.assertIn("ChatTextNormalizer.normalize(title) != onlyNormalizedTitle", scanner)

    def test_since_parser_accepts_iso_and_relative_spans(self) -> None:
        source = TRANSCRIPT_TIME.read_text(encoding="utf-8")

        self.assertIn("enum SinceParser", source)
        self.assertIn("ISO8601DateFormatter", source)
        self.assertIn('"mhd".contains(unit)', source)
        self.assertIn("static func localDate(date: String?, timeRaw: String?", source)

    def test_transcript_reader_pages_history_and_stops_at_since(self) -> None:
        source = TRANSCRIPT_READER.read_text(encoding="utf-8")

        self.assertIn("func readSince(", source)
        self.assertIn("kAXVerticalScrollBarAttribute", source)
        self.assertIn("NSNumber(value: 0.0)", source)
        self.assertIn("NSNumber(value: 1.0)", source)
        self.assertIn("pageGrowthTimeout: TimeInterval = 3.0", source)
        self.assertIn("for row in rows.reversed()", source)
        self.assertIn("peekOldestLoadedTime", source)

    def test_since_boundary_uses_only_own_time_labels(self) -> None:
        reader = TRANSCRIPT_READER.read_text(encoding="utf-8")
        helpers = TRANSCRIPT_TIME.read_text(encoding="utf-8")

        self.assertIn("static func timeLabel(_ text: String?) -> String?", helpers)
        self.assertIn("let labelDate: String?", reader)
        self.assertIn("analysis.labelTimestamp.map { $0 < sinceMinute }", reader)
        self.assertIn("crossReversedIndex = pending", reader)
        self.assertIn("if let edge = labelled.max()", reader)
        self.assertIn("ownLabel=", reader)

    def test_time_label_accepts_receipt_count_prefix(self) -> None:
        helpers = TRANSCRIPT_TIME.read_text(encoding="utf-8")

        # KakaoTalk renders the newest labels as "1\n오후 1:17" (receipt count, then time).
        self.assertIn("1\\n오후 1:17", helpers)
        self.assertIn(".split(whereSeparator: \\.isNewline)", helpers)
        self.assertIn('case 2 where lines[0].range(of: #"^\\d{1,4}$"#, options: .regularExpression) != nil:', helpers)
        self.assertIn("return candidate", helpers)

    def test_since_messages_take_date_and_time_from_own_labels(self) -> None:
        reader = TRANSCRIPT_READER.read_text(encoding="utf-8")

        self.assertIn("private func resolveOwnLabels(", reader)
        self.assertIn("entry.analysisIndex >= firstKept", reader)
        self.assertIn("timestamp < sinceMinute", reader)
        self.assertIn("entry.message.withDateTime(date: label?.date, timeRaw: label?.time)", reader)


class MCPReadSinceContractTests(unittest.TestCase):
    def test_mcp_read_schema_exposes_since_and_timeout(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")

        self.assertIn('"since": [', source)
        self.assertIn('"timeout_sec": [', source)
        self.assertIn('"maximum": 2000', source)
        self.assertIn('"maximum": 600', source)
        self.assertIn("Without since: 1..100, default 20. With since: safety cap 1..2000, default 2000.", source)

    def test_mcp_read_keeps_legacy_limits_without_since(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")

        self.assertIn("boundedLimit = max(1, min(limit, 100))", source)
        self.assertIn("let timeoutSec = sinceMode ? boundedSinceTimeoutSec : (deepRecovery ? 15.0 : 8.0)", source)
        self.assertIn("timeoutSec: sinceMode ? boundedSinceTimeoutSec : 15.0", source)

    def test_mcp_read_since_mode_limits_and_meta(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")

        self.assertIn("private static let sinceLimitMax = 2_000", source)
        self.assertIn("private static let sinceTimeoutDefault = 180.0", source)
        self.assertIn("private static let sinceTimeoutMax = 600.0", source)
        self.assertIn('command.append(contentsOf: ["--since", since, "--timeout-sec", String(Int(childBudget))])', source)
        for key in ('meta["since"]', 'meta["oldest_reached"]', 'meta["truncated"]', 'meta["pages_loaded"]', 'meta["stop_reason"]'):
            self.assertIn(key, source)


class ReadSinceDocumentationTests(unittest.TestCase):
    def test_docs_describe_since_and_unread_count(self) -> None:
        for path in (README_KO, README_EN, USAGE, SKILL):
            with self.subTest(path=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn("--since", text)
                self.assertIn("unread_count", text)

    def test_usage_documents_mcp_since_limits(self) -> None:
        usage = USAGE.read_text(encoding="utf-8")

        self.assertIn("`timeout_sec`", usage)
        self.assertIn("`oldest_reached`", usage)
        self.assertIn("`pages_loaded`", usage)
        self.assertIn("`stop_reason`", usage)
        self.assertIn("`--max-pages N`", usage)

    def test_docs_describe_newest_reached(self) -> None:
        usage = USAGE.read_text(encoding="utf-8")
        skill = SKILL.read_text(encoding="utf-8")

        for text in (usage, skill):
            self.assertIn("`newest_reached`", text)
            self.assertIn("`newest_unreached`", text)
            self.assertIn("--timeout-sec", text)
        self.assertIn("#### Reading the newest end", usage)
        self.assertIn("`meta.newest_reached`", usage)
        self.assertIn("It is `complete` exactly when `truncated`\nis `false`.", usage)

    def test_docs_list_mcp_chats_tool(self) -> None:
        for path in (README_KO, README_EN, USAGE, SKILL):
            with self.subTest(path=path.name):
                self.assertIn("kmsg_chats", path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
