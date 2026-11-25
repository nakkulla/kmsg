import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources" / "kmsg"
READ_COMMAND = SOURCES / "Commands" / "ReadCommand.swift"
MCP_SERVER_COMMAND = SOURCES / "Commands" / "MCPServerCommand.swift"
TRANSCRIPT_READER = SOURCES / "KakaoTalk" / "TranscriptReader.swift"
CHAT_WINDOW_RESOLVER = SOURCES / "KakaoTalk" / "ChatWindowResolver.swift"
USAGE = REPO_ROOT / "USAGE.md"


class RecentReadTablePathContractTests(unittest.TestCase):
    def test_latest_read_takes_the_table_path_before_the_row_search(self) -> None:
        source = TRANSCRIPT_READER.read_text(encoding="utf-8")

        table_path = source.index("let tableMessages = readRecentFromTable(")
        row_search = source.index("let messageRows = collectTranscriptRows(")
        self.assertLess(table_path, row_search)
        self.assertIn("if let table = transcriptTable(in: context.transcriptRoot) {", source)
        self.assertIn("falling back to row search", source)

    def test_table_path_stops_at_the_limit_and_an_author_anchor(self) -> None:
        source = TRANSCRIPT_READER.read_text(encoding="utf-8")
        body = source[source.index("fileprivate func readRecentFromTable("):]
        body = body[: body.index("private func transcriptTable(")]

        self.assertIn("let rows = orderedRows(of: table, frameCache: frameCache)", body)
        self.assertIn("for row in rows.reversed() {", body)
        self.assertIn("if collected >= limit, contextRows >= Self.anchorContextRows {", body)
        self.assertIn("if analysis.explicitAuthor != nil {", body)
        self.assertNotIn("collectTranscriptRows(", body)

    def test_table_path_uses_the_since_read_time_rule(self) -> None:
        source = TRANSCRIPT_READER.read_text(encoding="utf-8")
        body = source[source.index("fileprivate func readRecentFromTable("):]
        body = body[: body.index("private func transcriptTable(")]

        self.assertIn("let ownLabels = resolveOwnLabels(analyses, from: 0)", body)
        self.assertIn("entry.message.withDateTime(date: label?.date, timeRaw: label?.time)", body)
        self.assertIn("return Array(messages.suffix(limit))", body)


class StopSignalWindowCloseContractTests(unittest.TestCase):
    def test_stop_signal_restores_then_closes_owed_windows(self) -> None:
        source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")
        handler = source[source.index("source.setEventHandler { [self] in"):]
        handler = handler[: handler.index("source.resume()")]

        self.assertLess(handler.index("restoreAll()"), handler.index("closeAll()"))
        self.assertLess(handler.index("closeAll()"), handler.index("exit(128 + stopSignal)"))
        self.assertIn("window.attributeOptional(kAXCloseButtonAttribute)", source)

    def test_read_registers_only_a_window_it_would_close(self) -> None:
        source = READ_COMMAND.read_text(encoding="utf-8")

        self.assertIn("if resolution.openedTransiently && !keepWindow && titleMatchesQuery {", source)
        register = source.index("chatWindowResolver.closeWindowOnStopSignal(window)")
        cancel = source.index("chatWindowResolver.cancelCloseOnStopSignal(window)")
        normal_close = source.index("} else if chatWindowResolver.closeWindow(window) {")
        self.assertLess(register, cancel)
        self.assertLess(cancel, normal_close)

    def test_mcp_gives_a_timed_out_child_time_to_clean_up(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")

        self.assertIn("private static let terminateGraceSec: TimeInterval = 2.0", source)
        self.assertIn("terminateSemaphore.wait(timeout: .now() + Self.terminateGraceSec)", source)
        self.assertIn("(deepRecovery ? 15.0 : 8.0)", source)

    def test_usage_documents_both_behaviours(self) -> None:
        usage = USAGE.read_text(encoding="utf-8")

        self.assertIn("#### Reading the latest messages", usage)
        self.assertIn("up to 2 seconds", usage)


if __name__ == "__main__":
    unittest.main()
