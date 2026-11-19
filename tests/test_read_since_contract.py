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
        self.assertIn("var timeoutSec: Double = ReadCommand.defaultSinceTimeoutSec", source)
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
        for key in ('meta["since"]', 'meta["oldest_reached"]', 'meta["truncated"]', 'meta["pages_loaded"]'):
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
        self.assertIn("`--max-pages N`", usage)


if __name__ == "__main__":
    unittest.main()
