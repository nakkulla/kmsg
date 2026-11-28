import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MCP_SERVER_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "MCPServerCommand.swift"


class MCPServerContractTests(unittest.TestCase):
    def test_startup_status_check_allows_slow_ax_ready_state(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        self.assertIn('run(["status"], timeoutSec: 15.0)', source)

    def test_subprocess_readers_start_after_successful_launch(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        run_index = source.index("try process.run()")
        stdout_reader_index = source.index("let stdoutData = MCPDataBuffer()")
        self.assertLess(run_index, stdout_reader_index)

    def test_mcp_server_accepts_content_length_and_ndjson(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        self.assertIn("enum MCPStdioTransport", source)
        self.assertIn("case contentLength", source)
        self.assertIn("case newlineDelimitedJSON", source)
        self.assertIn('trimmed.hasPrefix("{")', source)
        self.assertIn("writeContentLengthMessage", source)
        self.assertIn("writeNewlineDelimitedJSONMessage", source)

    def test_focus_fail_has_actionable_mcp_error_code(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        self.assertIn('combinedText.contains("FOCUS_FAIL")', source)
        self.assertIn('"KAKAO_SEARCH_FOCUS_FAILED"', source)
        self.assertIn("search input could not be focused", source)

    def test_chats_tool_is_listed_and_dispatched(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")

        self.assertIn('"name": "kmsg_chats"', source)
        self.assertIn('case "kmsg_chats":', source)
        self.assertIn("resultObject = callKmsgChats(arguments)", source)
        self.assertIn("Read-only.", source)

    def test_chats_tool_schema_uses_real_chats_flags(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        start = source.index('"name": "kmsg_chats"')
        end = source.index('"name": "kmsg_send"', start)
        schema = source[start:end]

        for key in ('"limit"', '"keep_window"', '"trace_ax"'):
            self.assertIn(key, schema)
        for absent in ('"deep_recovery"', '"background_safe"', '"since"'):
            self.assertNotIn(absent, schema)
        self.assertIn('"maximum": Self.chatsLimitMax', schema)
        self.assertIn("private static let chatsLimitMax = 200", source)
        self.assertIn("private static let chatsLimitDefault = 20", source)

    def test_chats_tool_runs_chats_json_and_relays_unread_count(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        start = source.index("private func callKmsgChats(")
        end = source.index("private func callKmsgSend(", start)
        body = source[start:end]

        self.assertIn('var command = ["chats", "--json", "--limit", String(boundedLimit)]', body)
        self.assertIn("timeoutSec: Self.chatsTimeoutSec", body)
        self.assertIn("private static let chatsTimeoutSec = 20.0", source)
        for key in ('"title"', '"chat_id"', '"last_message"', '"unread_count"', '"unread_count_capped"'):
            self.assertIn(key, body)
        for key in ('"ok": true', '"count"', '"chats": chats', '"latency_ms": run.latencyMs'):
            self.assertIn(key, body)
        for code in ('"PROCESS_TIMEOUT"', '"INVALID_JSON_OUTPUT"', '"INVALID_ARGUMENT"'):
            self.assertIn(code, body)

    def test_read_forwards_newest_reached_in_both_modes(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        start = source.index("private func callKmsgRead(")
        end = source.index("private func callKmsgChats(", start)
        body = source[start:end]

        # Set in the base meta, before the since-only fields.
        forward = body.index('"newest_reached": payload["newest_reached"] ?? NSNull(),')
        self.assertLess(forward, body.index("if sinceMode {\n            var meta"))

    def test_recent_read_child_gets_a_timeout_inside_the_process_limit(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")

        self.assertIn('["--timeout-sec", deepRecovery ? "13" : "6"]', source)
        self.assertIn(
            "command + (sinceMode ? [] : Self.recentReadChildTimeoutArgs(deepRecovery: deepRecovery)),",
            source,
        )
        self.assertIn("retryCommand.append(contentsOf: Self.recentReadChildTimeoutArgs(deepRecovery: true))", source)

    def test_read_tool_description_lists_newest_unreached(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        start = source.index('"name": "kmsg_read"')
        description = source[start: source.index('"inputSchema"', start)]

        self.assertIn("limit, newest_unreached, scroll_failed", description)
        self.assertIn("meta.newest_reached", description)


if __name__ == "__main__":
    unittest.main()
