import ArgumentParser
import Foundation

extension ChatWindowLayoutMode: ExpressibleByArgument {}

struct ReadCommand: ParsableCommand {
    private struct ReadJSONResponse: Encodable {
        let chat: String
        let fetchedAt: String
        let count: Int
        let messages: [TranscriptMessage]
        // Both modes; null when the newest end was not checked.
        let newestReached: Bool?
        // Present only for --since reads.
        let since: String?
        let oldestReached: Bool?
        let truncated: Bool?
        let pagesLoaded: Int?
        let stopReason: TranscriptStopReason?

        enum CodingKeys: String, CodingKey {
            case chat
            case fetchedAt = "fetched_at"
            case count
            case messages
            case newestReached = "newest_reached"
            case since
            case oldestReached = "oldest_reached"
            case truncated
            case pagesLoaded = "pages_loaded"
            case stopReason = "stop_reason"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(chat, forKey: .chat)
            try container.encode(fetchedAt, forKey: .fetchedAt)
            try container.encode(count, forKey: .count)
            try container.encode(messages, forKey: .messages)
            try container.encode(newestReached, forKey: .newestReached)
            try container.encodeIfPresent(since, forKey: .since)
            try container.encodeIfPresent(oldestReached, forKey: .oldestReached)
            try container.encodeIfPresent(truncated, forKey: .truncated)
            try container.encodeIfPresent(pagesLoaded, forKey: .pagesLoaded)
            try container.encodeIfPresent(stopReason, forKey: .stopReason)
        }
    }

