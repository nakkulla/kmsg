import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources" / "kmsg"
CHAT_WINDOW_RESOLVER = SOURCES / "KakaoTalk" / "ChatWindowResolver.swift"
READ_COMMAND = SOURCES / "Commands" / "ReadCommand.swift"
CACHE_COMMAND = SOURCES / "Commands" / "CacheCommand.swift"
MCP_SERVER_COMMAND = SOURCES / "Commands" / "MCPServerCommand.swift"
SEND_COMMAND = SOURCES / "Commands" / "SendCommand.swift"
AX_ACTION_RUNNER = SOURCES / "Accessibility" / "AXActionRunner.swift"
KAKAO_TALK_APP = SOURCES / "KakaoTalk" / "KakaoTalkApp.swift"
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

    def test_offscreen_moves_past_bottom_right_corner_outside_background_safe(self) -> None:
        source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")

        self.assertIn("func moveWindowOffscreen(_ window: UIElement) -> CGPoint?", source)
        self.assertIn("guard layoutMode == .offscreen, interactionMode == .allowUIAutomation else {", source)
        self.assertIn("let rightmost = displays.max { $0.maxX < $1.maxX } ?? first", source)
        self.assertIn("CGPoint(x: rightmost.maxX + 500, y: rightmost.maxY + 500)", source)
        self.assertIn("func restoreWindowPosition(_ window: UIElement, to origin: CGPoint)", source)

    def test_offscreen_search_moves_main_window_and_restores_on_every_exit(self) -> None:
        source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")
        start = source.index("private func openChatViaSearch(")
        body = source[start:source.index("private func dismissSearchAfterFailure(", start)]

        self.assertIn("let rootOrigin = unobtrusive ? moveWindowOffscreen(rootWindow) : nil", body)
        self.assertLess(body.index("defer {"), body.index("guard let searchField"))
        self.assertIn("restoreWindowPosition(rootWindow, to: rootOrigin)", body)
        self.assertLess(
            body.index("try? rootWindow.setAttribute(kAXMinimizedAttribute, value: true as CFBoolean)"),
            body.index("restoreWindowPosition(rootWindow, to: rootOrigin)"),
        )
        self.assertNotIn("runner.pressEscape()", body)

    def test_offscreen_never_activates_clicks_or_sends_untargeted_keys(self) -> None:
        source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")

        bring = source[source.index("private func bringForward("):source.index("func resolve(query:")]
        self.assertLess(bring.index("guard !unobtrusive else { return }"), bring.index("kakao.activate()"))

        trigger = source[source.index("private func triggerSearchResultOpen("):source.index("private func openSearchResultViaKeyboard(")]
        self.assertLess(trigger.index("if unobtrusive {"), trigger.index("runner.mouseDoubleClick("))

        keyboard = source[source.index("private func openSearchResultViaKeyboard("):source.index("private static let keyboardOpenMaxSteps")]
        self.assertLess(keyboard.index("guard runner.postsKeysToTargetOnly else {"), keyboard.index("runner.pressDownArrowKey()"))
        self.assertLess(keyboard.index("var previous = selectedSearchRow(in: rootWindow)"), keyboard.index("runner.pressDownArrowKey()"))
        self.assertLess(
            keyboard.index("if match.score > 0, match.matchedText == candidate.matchedText {"),
            keyboard.index("runner.pressEnterKey()"),
        )
        self.assertEqual(keyboard.count("runner.pressEnterKey()"), 1)
        self.assertNotIn("mouseDoubleClick", keyboard)
        self.assertNotIn("kakao.activate()", keyboard)

        close = source[source.index("func closeWindow(_ window: UIElement) -> Bool {"):source.index("private func resolveExistingWindowOnly(")]
        self.assertIn("window.attributeOptional(kAXCloseButtonAttribute)", close)
        self.assertLess(close.index("guard !unobtrusive else {"), close.index("runner.pressCommandW()"))

    def test_runner_posts_keys_to_target_process_when_bound(self) -> None:
        source = AX_ACTION_RUNNER.read_text(encoding="utf-8")

        self.assertIn("init(traceEnabled: Bool, keyTargetPid: (() -> pid_t?)? = nil)", source)
        self.assertIn("event.postToPid(pid)", source)
        keyboard = source[source.index("private func typeText("):source.index("private func postKeyEvent(")]
        self.assertNotIn(".post(tap:", keyboard)
        self.assertEqual(keyboard.count("postKeyEvent("), 4)
        post = source[source.index("private func postKeyEvent("):source.index("func mouseDoubleClick(")]
        self.assertLess(post.index("guard let keyTargetPid else {"), post.index("event.postToPid(pid)"))
        self.assertEqual(post.count(".post(tap: .cghidEventTap)"), 1)

    def test_offscreen_windows_return_after_stop_signal_or_kill(self) -> None:
        source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")

        parking = source[source.index("private final class OffscreenParking"):source.index("struct ChatWindowResolver {")]
        self.assertIn("for stopSignal in [SIGTERM, SIGINT] {", parking)
        self.assertLess(parking.index("restoreAll()"), parking.index("exit(128 + stopSignal)"))

        move = source[source.index("func moveWindowOffscreen("):source.index("func restoreWindowPosition(")]
        self.assertIn("visibleArea < frame.width * frame.height * 0.25", move)
        self.assertIn("origin = CGPoint(x: first.minX + 80, y: first.minY + 80)", move)
        self.assertLess(move.index("OffscreenParking.shared.park(window, origin: origin)"), move.index("try window.setPosition(target)"))
        restore = source[source.index("func restoreWindowPosition("):]
        self.assertIn("OffscreenParking.shared.unpark(window)", restore)

    def test_offscreen_target_window_takes_keys_without_activation(self) -> None:
        source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")

        take = source[source.index("func takeKeysWithoutActivation("):source.index("func resolve(query:")]
        self.assertNotIn("kakao.activate()", take)
        self.assertLess(take.index("if holdsFocus() {"), take.index("tryRaiseWindow(window)"))

        search = source[source.index("private func openChatViaSearch("):source.index("private func dismissSearchAfterFailure(")]
        self.assertLess(search.index("moveWindowOffscreen(rootWindow)"), search.index("guard takeKeysWithoutActivation(rootWindow) else {"))

        read = READ_COMMAND.read_text(encoding="utf-8")
        self.assertLess(
            read.index("offscreenOrigin = chatWindowResolver.moveWindowOffscreen(window)"),
            read.index("chatWindowResolver.takeKeysWithoutActivation(window)"),
        )

    def test_offscreen_hands_front_back_after_window_recovery(self) -> None:
        app = KAKAO_TALK_APP.read_text(encoding="utf-8")
        self.assertIn("public struct FrontmostAppKeeper {", app)
        self.assertIn("previous.bundleIdentifier != KakaoTalkApp.bundleIdentifier", app)
        for path in (READ_COMMAND, SEND_COMMAND):
            with self.subTest(path=path.name):
                source = path.read_text(encoding="utf-8")
                self.assertIn("KakaoTalkApp.FrontmostAppKeeper(enabled: layout == .offscreen)", source)
                self.assertIn("frontmostKeeper.handFrontBack(from: kakao)", source)

    def test_send_supports_offscreen_layout(self) -> None:
        source = SEND_COMMAND.read_text(encoding="utf-8")

        self.assertIn("var layout: ChatWindowLayoutMode = .preserve", source)
        self.assertIn("layoutMode: layout", source)
        self.assertIn("keyTargetPid: layout == .offscreen ? { KakaoTalkApp.runningApplication?.processIdentifier } : nil", source)
        self.assertIn("chatWindowResolver.moveWindowOffscreen(resolution.window)", source)
        send = source[source.index("try sendMessageToWindow(resolution.window"):source.index("closeWindowsIfNeeded(")]
        self.assertIn("restoreOffscreenWindow()", send)
        self.assertIn("offscreen layout does not type blindly", source)

        message = source[source.index("private func sendMessageToWindow("):source.index("private func pressSendButton(")]
        self.assertLess(
            message.index("try pressSendButton(in: window, input: input, runner: runner)"),
            message.index("runner.pressEnterWithVerification("),
        )
        button = source[source.index("private func pressSendButton("):source.index("private func closeWindowsIfNeeded(")]
        self.assertIn('(title == "전송" || title == "send") && button.isEnabled && supportsAction(kAXPressAction, on: button)', button)
        self.assertNotIn("pressEnter", button)
        self.assertNotIn("typeText", button)
        self.assertEqual(button.count('setTextWithVerification("", on: input'), 2)
        self.assertLess(button.index("try sendButton.press()"), button.index("condition: inputIsEmpty)"))
        self.assertIn("SendFailureCode.sendUnconfirmed.rawValue", button)

        mcp = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        codes = mcp[mcp.index("private func extractErrorCode("):mcp.index("private func mapHint(")]
        self.assertLess(codes.index('combinedText.contains("SEND_UNCONFIRMED")'), codes.index('lowered.contains("not found")'))
        self.assertLess(codes.index('combinedText.contains("SEND_BUTTON_MISSING")'), codes.index('lowered.contains("not found")'))
        self.assertIn("Do not resend: read the chat first", mcp)
        self.assertIn("if layout != .offscreen,\n           let listWindow = kakao.chatListWindow,", source)

    def test_read_moves_window_and_restores_when_not_closed(self) -> None:
        source = READ_COMMAND.read_text(encoding="utf-8")

        self.assertIn("offscreenOrigin = chatWindowResolver.moveWindowOffscreen(window)", source)
        self.assertIn("chatWindowResolver.restoreWindowPosition(window, to: origin)", source)
        defer_body = source[source.index("        defer {\n            restoreOffscreenWindow()"):]
        self.assertLess(defer_body.index("restoreOffscreenWindow()"), defer_body.index("chatWindowResolver.closeWindow(window)"))
        self.assertIn("keyTargetPid: layout == .offscreen ? { KakaoTalkApp.runningApplication?.processIdentifier } : nil", source)
        self.assertIn("offscreen moves the chat window off all displays while reading", source)

    def test_mcp_layout_accepts_offscreen_and_env_default(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")

        self.assertIn('"split-left", "split-right", "offscreen"]', source)
        self.assertIn('case "preserve", "left", "right", "split-left", "split-right", "offscreen":', source)
        self.assertIn('Self.validReadLayout(env["KMSG_DEFAULT_READ_LAYOUT"])', source)
        self.assertIn('?? Self.validReadLayout(env["KMSG_DEFAULT_LAYOUT"])', source)
        self.assertIn('sendLayoutDefault = Self.validReadLayout(env["KMSG_DEFAULT_LAYOUT"]) ?? "preserve"', source)
        self.assertIn('var command = ["send", chat, message, "--layout", sendLayoutDefault]', source)


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

    def test_search_results_left_behind_are_reset(self) -> None:
        source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")
        start = source.index("private func openChatViaSearch(")
        end = source.index("private func openChatListRow(", start)
        body = source[start:end]

        # Exit: the list is checked after the field is restored.
        restore = body.index("restoreSearchField(field, typedQuery: query, originalValue: originalSearchText)")
        self.assertLess(restore, body.index("releaseSearchResultsLeftBehind(field: field, resultsList: resultsList, in: rootWindow)"))
        # Entry: a list that ignores the query is reset before the row is opened.
        reset = body.index("resetSearchList(in: rootWindow)")
        self.assertLess(body.index("let listRebuilt = waitForSearchListRebuild("), reset)
        self.assertLess(reset, body.index("let matchingCandidates = waitForMatchingSearchResults("))
        self.assertIn("private func resetSearchList(in rootWindow: UIElement) -> Bool", source)
        # The keyboard open still requires the selection to move.
        self.assertIn("search: keyboard open stopped at step \\(step) (selection did not move)", source)

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
