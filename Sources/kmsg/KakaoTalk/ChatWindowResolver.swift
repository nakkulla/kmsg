import ApplicationServices.HIServices
import Foundation

enum ChatWindowLayoutMode: String {
    case preserve
    case left
    case right
    case splitLeft = "split-left"
    case splitRight = "split-right"
    /// Keep the size, but move the chat window off every display while reading.
    case offscreen

    /// Whether `standardizeReadableWindow` resizes/moves windows on screen.
    var resizesWindows: Bool {
        self != .preserve && self != .offscreen
    }

    var isRightAligned: Bool {
        self == .right || self == .splitRight
    }

    var isSplit: Bool {
        self == .splitLeft || self == .splitRight
    }
}

enum ChatWindowResolutionMethod {
    case existingWindow
    case openedViaChatList
    case openedViaSearch
}

enum ChatWindowInteractionMode {
    case allowUIAutomation
    case backgroundSafe
}

struct ChatWindowResolution {
    let window: UIElement
    let method: ChatWindowResolutionMethod

    var openedViaSearch: Bool {
        method == .openedViaSearch
    }

    var openedTransiently: Bool {
        method != .existingWindow
    }
}

private enum ChatWindowFailureCode: String {
    case backgroundSafeBlocked = "BACKGROUND_SAFE_BLOCKED"
    case focusFail = "FOCUS_FAIL"
    case inputNotReflected = "INPUT_NOT_REFLECTED"
    case windowNotReady = "WINDOW_NOT_READY"
    case searchMiss = "SEARCH_MISS"
}

private struct SearchScanProfile {
    let label: String
    let timeout: TimeInterval
    let pollInterval: TimeInterval
    let rowLimit: Int
    let cellLimit: Int
    let supplementalLimit: Int
    let candidateNodeBudget: Int
    let textLimit: Int
    let textNodeBudget: Int
    let includeSupplementalRoles: Bool
    let includeApplicationRoot: Bool
}

private struct SearchCandidate {
    let element: UIElement
    let textScore: Int
    let matchedText: String
    /// Screen point captured while the element was still fresh. KakaoTalk invalidates
    /// search-result AX handles within a few hundred ms, so the coordinate must be read
    /// at scan time, not at click time.
    let clickPoint: CGPoint?
}

/// A chat window the resolver already moved off the displays the moment it opened,
/// with the origin the caller's `moveWindowOffscreen` hands back for the restore.
private final class EarlyOffscreenMove {
    var window: UIElement?
    var origin: CGPoint?
}

/// Windows currently parked off the displays, and windows this call opened and owes a
/// close. A stop signal puts the former back and closes the latter before the process
/// exits: the MCP server terminates a call that runs over its time budget, and `defer`
/// does not run then.
private final class OffscreenParking: @unchecked Sendable {
    static let shared = OffscreenParking()

    private let lock = NSLock()
    private var parked: [(window: UIElement, origin: CGPoint)] = []
    private var closeOnStop: [UIElement] = []
    private var signalSources: [DispatchSourceSignal] = []

    func park(_ window: UIElement, origin: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        installSignalSources()
        parked.append((window, origin))
    }

    func unpark(_ window: UIElement) {
        lock.lock()
        defer { lock.unlock() }
        parked.removeAll { CFEqual($0.window.axElement, window.axElement) }
    }

    func closeOnStop(_ window: UIElement) {
        lock.lock()
        defer { lock.unlock() }
        installSignalSources()
        closeOnStop.append(window)
    }

    func cancelCloseOnStop(_ window: UIElement) {
        lock.lock()
        defer { lock.unlock() }
        closeOnStop.removeAll { CFEqual($0.axElement, window.axElement) }
    }

    /// Caller holds `lock`.
    private func installSignalSources() {
        guard signalSources.isEmpty else { return }
        for stopSignal in [SIGTERM, SIGINT] {
            signal(stopSignal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: stopSignal, queue: .global())
            source.setEventHandler { [self] in
                restoreAll()
                closeAll()
                exit(128 + stopSignal)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func restoreAll() {
        lock.lock()
        defer { lock.unlock() }
        for entry in parked {
            try? entry.window.setPosition(entry.origin)
        }
    }

    /// Presses each owed window's own close button, which works without KakaoTalk in front.
    /// Nothing waits for the window to go: the caller that sent the signal waits only briefly.
    private func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        for window in closeOnStop {
            guard let closeButton: AXUIElement = window.attributeOptional(kAXCloseButtonAttribute) else {
                continue
            }
            try? UIElement(closeButton).press()
        }
    }
}

struct ChatWindowResolver {
    private static let minimumReadableWindowSize = CGSize(width: 760, height: 900)
    private static let minimumSplitWindowSize = CGSize(width: 520, height: 680)
    private static let maximumAutomaticWindowSize = CGSize(width: 1200, height: 1000)

    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner
    private let useCache: Bool
    private let deepRecoveryEnabled: Bool
    private let layoutMode: ChatWindowLayoutMode
    private let interactionMode: ChatWindowInteractionMode
    private let earlyOffscreenMove = EarlyOffscreenMove()

    init(
        kakao: KakaoTalkApp,
        runner: AXActionRunner,
        useCache: Bool = true,
        deepRecoveryEnabled: Bool = false,
        layoutMode: ChatWindowLayoutMode = .preserve,
        interactionMode: ChatWindowInteractionMode = .allowUIAutomation
    ) {
        self.kakao = kakao
        self.runner = runner
        self.useCache = useCache
        self.deepRecoveryEnabled = deepRecoveryEnabled
        self.layoutMode = layoutMode
        self.interactionMode = interactionMode
    }

    /// `--layout offscreen` keeps KakaoTalk out of the user's way: windows stay off the
    /// displays, KakaoTalk is not brought to the front, and nothing is clicked.
    private var unobtrusive: Bool {
        layoutMode == .offscreen && interactionMode == .allowUIAutomation
    }

    private func bringForward(_ window: UIElement) {
        guard !unobtrusive else { return }
        kakao.activate()
        _ = tryRaiseWindow(window)
    }

    /// offscreen: makes `window` the one KakaoTalk routes keys and focus to, without
    /// bringing KakaoTalk to the front. Keys posted to the process go to its focused
    /// window, so another open chat would receive them otherwise. AXRaise lifts the
    /// window above other apps' inactive windows, so it runs only when the window does
    /// not hold the focus already, and callers move the window off the displays first.
    /// Returns true outside the offscreen layout. Holding the focus does not guarantee
    /// that text keys arrive (they do not while the user types in another app), so
    /// callers confirm the effect of each key and sending uses no keys at all.
    @discardableResult
    func takeKeysWithoutActivation(_ window: UIElement) -> Bool {
        guard unobtrusive else { return true }
        let holdsFocus = { kakao.focusedWindow.map { areSameAXElement($0, window) } ?? false }
        if holdsFocus() {
            return true
        }
        _ = tryRaiseWindow(window)
        let taken = runner.waitUntil(label: "window takes keys", timeout: 0.5, pollInterval: 0.04, condition: holdsFocus)
        if !taken {
            runner.log("offscreen: window '\(window.title ?? "")' did not take KakaoTalk's focus")
        }
        return taken
    }

    func resolve(query: String) throws -> ChatWindowResolution {
        if interactionMode == .backgroundSafe {
            return try resolveExistingWindowOnly(query: query)
        }

        let usableWindow = try requireUsableWindow()

        if let existingWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            standardizeReadableWindow(existingWindow, label: "existing chat window")
            return ChatWindowResolution(window: existingWindow, method: .existingWindow)
        }

        let searchWindow = selectSearchWindow(fallback: usableWindow)
        standardizeReadableWindow(searchWindow, label: "search root window")
        let chatWindow = try openChatViaSearch(query: query, in: searchWindow, fallbackWindow: usableWindow)
        standardizeReadableWindow(chatWindow, label: "opened chat window")
        return ChatWindowResolution(window: chatWindow, method: .openedViaSearch)
    }

    func resolve(chatID: String) throws -> ChatWindowResolution {
        guard let record = ChatIdentityRegistryStore.shared.record(for: chatID) else {
            throw KakaoTalkError.elementNotFound("Unknown chat_id '\(chatID)'. Run 'kmsg chats' first to refresh the local registry.")
        }

        if interactionMode == .backgroundSafe {
            return try resolveExistingWindowOnly(query: record.displayName)
        }

        let usableWindow = try requireUsableWindow()
        let query = record.displayName

        if let existingWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            standardizeReadableWindow(existingWindow, label: "existing chat window")
            return ChatWindowResolution(window: existingWindow, method: .existingWindow)
        }

        if let chatListWindow = kakao.chatListWindow,
           let chatWindow = openChatListRow(
               chatID: chatID,
               normalizedName: record.normalizedName,
               query: query,
               in: chatListWindow,
               fallbackWindow: usableWindow
           )
        {
            standardizeReadableWindow(chatWindow, label: "opened chat window")
            return ChatWindowResolution(window: chatWindow, method: .openedViaChatList)
        }

        runner.log("chat_id: falling back to search for '\(query)'")
        let searchWindow = selectSearchWindow(fallback: usableWindow)
        standardizeReadableWindow(searchWindow, label: "search root window")
        let chatWindow = try openChatViaSearch(query: query, in: searchWindow, fallbackWindow: usableWindow)
        standardizeReadableWindow(chatWindow, label: "opened chat window")
        return ChatWindowResolution(window: chatWindow, method: .openedViaSearch)
    }