    static let defaultLimit = 20
    static let defaultSinceLimit = 2_000
    static let defaultSinceTimeoutSec = 180.0
    static let defaultRecentTimeoutSec = 6.0

    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read messages from a chat",
        discussion: """
            Use either:
              kmsg read <chat>
              kmsg read --chat-id <chat-id>

            Use --background-safe to read only already exposed chat windows without launching,
            activating, logging in, searching, opening rows, resizing, or closing windows.

            Use --since to read every message at or after a time instead of the latest N:
              kmsg read --chat-id <chat-id> --since 2026-11-18T07:00:00+09:00 --json
              kmsg read <chat> --since 24h
            --since pages older history into the chat window (up to --max-pages) and
            stops at --timeout-sec; --limit then only caps the result (default 2000).
            With --background-safe, --since reads only already loaded rows.

            Before reading, the chat is scrolled to the bottom until no newer rows load
            (recent reads only when the window opened away from the bottom).
            newest_reached in the JSON output says whether the
            newest end was confirmed; recent reads stop at --timeout-sec (default 6).

            When author is "(me)", the message was sent by you.
            """
    )

    @Option(name: .long, help: "Read using a chat_id from 'kmsg chats'")
    var chatID: String?

    @Argument(help: "Name of the chat to read from (partial match supported)")
    var chat: String?

    @Option(name: .shortAndLong, help: "Maximum number of messages to show (default 20; with --since, a safety cap, default 2000)")
    var limit: Int?

    @Option(name: .long, help: "Read all messages at or after this time: ISO 8601 (2026-11-18T07:00:00+09:00, local time without offset) or relative (90m, 24h, 2d)")
    var since: String?

    @Option(name: .long, help: "Maximum number of history pages (~50 rows each) to load: older pages with --since, and separately newer pages when scrolling to the newest end")
    var maxPages: Int = 40

    @Option(name: .long, help: "Overall time budget in seconds; returns what was read so far when exceeded (default 180 with --since, 6 otherwise)")
    var timeoutSec: Double?

    @Flag(name: .long, help: "Show raw element info for debugging")
    var debug: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: [.short, .long], help: "Keep auto-opened chat window after read")
    var keepWindow: Bool = false

    @Flag(
        name: .long,
        help: "Do not activate, search, open, resize, or close KakaoTalk windows; only read already exposed matching chat windows"
    )
    var backgroundSafe: Bool = false

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Enable deep window recovery when fast window detection fails",
            visibility: .default
        )
    )
    var deepRecovery: Bool = false

    @Option(name: .long, help: "Window layout before reading: preserve, left, right, split-left, or split-right; offscreen moves the chat window off all displays while reading")
    var layout: ChatWindowLayoutMode = .preserve

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    func validate() throws {
        if let limit, limit < 1 {
            throw ValidationError("--limit must be at least 1.")
        }
        if let since, SinceParser.parse(since) == nil {
            throw ValidationError("--since must be ISO 8601 (e.g. 2026-11-18T07:00:00+09:00) or relative (90m, 24h, 2d).")
        }
        if maxPages < 0 {
            throw ValidationError("--max-pages must be 0 or greater.")
        }
        if let timeoutSec, timeoutSec <= 0 {
            throw ValidationError("--timeout-sec must be greater than 0.")
        }

        if let chatID, !chatID.isEmpty {
            guard chat == nil else {
                throw ValidationError("Chat name cannot be provided together with --chat-id.")
            }
            return
        }

        guard let chat, !chat.isEmpty else {
            throw ValidationError("Chat name is required unless --chat-id is provided.")
        }
    }

    func run() throws {
        let startedAt = Date()
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let frontmostKeeper = KakaoTalkApp.FrontmostAppKeeper(enabled: layout == .offscreen)
        // offscreen: keys go to KakaoTalk's process only, so it never has to come to the front.
        let runner = AXActionRunner(
            traceEnabled: traceAX,
            keyTargetPid: layout == .offscreen ? { KakaoTalkApp.runningApplication?.processIdentifier } : nil
        )
        let kakao = backgroundSafe
            ? try KakaoTalkApp(autoLaunch: false)
            : try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        // With no KakaoTalk window left, recovery brings the app forward; give the front back.
        defer {
            if frontmostKeeper.handFrontBack(from: kakao) {
                runner.log("offscreen: front handed back to the previous app")
            }
        }
        let chatWindowResolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            deepRecoveryEnabled: deepRecovery,
            layoutMode: layout,
            interactionMode: backgroundSafe ? .backgroundSafe : .allowUIAutomation
        )
        let transcriptReader = KakaoTalkTranscriptReader(
            kakao: kakao,
            runner: runner,
            interactionMode: backgroundSafe ? .backgroundSafe : .allowUIAutomation
        )

        let resolution: ChatWindowResolution
        let requestedChat: String
        do {
            if let chatID {
                requestedChat = chatID
                resolution = try chatWindowResolver.resolve(chatID: chatID)
            } else {
                let chat = chat ?? ""
                requestedChat = chat
                resolution = try chatWindowResolver.resolve(query: chat)
            }
        } catch {
            print("No chat window found for '\(requestedChat)'")
            print("Reason: \(error)")
            if backgroundSafe {
                print("Available windows: \(kakao.windows.count) title(s) hidden in background-safe mode")
            } else {
                print("\nAvailable windows:")
                for (index, window) in kakao.windows.enumerated() {
                    print("  [\(index)] \(window.title ?? "(untitled)")")
                }
            }
            throw ExitCode.failure
        }

        let window = resolution.window
        if resolution.openedViaSearch {
            runner.log("read: opening chat via search")
        } else if resolution.method == .openedViaChatList {
            runner.log("read: opening chat via chat list")
        }

        if resolution.openedTransiently {
            if keepWindow {
                runner.log("read: keep-window enabled; auto-opened window will be kept")
            } else {
                runner.log("read: auto-opened window will be closed after read")
            }
        } else {
            runner.log("read: found existing chat window")
        }

        // --layout offscreen: original position of a moved window. It is restored before the
        // window is closed too, because KakaoTalk reopens a chat where it was last closed.
        var offscreenOrigin: CGPoint?
        let restoreOffscreenWindow = {
            if let origin = offscreenOrigin {
                chatWindowResolver.restoreWindowPosition(window, to: origin)
            }
        }

        // A window this read opened is closed on a stop signal too, under the same title check
        // as the close below.
        let resolvedTitleAtOpen = window.title ?? ""
        let titleMatchesQuery = chatID != nil || resolvedTitleAtOpen.isEmpty
            || resolvedTitleAtOpen.localizedCaseInsensitiveContains(requestedChat)
        if resolution.openedTransiently && !keepWindow && titleMatchesQuery {
            chatWindowResolver.closeWindowOnStopSignal(window)
        }

        defer {
            restoreOffscreenWindow()
            chatWindowResolver.cancelCloseOnStopSignal(window)
            if resolution.openedTransiently && !keepWindow {
                let resolvedTitle = window.title ?? ""
                if chatID == nil && !resolvedTitle.isEmpty && !resolvedTitle.localizedCaseInsensitiveContains(requestedChat) {
                    runner.log("read: skipped auto-close because resolved title '\(resolvedTitle)' did not match query")
                } else if chatWindowResolver.closeWindow(window) {
                    runner.log("read: auto-opened chat window closed")
                } else {
                    runner.log("read: failed to close auto-opened chat window")
                }
            } else if resolution.openedTransiently && keepWindow {
                runner.log("read: auto-opened chat window kept by --keep-window")
            }
        }

        offscreenOrigin = chatWindowResolver.moveWindowOffscreen(window)
        // The reader finds the chat pane through KakaoTalk's focus, which an already open
        // window does not hold while KakaoTalk stays in the background.
        chatWindowResolver.takeKeysWithoutActivation(window)

        let sinceDate = since.flatMap { SinceParser.parse($0, now: startedAt) }
        let budgetSec = timeoutSec ?? (sinceDate != nil ? Self.defaultSinceTimeoutSec : Self.defaultRecentTimeoutSec)
        let deadline = startedAt.addingTimeInterval(budgetSec)
        let snapshot: TranscriptSnapshot
        var history: TranscriptHistoryInfo?
        do {
            if let sinceDate {
                let result = try transcriptReader.readSince(
                    from: window,
                    fallbackChatTitle: window.title ?? requestedChat,
                    since: sinceDate,
                    limit: limit ?? Self.defaultSinceLimit,
                    maxPages: maxPages,
                    deadline: deadline,
                    allowPaging: !backgroundSafe
                )
                snapshot = result.snapshot
                history = result.history
            } else {
                snapshot = try transcriptReader.readSnapshot(
                    from: window,
                    fallbackChatTitle: window.title ?? requestedChat,
                    limit: limit ?? Self.defaultLimit,
                    // background-safe never scrolls, so the newest end stays unchecked.
                    newestEnd: backgroundSafe ? nil : NewestEndOptions(maxLoads: maxPages, deadline: deadline)
                )
            }
        } catch TranscriptReadError.transcriptContextUnavailable {
            print("Could not locate chat transcript area.")
            print("Use 'kmsg inspect --window <n>' to inspect the opened chat window.")
            return
        } catch TranscriptReadError.noMessageRows {
            print("No message rows found in the chat transcript area.")
            print("Use 'kmsg inspect --window <n>' to inspect transcript structure.")
            return
        } catch TranscriptReadError.noReadableMessages {
            print("No message body text extracted from transcript container.")
            print("Use 'kmsg inspect --window <n>' to inspect message nodes.")
            return
        }

        if json {
            try printMessagesAsJSON(snapshot, history: history)
            return
        }

        print("Reading messages from: \(snapshot.chat)\n")
        if let history {
            print("Messages since \(SinceParser.format(history.since)) (\(snapshot.count)):")
            print("pages_loaded: \(history.pagesLoaded), oldest_reached: \(history.oldestReached), newest_reached: \(snapshot.newestReached.map { String($0) } ?? "null"), truncated: \(history.truncated), stop_reason: \(history.stopReason.rawValue)\n")
        } else {
            print("Recent messages (\(snapshot.count)), newest_reached: \(snapshot.newestReached.map { String($0) } ?? "null"):\n")
        }
        for (index, message) in snapshot.messages.enumerated() {
            if debug {
                print("[\(index + 1)] author=\(message.author ?? "(me)") time=\(message.timeRaw ?? "unknown") body=\(message.body)")
                continue
            }

            print("[\(index + 1)] author: \(message.author ?? "(me)")")
            print("    time: \(message.timeRaw ?? "unknown")")
            print("    body: \(message.body)")
            print("")
        }
    }

    private func printMessagesAsJSON(_ snapshot: TranscriptSnapshot, history: TranscriptHistoryInfo?) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let payload = ReadJSONResponse(
            chat: snapshot.chat,
            fetchedAt: formatter.string(from: snapshot.fetchedAt),
            count: snapshot.count,
            messages: snapshot.messages,
            newestReached: snapshot.newestReached,
            since: history.map { SinceParser.format($0.since) },
            oldestReached: history?.oldestReached,
            truncated: history?.truncated,
            pagesLoaded: history?.pagesLoaded,
            stopReason: history?.stopReason
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
