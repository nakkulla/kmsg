import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources" / "kmsg"
CHAT_WINDOW_RESOLVER = SOURCES / "KakaoTalk" / "ChatWindowResolver.swift"
READ_COMMAND = SOURCES / "Commands" / "ReadCommand.swift"
CACHE_COMMAND = SOURCES / "Commands" / "CacheCommand.swift"
MCP_SERVER_COMMAND = SOURCES / "Commands" / "MCPServerCommand.swift"
USAGE = REPO_ROOT / "USAGE.md"
README_KO = REPO_ROOT / "README.md"
README_EN = REPO_ROOT / "README.en.md"
SKILL = REPO_ROOT / "skills" / "kmsg" / "SKILL.md"


class OffscreenLayoutContractTests(unittest.TestCase):
    def test_offscreen_layout_mode_does_not_resize_windows(self) -> None:
        source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")

        self.assertIn("case offscreen", source)
        self.assertIn("self != .preserve && self != .offscreen", source)
        self.assertIn("guard layoutMode.resizesWindows else {", source)

    def test_offscreen_moves_left_of_display_union_outside_background_safe(self) -> None:
        source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")

        self.assertIn("func moveWindowOffscreen(_ window: UIElement) -> CGPoint?", source)
        self.assertIn("guard layoutMode == .offscreen, interactionMode == .allowUIAutomation else {", source)
        self.assertIn("reduce(first) { $0.union($1) }", source)
        self.assertIn("CGPoint(x: union.minX - frame.width - 100, y: frame.minY)", source)
        self.assertIn("func restoreWindowPosition(_ window: UIElement, to origin: CGPoint)", source)

    def test_read_moves_window_and_restores_when_not_closed(self) -> None:
        source = READ_COMMAND.read_text(encoding="utf-8")

        self.assertIn("offscreenOrigin = chatWindowResolver.moveWindowOffscreen(window)", source)
        self.assertIn("chatWindowResolver.restoreWindowPosition(window, to: origin)", source)
        self.assertEqual(source.count("restoreOffscreenWindow()"), 3)
        self.assertIn("offscreen moves the chat window off all displays while reading", source)

    def test_mcp_layout_accepts_offscreen_and_env_default(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")

        self.assertIn('"split-left", "split-right", "offscreen"]', source)
        self.assertIn('case "preserve", "left", "right", "split-left", "split-right", "offscreen":', source)
        self.assertIn('Self.validReadLayout(env["KMSG_DEFAULT_READ_LAYOUT"])', source)
        self.assertIn('?? Self.validReadLayout(env["KMSG_DEFAULT_LAYOUT"])', source)


class SearchFieldCleanupContractTests(unittest.TestCase):
    def test_search_path_restores_field_on_every_exit(self) -> None:
        source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")
        start = source.index("private func openChatViaSearch(")
        end = source.index("private func openChatListRow(", start)
        body = source[start:end]

        self.assertIn("let originalSearchText = searchField.stringValue ?? \"\"", body)
        self.assertIn("defer {", body)
        self.assertIn("restoreSearchField(field, typedQuery: query, originalValue: originalSearchText)", body)
        self.assertLess(body.index("defer {"), body.index('label: "search field input"'))

    def test_restore_only_touches_kmsg_text_and_uses_clear_button(self) -> None:
        source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")

        self.assertIn("func restoreSearchField(_ field: UIElement, typedQuery: String, originalValue: String)", source)
        self.assertIn("guard current == typed || current.isEmpty else {", source)
        self.assertIn('field.attributeOptional("AXCancelButton")', source)
        self.assertIn('subrole == "AXCancelButton"', source)

    def test_cache_warmup_restores_search_field(self) -> None:
        source = CACHE_COMMAND.read_text(encoding="utf-8")

        self.assertIn(
            "windowResolver.restoreSearchField(searchField, typedQuery: recipient, originalValue: originalSearchText)",
            source,
        )


class WindowLayoutDocumentationTests(unittest.TestCase):
    def test_docs_mention_offscreen_layout(self) -> None:
        for path in (README_KO, README_EN, USAGE, SKILL):
            with self.subTest(path=path.name):
                self.assertIn("--layout offscreen", path.read_text(encoding="utf-8"))

    def test_usage_documents_layout_env_and_search_cleanup(self) -> None:
        usage = USAGE.read_text(encoding="utf-8")

        self.assertIn("`KMSG_DEFAULT_LAYOUT`", usage)
        self.assertIn("`split-right`, or `offscreen`", usage)
        self.assertIn("main window's search field", usage)


if __name__ == "__main__":
    unittest.main()