    @discardableResult
    func closeWindow(_ window: UIElement) -> Bool {
        let closeAction = "AXClose"

        bringForward(window)

        if supportsAction(closeAction, on: window) {
            do {
                try window.performAction(closeAction)
                if waitForWindowClosed(window, label: "close via AXClose") {
                    return true
                }
            } catch {
                runner.log("close window: AXClose failed (\(error))")
            }
        }

        // The window's own close button works without KakaoTalk being frontmost.
        if let standardClose: AXUIElement = window.attributeOptional(kAXCloseButtonAttribute) {
            do {
                try UIElement(standardClose).press()
                if waitForWindowClosed(window, label: "close via AXCloseButton") {
                    return true
                }
            } catch {
                runner.log("close window: AXCloseButton press failed (\(error))")
            }
        }

        if let closeButton = findCloseButton(in: window) {
            do {
                try closeButton.press()
                if waitForWindowClosed(window, label: "close via button") {
                    return true
                }
            } catch {
                runner.log("close window: button press failed (\(error))")
            }
        }

        // cmd+W closes whichever KakaoTalk window takes keys; without KakaoTalk in front
        // that cannot be confirmed to be this one.
        guard !unobtrusive else {
            runner.log("close window: cmd+w fallback skipped (offscreen layout)")
            return false
        }

        runner.log("close window: fallback via cmd+w")
        runner.pressCommandW()
        return waitForWindowClosed(window, label: "close via cmd+w")
    }

    private func resolveExistingWindowOnly(query: String) throws -> ChatWindowResolution {
        if let existingWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            runner.log("background-safe: matched already exposed chat window")
            return ChatWindowResolution(window: existingWindow, method: .existingWindow)
        }

        if let focusedWindow = kakao.focusedWindow,
           let title = focusedWindow.title,
           scoreQueryMatch(query: query, candidateText: title) > 0
        {
            runner.log("background-safe: matched already focused chat window")
            return ChatWindowResolution(window: focusedWindow, method: .existingWindow)
        }

        throw KakaoTalkError.elementNotFound(
            "[\(ChatWindowFailureCode.backgroundSafeBlocked.rawValue)] No already exposed chat window matched '\(query)'. " +
            "Background-safe mode does not activate KakaoTalk, open chat rows, search, resize, or close windows."
        )
    }

    private func requireUsableWindow() throws -> UIElement {
        if let immediateWindow = kakao.focusedWindow ?? kakao.mainWindow ?? kakao.windows.first {
            runner.log("Usable window found via immediate probe")
            return immediateWindow
        }

        if let usableWindow = kakao.ensureMainWindow(timeout: 0.9, mode: .fast, trace: { message in
            runner.log(message)
        }) {
            return usableWindow
        }

        runner.log("window fast path failed; attempting one-shot open defense")
        if let usableWindow = attemptQuickOpenDefense(forceOpenEvenIfWindowPresent: !deepRecoveryEnabled) {
            return usableWindow
        }

        guard deepRecoveryEnabled else {
            runner.log("window fast path failed; deep recovery disabled")
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.windowNotReady.rawValue)] Usable KakaoTalk window unavailable (fast mode)")
        }

        runner.log("window: escalating to full recovery (3.0s)")
        if let usableWindow = kakao.ensureMainWindow(timeout: 3.0, mode: .recovery, trace: { message in
            runner.log(message)
        }) {
            return usableWindow
        }

        throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.windowNotReady.rawValue)] Usable KakaoTalk window unavailable")
    }

    private func attemptQuickOpenDefense(forceOpenEvenIfWindowPresent: Bool) -> UIElement? {
        runner.log("window: quick-open defense start")

        let hasVisibleWindow = kakao.focusedWindow != nil || kakao.mainWindow != nil || !kakao.windows.isEmpty
        if forceOpenEvenIfWindowPresent || !hasVisibleWindow {
            if KakaoTalkApp.isRunning {
                if hasVisibleWindow && forceOpenEvenIfWindowPresent {
                    runner.log("window: forcing open /Applications/KakaoTalk.app (fast-mode fallback)")
                } else {
                    runner.log("window: no visible windows; forcing open /Applications/KakaoTalk.app")
                }
                _ = KakaoTalkApp.forceOpen(timeout: 0.8)
            } else {
                runner.log("window: KakaoTalk not running; launching")
                _ = KakaoTalkApp.launch(timeout: 0.8)
            }
        } else {
            runner.log("window: quick-open defense skipped (windows already present)")
        }

        kakao.activate()
        if let usableWindow = kakao.ensureMainWindow(timeout: 0.8, mode: .fast, trace: { message in
            runner.log(message)
        }) {
            runner.log("window: quick-open defense succeeded")
            return usableWindow
        }

        runner.log("window: quick-open defense failed")
        return nil
    }

    private func selectSearchWindow(fallback: UIElement) -> UIElement {
        if let chatListWindow = kakao.chatListWindow {
            runner.log("search root selected: chatListWindow")
            return chatListWindow
        }
        if let mainWindow = kakao.mainWindow {
            runner.log("search root selected: mainWindow")
            return mainWindow
        }
        runner.log("search root selected: fallback usable window")
        return fallback
    }

    private func openChatViaSearch(query: String, in rootWindow: UIElement, fallbackWindow: UIElement) throws -> UIElement {
        runner.log("search: locating search field")

        // offscreen: the main window leaves the displays for the lookup and returns on every exit.
        // A minimized main window (the Hermes relay minimizes it after every call) comes up
        // while it is searched; it is minimized again off the displays before it moves back.
        let rootWasMinimized: Bool = unobtrusive ? (rootWindow.attributeOptional(kAXMinimizedAttribute) ?? false) : false
        let rootOrigin = unobtrusive ? moveWindowOffscreen(rootWindow) : nil
        defer {
            if let rootOrigin {
                if rootWasMinimized {
                    try? rootWindow.setAttribute(kAXMinimizedAttribute, value: true as CFBoolean)
                    runner.log("offscreen: main window minimized again")
                }
                restoreWindowPosition(rootWindow, to: rootOrigin)
            }
        }
        guard takeKeysWithoutActivation(rootWindow) else {
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.focusFail.rawValue)] KakaoTalk main window could not take keys without coming to the front")
        }

        guard let searchField = locateSearchField(in: rootWindow) else {
            throw KakaoTalkError.elementNotFound("[\(ChatWindowFailureCode.searchMiss.rawValue)] Search field not found")
        }

        guard runner.focusWithVerification(searchField, label: "search field", attempts: 1) else {
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.focusFail.rawValue)] Could not focus search field")
        }

        // kmsg types the chat name into the main search field; put the field back on
        // every exit so the chat list is not left filtered (and later `chats` sees all rows).
        let originalSearchText = searchField.stringValue ?? ""
        // Resetting a stale results list below closes the search, so the field is located again.
        var queryField = searchField
        defer {
            // The field handle can go stale once the chat opens; re-locate it then.
            let field = queryField.role != nil ? queryField : (locateSearchField(in: rootWindow) ?? queryField)
            let resultsList = searchListSnapshot(in: rootWindow)
            restoreSearchField(field, typedQuery: query, originalValue: originalSearchText)
            releaseSearchResultsLeftBehind(field: field, resultsList: resultsList, in: rootWindow)
        }

        _ = runner.setTextWithVerification("", on: searchField, label: "search field clear", attempts: 1)
        if !originalSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Clearing a filtered list rebuilds it too; let that settle before the snapshot.
            Thread.sleep(forTimeInterval: 0.4)
        }
        var listBeforeInput = searchListSnapshot(in: rootWindow)

        let enterQuery = { (field: UIElement) -> Bool in
            self.runner.setTextWithVerification(query, on: field, label: "search field input", attempts: 1) ||
                self.runner.typeTextWithVerification(query, on: field, label: "search field input", attempts: 2)
        }

        guard enterQuery(searchField) else {
            dismissSearchAfterFailure()
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.inputNotReflected.rawValue)] Search keyword was not entered")
        }

        // The chat list keeps showing its unfiltered rows for a few hundred ms after the
        // query is typed. A row matched there is replaced by the search results, so wait
        // for the list to be rebuilt before scanning.
        let listRebuilt = waitForSearchListRebuild(since: listBeforeInput, in: rootWindow)

        // An empty field over a list that does not react to the query is an earlier search's
        // results left behind: its one row is already selected, so no arrow key can move the
        // selection and the open below would refuse it. It never clears by itself.
        if !listRebuilt,
           listBeforeInput.firstRow != nil,
           originalSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           resetSearchList(in: rootWindow)
        {
            runner.log("search: list ignored the query; reset the results left by an earlier search")
            guard let freshField = locateSearchField(in: rootWindow) else {
                throw KakaoTalkError.elementNotFound("[\(ChatWindowFailureCode.searchMiss.rawValue)] Search field not found")
            }
            queryField = freshField
            guard runner.focusWithVerification(queryField, label: "search field", attempts: 1) else {
                throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.focusFail.rawValue)] Could not focus search field")
            }
            _ = runner.setTextWithVerification("", on: queryField, label: "search field clear", attempts: 1)
            listBeforeInput = searchListSnapshot(in: rootWindow)
            guard enterQuery(queryField) else {
                dismissSearchAfterFailure()
                throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.inputNotReflected.rawValue)] Search keyword was not entered")
            }
            waitForSearchListRebuild(since: listBeforeInput, in: rootWindow)
        }

        let matchingCandidates = waitForMatchingSearchResults(query: query, rootWindow: rootWindow)
        guard let matchingResult = pickBestSearchResult(from: matchingCandidates) else {
            dismissSearchAfterFailure()
            throw KakaoTalkError.elementNotFound("[\(ChatWindowFailureCode.searchMiss.rawValue)] No search result found for '\(query)'")
        }

        let windowsBeforeOpen = kakao.windows
        let openTriggered = triggerSearchResultOpen(
            matchingResult,
            query: query,
            rootWindow: rootWindow,
            searchField: queryField
        ) {
            resolveOpenedChatWindowFast(query: query) != nil
        }
        guard openTriggered else {
            dismissSearchAfterFailure()
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.searchMiss.rawValue)] Could not open matched search result")
        }

        if let window = waitForOpenedChatWindow(query: query, fallbackWindow: fallbackWindow) {
            let isNewWindow = !windowsBeforeOpen.contains { areSameAXElement($0, window) }
            let titleMatches = scoreQueryMatch(query: query, candidateText: window.title ?? "") > 0
            if !isNewWindow || titleMatches {
                return window
            }
            runner.log("search: opened window title does not match '\(query)'; treating as wrong chat")
        }

        closeWindowsOpened(after: windowsBeforeOpen)
        throw KakaoTalkError.windowNotFound("[\(ChatWindowFailureCode.windowNotReady.rawValue)] Chat window for '\(query)' did not open")
    }

    /// Escape backs out of the search while KakaoTalk is frontmost. Posted to the process
    /// with the list focused it closes the main window instead, so offscreen leaves the
    /// cleanup to the search field restore.
    private func dismissSearchAfterFailure() {
        guard !unobtrusive else { return }
        runner.pressEscape()
    }

    private func openChatListRow(
        chatID: String,
        normalizedName: String,
        query: String,
        in chatListWindow: UIElement,
        fallbackWindow: UIElement
    ) -> UIElement? {
        runner.log("chat_id: scanning chat list rows")
        standardizeReadableWindow(chatListWindow, label: "chat list window")
        let scanner = ChatListScanner()
        let registry = ChatIdentityRegistryStore.shared
        // Only rows carrying this chat's name can be it; reading every row's preview first
        // outlasts the caller's time budget. With several chats of the same name on record
        // all of them are needed to tell them apart, so only a unique name stops at its row.
        let sameNameRecords = registry.recordCount(normalizedName: normalizedName)
        let snapshots = scanner.scan(
            in: chatListWindow,
            limit: 200,
            onlyNormalizedTitle: normalizedName,
            stopAfter: sameNameRecords == 1 ? 1 : nil,
            trace: { message in
                runner.log(message)
            }
        )
        guard !snapshots.isEmpty else {
            runner.log("chat_id: chat list scan found no row named like \(chatID)")
            return nil
        }

        let assignedIDs = registry.assignChatIDs(for: snapshots.map(\.discovery))
        guard let matchIndex = assignedIDs.firstIndex(of: chatID) else {
            runner.log("chat_id: no visible chat row matched \(chatID)")
            return nil
        }

        let row = snapshots[matchIndex].element
        runner.log("chat_id: matched row title='\(snapshots[matchIndex].discovery.title)'")
        kakao.activate()
        _ = tryRaiseWindow(chatListWindow)

        if triggerChatListRowOpen(row) {
            if let window = waitForOpenedChatWindow(query: query, fallbackWindow: fallbackWindow) {
                return window
            }
        }

        runner.log("chat_id: matched row did not open a chat window")
        return nil
    }

    private func triggerChatListRowOpen(_ row: UIElement) -> Bool {
        if tryActivateSearchResult(row, label: "chat list row") {
            return true
        }

        let selected = trySelectSearchResult(row, label: "chat list row")
        if !selected, let parent = row.parent, trySelectSearchResult(parent, label: "chat list row.parent") {
            runner.pressEnterKey()
            return true
        }

        if selected {
            runner.pressEnterKey()
            return true
        }

        return false
    }

    private func standardizeReadableWindow(_ window: UIElement, label: String) {
        guard interactionMode != .backgroundSafe else {
            runner.log("\(label): background-safe mode; preserving window focus, size, and position")
            return
        }

        bringForward(window)

        // preserve mode (default) keeps the user's window size/position untouched;
        // only bring it forward. Resizing is opt-in via --layout left/right.
        // offscreen moves only the resolved chat window (moveWindowOffscreen).
        guard layoutMode.resizesWindows else {
            return
        }

        guard let currentSize = window.size else {
            runner.log("\(label): size unavailable; skipping resize")
            return
        }
        let currentFrame = window.frame

        let targetSize = readableTargetSize(for: currentSize)
        guard targetSize != currentSize else {
            runner.log("\(label): size already readable \(Int(currentSize.width))x\(Int(currentSize.height))")
            if let layoutFrame = automaticLayoutFrame(for: window, preferredSize: targetSize, currentFrame: currentFrame) {
                applyWindowFrame(layoutFrame, to: window, label: label)
            }
            return
        }

        if let layoutFrame = automaticLayoutFrame(for: window, preferredSize: targetSize, currentFrame: currentFrame) {
            applyWindowFrame(layoutFrame, to: window, label: label)
        } else {
            do {
                try window.setSize(targetSize)
                if let currentPosition = currentFrame?.origin {
                    try? window.setPosition(currentPosition)
                }
                runner.log("\(label): resized to \(Int(targetSize.width))x\(Int(targetSize.height))")
                Thread.sleep(forTimeInterval: 0.08)
            } catch {
                runner.log("\(label): resize failed (\(error))")
            }
        }
    }

    private func readableTargetSize(for currentSize: CGSize) -> CGSize {
        CGSize(
            width: readableTargetDimension(
                current: currentSize.width,
                minimum: Self.minimumReadableWindowSize.width,
                automaticMaximum: Self.maximumAutomaticWindowSize.width
            ),
            height: readableTargetDimension(
                current: currentSize.height,
                minimum: Self.minimumReadableWindowSize.height,
                automaticMaximum: Self.maximumAutomaticWindowSize.height
            )
        )
    }

    private func readableTargetDimension(current: CGFloat, minimum: CGFloat, automaticMaximum: CGFloat) -> CGFloat {
        if current >= automaticMaximum {
            return current
        }

        return max(current, minimum)
    }

    private func automaticLayoutFrame(
        for window: UIElement,
        preferredSize: CGSize,
        currentFrame: CGRect?
    ) -> CGRect? {
        guard layoutMode.resizesWindows else {
            return nil
        }

        let currentFrame = currentFrame ?? window.frame ?? CGRect(origin: .zero, size: preferredSize)
        let screenFrame = screenFrame(containing: currentFrame) ?? CGDisplayBounds(CGMainDisplayID())
        let usableFrame = screenFrame.insetBy(dx: 24, dy: 24)
        guard usableFrame.width > 0, usableFrame.height > 0 else {
            return nil
        }

        if layoutMode.isSplit {
            return splitLayoutFrame(in: usableFrame)
        }

        let layoutSize = CGSize(
            width: min(
                max(preferredSize.width, Self.minimumReadableWindowSize.width),
                min(Self.maximumAutomaticWindowSize.width, usableFrame.width)
            ),
            height: min(
                max(preferredSize.height, Self.minimumReadableWindowSize.height),
                min(Self.maximumAutomaticWindowSize.height, usableFrame.height)
            )
        )
        let x = layoutMode.isRightAligned ? usableFrame.maxX - layoutSize.width : usableFrame.minX
        let y = min(max(currentFrame.minY, usableFrame.minY), usableFrame.maxY - layoutSize.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: layoutSize)
    }

    private func splitLayoutFrame(in usableFrame: CGRect) -> CGRect {
        let halfWidth = floor(usableFrame.width / 2)
        let width = min(
            max(halfWidth, min(Self.minimumSplitWindowSize.width, usableFrame.width)),
            usableFrame.width
        )
        let height = min(
            max(Self.minimumSplitWindowSize.height, usableFrame.height),
            usableFrame.height
        )
        let x = layoutMode.isRightAligned ? usableFrame.maxX - width : usableFrame.minX
        return CGRect(origin: CGPoint(x: x, y: usableFrame.minY), size: CGSize(width: width, height: height))
    }

    private func screenFrame(containing frame: CGRect) -> CGRect? {
        let referencePoint = CGPoint(x: frame.midX, y: frame.midY)
        return activeDisplayBounds().first { $0.contains(referencePoint) }
    }

    /// Bounds of every active display in global (AX, top-left origin) coordinates.
    private func activeDisplayBounds() -> [CGRect] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return []
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return []
        }

        return displays.prefix(Int(displayCount)).map(CGDisplayBounds)
    }

    // MARK: - Offscreen layout

    /// For `--layout offscreen`: moves the window past the bottom-right corner of the
    /// rightmost display so it does not cover the user's work. macOS clamps the position
    /// and keeps a small piece visible (about 40x32 at that corner, against a 40pt-wide
    /// full-height strip when moved sideways); that is accepted. Returns the original
    /// origin when the window was moved, for `restoreWindowPosition`.
    func moveWindowOffscreen(_ window: UIElement) -> CGPoint? {
        guard layoutMode == .offscreen, interactionMode == .allowUIAutomation else {
            return nil
        }
        if let early = earlyOffscreenMove.window, areSameAXElement(early, window), let origin = earlyOffscreenMove.origin {
            earlyOffscreenMove.window = nil
            earlyOffscreenMove.origin = nil
            return origin
        }
        guard let frame = window.frame else {
            runner.log("offscreen: window frame unavailable; leaving window in place")
            return nil
        }
        let displays = activeDisplayBounds()
        guard let first = displays.first else {
            runner.log("offscreen: display list unavailable; leaving window in place")
            return nil
        }
        // A run that was killed outright leaves its window parked. Its origin is lost, so
        // such a window goes back to the main display instead of to the corner again.
        var origin = frame.origin
        let visibleArea = displays.map { $0.intersection(frame) }.filter { !$0.isNull }.reduce(0) { $0 + $1.width * $1.height }
        if frame.width > 0, frame.height > 0, visibleArea < frame.width * frame.height * 0.25 {
            origin = CGPoint(x: first.minX + 80, y: first.minY + 80)
            runner.log("offscreen: window was already off the displays; it will return to \(Int(origin.x)),\(Int(origin.y))")
        }
        let rightmost = displays.max { $0.maxX < $1.maxX } ?? first
        let target = CGPoint(x: rightmost.maxX + 500, y: rightmost.maxY + 500)
        OffscreenParking.shared.park(window, origin: origin)
        do {
            try window.setPosition(target)
        } catch {
            OffscreenParking.shared.unpark(window)
            runner.log("offscreen: move failed (\(error))")
            return nil
        }
        Thread.sleep(forTimeInterval: 0.08)
        let landed = window.position.map { "\(Int($0.x)),\(Int($0.y))" } ?? "unknown"
        runner.log("offscreen: moved from \(Int(frame.minX)),\(Int(frame.minY)) toward \(Int(target.x)),\(Int(target.y)); now \(landed)")
        return origin
    }

    /// Marks a window this call opened so that a stop signal closes it; `defer` does not run then.
    func closeWindowOnStopSignal(_ window: UIElement) {
        OffscreenParking.shared.closeOnStop(window)
    }

    func cancelCloseOnStopSignal(_ window: UIElement) {
        OffscreenParking.shared.cancelCloseOnStop(window)
    }

    func restoreWindowPosition(_ window: UIElement, to origin: CGPoint) {
        OffscreenParking.shared.unpark(window)
        do {
            try window.setPosition(origin)
            runner.log("offscreen: restored window to \(Int(origin.x)),\(Int(origin.y))")
        } catch {
            runner.log("offscreen: restore failed (\(error))")
        }
    }

    // MARK: - Search field cleanup

    /// Puts the main search field back the way kmsg found it after kmsg typed `typedQuery`.
    /// Leaves it alone when its text is neither kmsg's query nor empty (the user changed it).
    func restoreSearchField(_ field: UIElement, typedQuery: String, originalValue: String) {
        let current = (field.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = typedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = originalValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == original {
            return
        }
        guard current == typed || current.isEmpty else {
            runner.log("search: field text changed by someone else; leaving it")
            return
        }

        if original.isEmpty, !current.isEmpty, let clearButton = searchClearButton(of: field) {
            do {
                try clearButton.press()
                runner.log("search: pressed search field clear button")
            } catch {
                runner.log("search: clear button press failed (\(error))")
            }
        }
        if (field.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != original {
            _ = runner.setTextWithVerification(originalValue, on: field, label: "search field restore", attempts: 2)
        }
    }

    private func searchClearButton(of field: UIElement) -> UIElement? {
        if let cancel: AXUIElement = field.attributeOptional("AXCancelButton") {
            return UIElement(cancel)
        }
        return field.children.first { child in
            guard child.role == kAXButtonRole else { return false }
            let subrole: String? = child.attributeOptional(kAXSubroleAttribute)
            if subrole == "AXCancelButton" {
                return true
            }
            let label = [child.title, child.axDescription, child.identifier]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return label.contains("cancel") || label.contains("clear") || label.contains("지우기") || label.contains("취소")
        }
    }

    /// Emptying the field does not always make KakaoTalk rebuild the list: the results of
    /// kmsg's search can stay, under an empty field, until the search is closed.
    private func releaseSearchResultsLeftBehind(field: UIElement, resultsList: SearchListSnapshot, in rootWindow: UIElement) {
        guard resultsList.firstRow != nil,
              (field.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }
        // Short on purpose: a list that is going to rebuild has done so by now, and reads run
        // under a caller's time limit.
        if waitForSearchListRebuild(since: resultsList, in: rootWindow, timeout: 0.15) {
            return
        }
        if resetSearchList(in: rootWindow) {
            runner.log("search: results stayed under the emptied field; reset the list")
        }
    }

    /// The main window's search button closes the search and brings the full list back.
    private func resetSearchList(in rootWindow: UIElement) -> Bool {
        guard let button = searchToggleButtons(in: rootWindow).first else {
            runner.log("search: no search button to reset the list with")
            return false
        }
        do {
            try button.press()
        } catch {
            runner.log("search: search button press failed (\(error))")
            return false
        }
        Thread.sleep(forTimeInterval: 0.2)
        return true
    }

    private func searchToggleButtons(in rootWindow: UIElement) -> [UIElement] {
        rootWindow.findAll(role: kAXButtonRole, limit: 24, maxNodes: 220).filter { button in
            let title = (button.title ?? "").lowercased()
            let description = (button.axDescription ?? "").lowercased()
            let identifier = (button.identifier ?? "").lowercased()

            if identifier == "friends" || identifier == "chatrooms" || identifier == "more" {
                return false
            }

            return title.contains("search")
                || title.contains("검색")
                || description.contains("search")
                || description.contains("검색")
                || identifier.contains("search")
        }
    }

    private func applyWindowFrame(_ frame: CGRect, to window: UIElement, label: String) {
        do {
            try window.setFrame(frame)
            runner.log("\(label): laid out \(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY))")
            Thread.sleep(forTimeInterval: 0.08)
        } catch {
            runner.log("\(label): layout failed (\(error)); falling back to size-only resize")
            do {
                try window.setSize(frame.size)
                Thread.sleep(forTimeInterval: 0.08)
            } catch {
                runner.log("\(label): resize fallback failed (\(error))")
            }
        }
    }

    private func resolveCachedElement(
        slot: AXPathSlot,
        root: UIElement,
        validate: (UIElement) -> Bool
    ) -> UIElement? {
        guard useCache else { return nil }
        return AXPathCacheStore.shared.resolve(
            slot: slot,
            root: root,
            validate: validate,
            trace: { message in
                runner.log(message)
            }
        )
    }

    private func rememberCachedElement(slot: AXPathSlot, root: UIElement, element: UIElement) {
        guard useCache else { return }
        AXPathCacheStore.shared.remember(
            slot: slot,
            root: root,
            element: element,
            trace: { message in
                runner.log(message)
            }
        )
    }

    private func locateSearchField(in rootWindow: UIElement) -> UIElement? {
        if let cachedSearchField = resolveCachedElement(
            slot: .searchField,
            root: rootWindow,
            validate: { field in
                field.isEnabled && field.role == kAXTextFieldRole
            }
        ) {
            return cachedSearchField
        }

        let initialFields = discoverSearchFieldCandidates(in: rootWindow)
        if let field = pickSearchField(from: initialFields) {
            rememberCachedElement(slot: .searchField, root: rootWindow, element: field)
            return field
        }

        let searchButtons = searchToggleButtons(in: rootWindow)

        for button in searchButtons.prefix(4) {
            do {
                try button.press()
                runner.log("search: pressed search-like button title='\(button.title ?? "")' id='\(button.identifier ?? "")'")
            } catch {
                runner.log("search: search-like button press failed (\(error))")
            }

            Thread.sleep(forTimeInterval: 0.08)
            let fields = discoverSearchFieldCandidates(in: rootWindow)
            if let field = pickSearchField(from: fields) {
                rememberCachedElement(slot: .searchField, root: rootWindow, element: field)
                return field
            }
        }

        return nil
    }

    private func discoverSearchFieldCandidates(in rootWindow: UIElement) -> [UIElement] {
        var fields: [UIElement] = []
        fields.append(contentsOf: rootWindow.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140))
        if let focusedWindow = kakao.focusedWindow {
            fields.append(contentsOf: focusedWindow.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140))
        }
        if let mainWindow = kakao.mainWindow {
            fields.append(contentsOf: mainWindow.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140))
        }
        return fields.filter { $0.isEnabled }
    }

    private func waitForMatchingSearchResults(query: String, rootWindow: UIElement) -> [SearchCandidate] {
        let fastProfile = SearchScanProfile(
            label: "fast",
            timeout: 0.22,
            pollInterval: 0.04,
            rowLimit: 24,
            cellLimit: 24,
            supplementalLimit: 0,
            candidateNodeBudget: 320,
            textLimit: 6,
            textNodeBudget: 80,
            includeSupplementalRoles: false,
            includeApplicationRoot: false
        )
        let expandedProfile = SearchScanProfile(
            label: "expanded",
            timeout: 0.75,
            pollInterval: 0.05,
            rowLimit: 120,
            cellLimit: 120,
            supplementalLimit: 80,
            candidateNodeBudget: 1_200,
            textLimit: 16,
            textNodeBudget: 220,
            includeSupplementalRoles: true,
            includeApplicationRoot: true
        )

        var matches: [SearchCandidate] = []
        let foundFast = runner.waitUntil(label: "search results (\(fastProfile.label))", timeout: fastProfile.timeout, pollInterval: fastProfile.pollInterval) {
            matches = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: fastProfile)
            return !matches.isEmpty
        }
        if !foundFast {
            matches = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: fastProfile)
        }
        if !matches.isEmpty {
            runner.log("search: matching candidates=\(matches.count) via \(fastProfile.label)")
            return matches
        }

        runner.log("search: no matches in fast scan; expanding search scope")
        let foundExpanded = runner.waitUntil(label: "search results (\(expandedProfile.label))", timeout: expandedProfile.timeout, pollInterval: expandedProfile.pollInterval) {
            matches = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: expandedProfile)
            return !matches.isEmpty
        }
        if !foundExpanded {
            matches = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: expandedProfile)
        }
        runner.log("search: matching candidates=\(matches.count)")
        return matches
    }

    private func findMatchingSearchResults(
        query: String,
        rootWindow: UIElement,
        profile: SearchScanProfile
    ) -> [SearchCandidate] {
        var roots: [UIElement] = [rootWindow]
        if let focusedWindow = kakao.focusedWindow {
            roots.append(focusedWindow)
        }
        if let mainWindow = kakao.mainWindow {
            roots.append(mainWindow)
        }
        if profile.includeApplicationRoot {
            roots.append(kakao.applicationElement)
        }
        roots = deduplicateElements(roots)

        var results: [SearchCandidate] = []
        for root in roots {
            var candidates: [UIElement] = []
            candidates.append(contentsOf: root.findAll(role: kAXRowRole, limit: profile.rowLimit, maxNodes: profile.candidateNodeBudget))
            candidates.append(contentsOf: root.findAll(role: kAXCellRole, limit: profile.cellLimit, maxNodes: profile.candidateNodeBudget))

            if profile.includeSupplementalRoles {
                candidates.append(contentsOf: root.findAll(role: kAXGroupRole, limit: profile.supplementalLimit, maxNodes: profile.candidateNodeBudget))
                candidates.append(contentsOf: root.findAll(role: kAXButtonRole, limit: profile.supplementalLimit, maxNodes: profile.candidateNodeBudget))
                candidates.append(contentsOf: root.findAll(role: kAXStaticTextRole, limit: profile.supplementalLimit, maxNodes: profile.candidateNodeBudget))
            }

            candidates = deduplicateElements(candidates)
            for candidate in candidates {
                let (matchScore, matchedText) = bestQueryMatch(
                    query: query,
                    in: candidate,
                    textLimit: profile.textLimit,
                    textNodeBudget: profile.textNodeBudget
                )
                guard matchScore > 0, let matchedText else { continue }
                let activationCandidate = activationTarget(for: candidate)
                // Capture the click coordinate now, while the handle is valid.
                let clickPoint = centerPoint(of: candidate.frame) ?? centerPoint(of: activationCandidate.frame)
                results.append(
                    SearchCandidate(
                        element: activationCandidate,
                        textScore: matchScore,
                        matchedText: matchedText,
                        clickPoint: clickPoint
                    )
                )
            }

            if !results.isEmpty && !profile.includeSupplementalRoles {
                break
            }
        }

        return deduplicateSearchCandidates(results)
    }

    private func waitForOpenedChatWindow(query: String, fallbackWindow: UIElement) -> UIElement? {
        var resolved: UIElement?
        _ = runner.waitUntil(label: "chat context ready", timeout: 0.8, pollInterval: 0.05, evaluateAfterTimeout: false) {
            resolved = resolveOpenedChatWindowFast(query: query)
            return resolved != nil
        }
        return resolved ?? resolveOpenedChatWindow(query: query, fallbackWindow: fallbackWindow)
    }

    private func resolveOpenedChatWindowFast(query: String) -> UIElement? {
        if let matchedWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            return matchedWindow
        }

        if let focusedWindow = kakao.focusedWindow,
           let title = focusedWindow.title,
           scoreQueryMatch(query: query, candidateText: title) > 0
        {
            return focusedWindow
        }

        return nil
    }

    private func resolveOpenedChatWindow(query: String, fallbackWindow: UIElement) -> UIElement? {
        if let fastWindow = resolveOpenedChatWindowFast(query: query) {
            return fastWindow
        }

        if let matchedWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            return matchedWindow
        }

        if let focusedWindow = kakao.focusedWindow, windowContainsLikelyChatInput(focusedWindow) {
            return focusedWindow
        }

        if windowContainsLikelyChatInput(fallbackWindow) {
            return fallbackWindow
        }

        if let mainWindow = kakao.mainWindow, windowContainsLikelyChatInput(mainWindow) {
            return mainWindow
        }

        return nil
    }

    private func windowContainsLikelyChatInput(_ window: UIElement) -> Bool {
        if window.findFirst(where: { element in
            guard element.isEnabled else { return false }
            return element.role == kAXTextAreaRole
        }) != nil {
            return true
        }

        return window.findFirst(where: { element in
            isLikelyMessageInputElement(element, in: window) && element.role != kAXTextFieldRole
        }) != nil
    }

    private func isLikelyMessageInputElement(_ element: UIElement, in window: UIElement? = nil) -> Bool {
        guard element.isEnabled else { return false }
        let role = element.role ?? ""
        if role == kAXTextAreaRole {
            return true
        }

        let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
        guard editable else { return false }
        guard role != kAXStaticTextRole && role != kAXImageRole else { return false }
        if role == kAXTextFieldRole, isLikelySearchField(element, in: window) {
            return false
        }
        return true
    }

    private func isLikelySearchField(_ element: UIElement, in window: UIElement?) -> Bool {
        let role = element.role ?? ""
        guard role == kAXTextFieldRole else { return false }

        let joinedText = [
            element.identifier ?? "",
            element.title ?? "",
            element.axDescription ?? "",
        ]
        .joined(separator: " ")
        .lowercased()

        if joinedText.contains("search") || joinedText.contains("검색") {
            return true
        }

        guard let windowFrame = window?.frame, let elementFrame = element.frame, windowFrame.height > 0 else {
            return false
        }

        if !isElementLikelyInsideWindow(elementFrame: elementFrame, windowFrame: windowFrame) {
            return true
        }

        let relativeY = (elementFrame.midY - windowFrame.minY) / windowFrame.height
        return relativeY < 0.5
    }

    private func pickBestSearchResult(from candidates: [SearchCandidate]) -> SearchCandidate? {
        guard !candidates.isEmpty else { return nil }
        let best = candidates.max { lhs, rhs in
            scoreSearchResult(lhs) < scoreSearchResult(rhs)
        }
        if let best {
            runner.log(
                "search: best result role='\(best.element.role ?? "unknown")' title='\(best.element.title ?? "")' textScore=\(best.textScore) matched='\(best.matchedText)' clickPoint=\(best.clickPoint.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "none")"
            )
        }
        return best
    }

    private func scoreSearchResult(_ candidate: SearchCandidate) -> Int {
        var score = candidate.textScore * 4
        let element = candidate.element
        if supportsAction("AXPress", on: element) {
            score += 4_000
        }
        if supportsAction("AXConfirm", on: element) {
            score += 3_000
        }
        if element.role == kAXRowRole {
            score += 1_600
        } else if element.role == kAXCellRole {
            score += 1_200
        } else if element.role == kAXButtonRole {
            score += 800
        }
        if let title = element.title, !title.isEmpty {
            score += 300
        }
        if element.role == nil || element.role?.isEmpty == true {
            score -= 2_000
        }
        // Prefer a visible, clickable row: KakaoTalk emits a collapsed h=0 section header
        // that matches the same text but has no clickable area.
        if candidate.clickPoint != nil {
            score += 200
        } else {
            score -= 5_000
        }
        return score
    }

    private func triggerSearchResultOpen(
        _ candidate: SearchCandidate,
        query: String,
        rootWindow: UIElement,
        searchField: UIElement,
        opened: () -> Bool
    ) -> Bool {
        if unobtrusive {
            return openSearchResultViaKeyboard(candidate, query: query, rootWindow: rootWindow, searchField: searchField, opened: opened)
        }

        let result = candidate.element
        var didTriggerAction = false

        if tryActivateSearchResult(result, label: "result") {
            didTriggerAction = true
            if runner.waitUntil(label: "search open confirm", timeout: 0.24, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened) {
                return true
            }
        }

        // Search-result rows only expose AXShowDefaultUI/AXShowAlternateUI and ignore
        // keyboard Enter, so a real double-click is the reliable way to open the chat.
        // The click is posted only when the row under the point right now matches the
        // query; a point that no longer holds that row (stale layout, ad banner, another
        // app on top) is never clicked, and the keyboard fallbacks below are skipped too.
        kakao.activate()
        guard let clickPoint = verifiedSearchResultClickPoint(candidate, query: query, rootWindow: rootWindow) else {
            runner.log("search: double-click skipped (no matching row under the click point)")
            return didTriggerAction
        }
        runner.mouseDoubleClick(at: clickPoint, label: "search result")
        didTriggerAction = true
        if runner.waitUntil(label: "search open confirm (double-click)", timeout: 0.6, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened) {
            return true
        }
        runner.log("search: direct activate miss; skipping heavy neighbor scan for speed")

        let selected = trySelectSearchResult(result, label: "result")
        if !selected, let parent = result.parent {
            let parentSelected = trySelectSearchResult(parent, label: "result.parent")
            didTriggerAction = didTriggerAction || parentSelected
        }
        didTriggerAction = didTriggerAction || selected
        if selected,
           runner.waitUntil(label: "search open confirm", timeout: 0.14, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened)
        {
            return true
        }

        if selected {
            kakao.activate()
            if runner.focusWithVerification(searchField, label: "search field confirm", attempts: 1) {
                runner.log("search: fallback confirm via Enter")
                runner.pressEnterKey()
                didTriggerAction = true
                if runner.waitUntil(label: "search open confirm", timeout: 0.18, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened) {
                    return true
                }
            } else {
                runner.log("search: fallback confirm skipped (search field focus failed)")
            }
        } else {
            runner.log("search: skipping Enter fallback because result selection was not available")
        }

        kakao.activate()
        if searchField.isFocused || runner.focusWithVerification(searchField, label: "search field confirm", attempts: 1) {
            runner.log("search: fallback confirm via Down+Enter")
            runner.pressDownArrowKey()
            Thread.sleep(forTimeInterval: 0.03)
            runner.pressEnterKey()
            didTriggerAction = true
            if runner.waitUntil(label: "search open confirm", timeout: 0.22, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened) {
                return true
            }
        } else {
            runner.log("search: Down+Enter skipped (search field focus unavailable)")
        }

        return didTriggerAction
    }

    /// offscreen layout: the main window is off the displays, so no point can be clicked.
    /// Arrow-down walks the result rows from the search field (KakaoTalk reports the
    /// selected row as AXSelected); Enter is sent only while the selected row is the
    /// matched one. Keys go to KakaoTalk's process only, never to the frontmost app.
    private func openSearchResultViaKeyboard(
        _ candidate: SearchCandidate,
        query: String,
        rootWindow: UIElement,
        searchField: UIElement,
        opened: () -> Bool
    ) -> Bool {
        guard runner.postsKeysToTargetOnly else {
            runner.log("search: keyboard open skipped (keys are not bound to KakaoTalk's process)")
            return false
        }
        guard searchField.isFocused || runner.focusWithVerification(searchField, label: "search field (keyboard open)", attempts: 1) else {
            runner.log("search: keyboard open skipped (search field focus unavailable)")
            return false
        }

        // The selection has to move on every arrow key, the first included: a row that was
        // selected beforehand proves nothing about where KakaoTalk routes the keys.
        var previous = selectedSearchRow(in: rootWindow)
        for step in 1...Self.keyboardOpenMaxSteps {
            runner.pressDownArrowKey()
            var selected: UIElement?
            _ = runner.waitUntil(label: "search row selection \(step)", timeout: 0.4, pollInterval: 0.02, evaluateAfterTimeout: false) {
                selected = selectedSearchRow(in: rootWindow)
                guard let selected else { return false }
                return previous.map { !areSameAXElement($0, selected) } ?? true
            }
            guard let selected, previous.map({ !areSameAXElement($0, selected) }) ?? true else {
                runner.log("search: keyboard open stopped at step \(step) (selection did not move)")
                return false
            }
            let match = bestQueryMatch(query: query, in: selected, textLimit: 6, textNodeBudget: 80)
            if match.score > 0, match.matchedText == candidate.matchedText {
                runner.log("search: row \(step) selected and matches; opening via Enter")
                runner.pressEnterKey()
                // The new window appears on a display; move it off at once, not after the
                // search field cleanup, so it only flashes.
                if runner.waitUntil(label: "search open confirm (keyboard)", timeout: 0.8, pollInterval: 0.02, evaluateAfterTimeout: false, condition: opened),
                   let openedWindow = resolveOpenedChatWindowFast(query: query),
                   let origin = moveWindowOffscreen(openedWindow)
                {
                    earlyOffscreenMove.window = openedWindow
                    earlyOffscreenMove.origin = origin
                }
                return true
            }
            previous = selected
        }
        runner.log("search: keyboard open found no selected row matching '\(query)'")
        return false
    }

    /// The matched row can sit below other results (friends, rooms with a longer name).
    private static let keyboardOpenMaxSteps = 40

    private func selectedSearchRow(in rootWindow: UIElement) -> UIElement? {
        rootWindow.findAll(role: kAXRowRole, limit: 48, maxNodes: 1500).first { row in
            (row.attributeOptional(kAXSelectedAttribute) as Bool?) ?? false
        }
    }

    // MARK: - Search list transition and click verification

    private struct SearchListSnapshot {
        let firstRow: UIElement?
        let tableFrame: CGRect?
    }

    private func searchListSnapshot(in rootWindow: UIElement) -> SearchListSnapshot {
        let firstRow = rootWindow.findAll(role: kAXRowRole, limit: 1, maxNodes: 600).first
        return SearchListSnapshot(firstRow: firstRow, tableFrame: firstRow?.parent?.frame)
    }

    /// KakaoTalk replaces the list's rows when it switches to search results: the old
    /// row handles die and the table frame changes. Returns once either is observed.
    @discardableResult
    private func waitForSearchListRebuild(since before: SearchListSnapshot, in rootWindow: UIElement, timeout: TimeInterval = 1.5) -> Bool {
        guard let oldFirstRow = before.firstRow else {
            runner.log("search: no list rows before input; skipping rebuild wait")
            return false
        }
        let rebuilt = runner.waitUntil(label: "search list rebuild", timeout: timeout, pollInterval: 0.04) {
            if oldFirstRow.role == nil {
                return true
            }
            return searchListSnapshot(in: rootWindow).tableFrame != before.tableFrame
        }
        if !rebuilt {
            runner.log("search: list rebuild not observed; relying on click-point verification")
        }
        return rebuilt
    }

    private func verifiedSearchResultClickPoint(
        _ candidate: SearchCandidate,
        query: String,
        rootWindow: UIElement
    ) -> CGPoint? {
        var point = clickableCenter(of: candidate.element) ?? candidate.clickPoint
        for attempt in 1...3 {
            if let point, isMatchingRowUnderPoint(point, query: query) {
                return point
            }
            runner.log("search: click point rejected on attempt \(attempt)")
            Thread.sleep(forTimeInterval: 0.12)
            let rescanned = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: Self.clickVerifyScanProfile)
            point = rescanned.max { scoreSearchResult($0) < scoreSearchResult($1) }?.clickPoint
        }
        if let point, isMatchingRowUnderPoint(point, query: query) {
            return point
        }
        return nil
    }

    private static let clickVerifyScanProfile = SearchScanProfile(
        label: "click-verify",
        timeout: 0.34,
        pollInterval: 0.04,
        rowLimit: 24,
        cellLimit: 24,
        supplementalLimit: 0,
        candidateNodeBudget: 320,
        textLimit: 6,
        textNodeBudget: 80,
        includeSupplementalRoles: false,
        includeApplicationRoot: false
    )

    /// Hit-tests the point: KakaoTalk must own the topmost element there, and that
    /// element must sit in a row or cell whose text matches the query.
    private func isMatchingRowUnderPoint(_ point: CGPoint, query: String) -> Bool {
        var kakaoPid: pid_t = 0
        AXUIElementGetPid(kakao.applicationElement.axElement, &kakaoPid)
        if let topmost = try? UIElement.systemWide().element(at: point) {
            var topmostPid: pid_t = 0
            AXUIElementGetPid(topmost.axElement, &topmostPid)
            if topmostPid != kakaoPid {
                runner.log("search: click point is covered by another app (pid \(topmostPid))")
                return false
            }
        }

        guard let hit = try? kakao.applicationElement.element(at: point) else {
            runner.log("search: hit-test failed at (\(Int(point.x)),\(Int(point.y)))")
            return false
        }
        var cursor: UIElement? = hit
        var hops = 0
        while let current = cursor, hops < 8 {
            let role = current.role
            if role == kAXRowRole || role == kAXCellRole,
               bestQueryMatch(query: query, in: current, textLimit: 6, textNodeBudget: 80).score > 0
            {
                return true
            }
            cursor = current.parent
            hops += 1
        }
        runner.log("search: element under click point is '\(hit.role ?? "unknown")', not a matching row")
        return false
    }

    /// Closes chat windows that appeared after `before` was captured (a wrong chat opened by kmsg).
    private func closeWindowsOpened(after before: [UIElement]) {
        for window in kakao.windows where !before.contains(where: { areSameAXElement($0, window) }) {
            runner.log("search: closing unexpected window opened by this lookup")
            closeWindow(window)
        }
    }

    private func tryActivateSearchResult(_ element: UIElement, label: String) -> Bool {
        if let actions = try? element.actionNames(), !actions.isEmpty {
            runner.log("search: \(label) actions=\(actions.joined(separator: ","))")
        }

        do {
            if supportsAction("AXPress", on: element) {
                try element.press()
                runner.log("search: \(label) activated via AXPress")
                return true
            }
        } catch {
            runner.log("search: \(label) AXPress failed (\(error))")
        }

        do {
            if supportsAction("AXConfirm", on: element) {
                try element.performAction("AXConfirm")
                runner.log("search: \(label) activated via AXConfirm")
                return true
            }
        } catch {
            runner.log("search: \(label) AXConfirm failed (\(error))")
        }

        return false
    }

    private func trySelectSearchResult(_ element: UIElement, label: String) -> Bool {
        do {
            try element.setAttribute("AXSelected", value: true as CFBoolean)
            runner.log("search: \(label) selected via AXSelected=true")
            return true
        } catch {
            runner.log("search: \(label) select failed (\(error))")
            return false
        }
    }

    private func supportsAction(_ action: String, on element: UIElement) -> Bool {
        guard let actions = try? element.actionNames() else { return false }
        return actions.contains(action)
    }

    private func findMatchingChatWindow(in windows: [UIElement], query: String) -> UIElement? {
        windows.compactMap { window -> (window: UIElement, score: Int)? in
            guard let title = window.title else { return nil }
            let score = scoreQueryMatch(query: query, candidateText: title)
            guard score > 0 else { return nil }
            return (window, score)
        }
        .max(by: { lhs, rhs in
            lhs.score < rhs.score
        })?
        .window
    }

    private func bestQueryMatch(
        query: String,
        in element: UIElement,
        textLimit: Int,
        textNodeBudget: Int
    ) -> (score: Int, matchedText: String?) {
        let candidateTexts = collectCandidateTexts(
            from: element,
            textLimit: textLimit,
            textNodeBudget: textNodeBudget
        )
        guard !candidateTexts.isEmpty else { return (0, nil) }

        var bestScore = 0
        var bestText: String?
        for candidateText in candidateTexts {
            let score = scoreQueryMatch(query: query, candidateText: candidateText)
            if score > bestScore {
                bestScore = score
                bestText = candidateText
            }
        }

        return (bestScore, bestText)
    }

    private func collectCandidateTexts(
        from element: UIElement,
        textLimit: Int,
        textNodeBudget: Int
    ) -> [String] {
        var texts: [String] = []

        func appendText(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            texts.append(trimmed)
        }

        appendText(element.title)
        appendText(element.stringValue)
        appendText(element.axDescription)

        let staticTexts = element.findAll(
            role: kAXStaticTextRole,
            limit: textLimit,
            maxNodes: textNodeBudget
        )
        for staticText in staticTexts {
            appendText(staticText.stringValue)
        }

        let textAreas = element.findAll(
            role: kAXTextAreaRole,
            limit: max(2, textLimit / 2),
            maxNodes: textNodeBudget
        )
        for textArea in textAreas {
            appendText(textArea.stringValue)
        }

        return deduplicateStringsPreservingOrder(texts)
    }

    private func scoreQueryMatch(query: String, candidateText: String) -> Int {
        let queryNormalized = normalizeSearchToken(query)
        let candidateNormalized = normalizeSearchToken(candidateText)
        guard !queryNormalized.isEmpty, !candidateNormalized.isEmpty else { return 0 }

        if queryNormalized == candidateNormalized {
            return 12_000
        }
        if candidateNormalized.hasPrefix(queryNormalized) {
            return 10_500
        }
        if candidateNormalized.contains(queryNormalized) {
            return 9_800
        }
        if queryNormalized.contains(candidateNormalized), candidateNormalized.count >= 2 {
            return 8_800
        }

        let queryVariants = honorificVariants(of: queryNormalized)
        let candidateVariants = honorificVariants(of: candidateNormalized)
        var best = 0

        for queryVariant in queryVariants where !queryVariant.isEmpty {
            for candidateVariant in candidateVariants where !candidateVariant.isEmpty {
                if queryVariant == candidateVariant {
                    best = max(best, 8_700)
                    continue
                }
                if candidateVariant.hasPrefix(queryVariant) {
                    best = max(best, 8_400)
                    continue
                }
                if candidateVariant.contains(queryVariant) {
                    best = max(best, 8_200)
                    continue
                }
                if queryVariant.contains(candidateVariant), candidateVariant.count >= 2 {
                    best = max(best, 7_900)
                }
            }
        }

        if best > 0 {
            return best
        }

        let minLength = min(queryNormalized.count, candidateNormalized.count)
        if minLength >= 2 {
            let shortest = queryNormalized.count <= candidateNormalized.count ? queryNormalized : candidateNormalized
            let longest = queryNormalized.count > candidateNormalized.count ? queryNormalized : candidateNormalized
            if longest.contains(shortest) {
                return 6_600
            }
        }

        return 0
    }

    private func normalizeSearchToken(_ text: String) -> String {
        let lowered = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(lowered.unicodeScalars.count)

        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFEFF {
                continue
            }
            if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
                continue
            }
            scalars.append(scalar)
        }

        return String(scalars)
    }

    private func honorificVariants(of text: String) -> [String] {
        let suffixes = ["선생님", "님", "씨"]
        var variants = Set<String>([text])
        for suffix in suffixes where text.hasSuffix(suffix) {
            let candidate = String(text.dropLast(suffix.count))
            if !candidate.isEmpty {
                variants.insert(candidate)
            }
        }
        return Array(variants)
    }

    private func deduplicateSearchCandidates(_ candidates: [SearchCandidate]) -> [SearchCandidate] {
        var unique: [SearchCandidate] = []
        unique.reserveCapacity(candidates.count)

        for candidate in candidates {
            if let index = unique.firstIndex(where: { existing in
                areSameAXElement(existing.element, candidate.element)
            }) {
                if candidate.textScore > unique[index].textScore {
                    unique[index] = candidate
                }
                continue
            }
            unique.append(candidate)
        }

        return unique
    }

    private func deduplicateElements(_ elements: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        unique.reserveCapacity(elements.count)
        for element in elements {
            if unique.contains(where: { existing in
                areSameAXElement(existing, element)
            }) {
                continue
            }
            unique.append(element)
        }

        return unique
    }

    private func deduplicateStringsPreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(values.count)

        for value in values {
            if seen.contains(value) {
                continue
            }
            seen.insert(value)
            unique.append(value)
        }

        return unique
    }

    /// Center of a frame, or nil if the frame is missing or too small to click reliably.
    private func centerPoint(of frame: CGRect?) -> CGPoint? {
        guard let frame, frame.width >= 4, frame.height >= 4 else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Live re-read fallback for a clickable screen point. Collapsed/zero-area rows
    /// (e.g. KakaoTalk's hidden section header) have no usable center, so descend to the
    /// first visible descendant before giving up. Prefer the point captured at scan time.
    private func clickableCenter(of element: UIElement) -> CGPoint? {
        if let point = centerPoint(of: element.frame) {
            return point
        }
        if let visible = element.findFirst(where: { child in
            centerPoint(of: child.frame) != nil
        }) {
            return centerPoint(of: visible.frame)
        }
        return nil
    }

    private func activationTarget(for element: UIElement) -> UIElement {
        if isSearchActivationRole(element.role) {
            return element
        }

        var cursor = element.parent
        var hops = 0
        while let current = cursor, hops < 4 {
            if isSearchActivationRole(current.role) {
                return current
            }
            cursor = current.parent
            hops += 1
        }

        return element
    }

    private func isSearchActivationRole(_ role: String?) -> Bool {
        switch role {
        case kAXRowRole, kAXCellRole, kAXButtonRole, kAXGroupRole:
            return true
        default:
            return false
        }
    }

    private func pickSearchField(from fields: [UIElement]) -> UIElement? {
        fields
            .filter { $0.isEnabled }
            .sorted { lhs, rhs in
                let lhsY = lhs.position?.y ?? .greatestFiniteMagnitude
                let rhsY = rhs.position?.y ?? .greatestFiniteMagnitude
                return lhsY < rhsY
            }
            .first
    }

    private func tryRaiseWindow(_ window: UIElement) -> Bool {
        if supportsAction(kAXRaiseAction, on: window) {
            do {
                try window.performAction(kAXRaiseAction)
                runner.log("window: raised via AXRaise")
                return true
            } catch {
                runner.log("window: AXRaise failed (\(error))")
            }
        }
        return false
    }

    private func findCloseButton(in window: UIElement) -> UIElement? {
        let buttons = window.findAll(role: kAXButtonRole, limit: 6, maxNodes: 80)
        if let match = buttons.first(where: { button in
            let joined = [
                button.identifier ?? "",
                button.title ?? "",
                button.axDescription ?? "",
            ].joined(separator: " ").lowercased()
            return joined.contains("close") || joined.contains("닫기")
        }) {
            return match
        }

        return buttons.first
    }

    private func waitForWindowClosed(_ window: UIElement, label: String) -> Bool {
        runner.waitUntil(label: label, timeout: 0.9, pollInterval: 0.06, evaluateAfterTimeout: false) {
            !kakao.windows.contains { candidate in
                areSameAXElement(candidate, window)
            }
        }
    }

    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }

    private func isElementLikelyInsideWindow(elementFrame: CGRect, windowFrame: CGRect) -> Bool {
        let expandedWindow = windowFrame.insetBy(dx: -24, dy: -24)
        return expandedWindow.intersects(elementFrame)
    }
}
