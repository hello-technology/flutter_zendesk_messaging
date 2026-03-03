import UIKit
import ZendeskSDK
import ZendeskSDKMessaging
import Flutter
import UserNotifications

// MARK: - ZendeskMessaging

public final class ZendeskMessaging: NSObject {

    // MARK: - Properties

    private weak var flutterPlugin: SwiftZendeskMessagingPlugin?
    private let channel: FlutterMethodChannel

    /// Prevents simultaneous presentation attempts.
    private var isPresenting = false

    /// Cached logged-in user (set on loginUser success).
    private var cachedUser: [String: Any?]?

    /// Last known connection status (updated via events).
    private var lastConnectionStatus: String = "unknown"

    /// Max retries × interval = 20 × 150 ms = 3 s window for the SDK to finish laying out.
    private static let composerHideMaxRetries = 20
    private static let composerHideRetryInterval: TimeInterval = 0.15

    // MARK: - Init

    init(flutterPlugin: SwiftZendeskMessagingPlugin, channel: FlutterMethodChannel) {
        self.flutterPlugin = flutterPlugin
        self.channel = channel
        super.init()
    }

    // MARK: - SDK Initialization

    func initialize(channelKey: String, flutterResult: @escaping FlutterResult) {
        Zendesk.initialize(
            withChannelKey: channelKey,
            messagingFactory: DefaultMessagingFactory()
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.flutterPlugin?.isInitialized = true
                    self.setupEventObserver()
                    self.setupPushNotifications()
                    flutterResult(nil)
                case .failure(let error):
                    flutterResult(FlutterError(
                        code: "initialize_error",
                        message: error.localizedDescription,
                        details: nil))
                }
            }
        }
    }

    // MARK: - Presentation Helpers

    /// Parse the Dart viewMode string into a UIModalPresentationStyle.
    private func presentationStyle(for viewMode: String?) -> UIModalPresentationStyle {
        switch viewMode {
        case "fullscreen":   return .fullScreen
        case "sheet":        return .pageSheet
        case "pageSheet":    return .pageSheet
        case "formSheet":    return .formSheet
        default:             return .automatic
        }
    }

    /// Returns true when the Dart exitAction string maps to returnToConversationList.
    private func wantsReturnToList(_ exitAction: String?) -> Bool {
        return exitAction == "return_to_conversation_list"
    }

    /// Present a messaging view controller modally, then call result.
    /// When `readOnly` is true, immediately kicks off a retry loop that
    /// keeps searching for and hiding the composer input bar.
    private func present(
    viewController vc: UIViewController,
    on root: UIViewController?,
    viewMode: String?,
    readOnly: Bool = false,
    flutterResult: @escaping FlutterResult
    ) {
        guard !isPresenting else {
            flutterResult(FlutterError(
                code: "show_error",
                message: "Messaging UI is already being presented",
                details: nil))
            return
        }
        guard let root = root else {
            flutterResult(FlutterError(
                code: "presentation_error",
                message: "No root view controller available",
                details: nil))
            return
        }

        isPresenting = true

        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = presentationStyle(for: viewMode)
        root.present(nav, animated: true) { [weak self, weak nav] in
            self?.isPresenting = false
            flutterResult(nil)
            // Start hiding after animation; pass `nav` so we search the
            // fully-presented container, not the inner VC before it is added
            // to the hierarchy.
//            if readOnly, let nav {
//                self?.retryReadOnly(in: nav, attemptsLeft: ZendeskMessaging.composerHideMaxRetries)
//            }
            if readOnly, let nav {
                self?.forceHideComposerContinuously(in: nav)
            }
        }
    }

    private func forceHideComposerContinuously(in vc: UIViewController) {
        // Immediate attempt
        retryReadOnly(in: vc, attemptsLeft: 50)

        // Keep enforcing every 1 second for ~10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak vc] in
            guard let self = self, let vc = vc else { return }
            self.forceHideComposerContinuously(in: vc)
        }
    }
    // MARK: - Composer Hiding
    //
    // The Zendesk SDK's internal framework determines which UIKit input type
    // backs the composer text field:
    //
    //   • Older UIKit-based SDK  →  UITextView  (isEditable = true)
    //   • Newer SwiftUI-based SDK → UITextField  (SwiftUI TextField renders
    //                               through UITextField, not UITextView)
    //
    // We try all three strategies in order, then give up gracefully:
    //   1. UITextField        — SwiftUI path (most common in current SDK)
    //   2. UITextView         — UIKit path (older SDK builds)
    //   3. Position-based     — last resort; finds the bottommost small
    //                           interactive view without caring about type

    private func retryReadOnly(in vc: UIViewController, attemptsLeft: Int) {
        guard attemptsLeft > 0 else {
            print("[ZendeskMessaging] retryReadOnly — gave up after all attempts")
            return
        }
        if tryReadOnly(in: vc) { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + ZendeskMessaging.composerHideRetryInterval) { [weak self, weak vc] in
            guard let self, let vc else { return }
            self.retryReadOnly(in: vc, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Searches [vc] and every descendant VC depth-first.
    /// Returns `true` when the composer bar is found and hidden.
    @discardableResult
    private func tryReadOnly(in vc: UIViewController) -> Bool {
        if applyReadOnly(to: vc.view, vc: vc) { return true }
        for child in vc.children {
            if tryReadOnly(in: child) { return true }
        }
        return false
    }

    /// Runs all three hiding strategies against [rootView].
    private func applyReadOnly(to rootView: UIView, vc: UIViewController) -> Bool {
        // Strategy 1 – UITextField (SwiftUI / newer Zendesk SDK)
        if let field = findFirstTextField(in: rootView) {
            print("[ZendeskMessaging] strategy=UITextField in \(type(of: vc))")
            return hideComposerContainer(of: field, rootView: rootView)
        }
        // Strategy 2 – UITextView isEditable (UIKit / older SDK)
        if let tv = findFirstEditableTextView(in: rootView) {
            print("[ZendeskMessaging] strategy=UITextView in \(type(of: vc))")
            return hideComposerContainer(of: tv, rootView: rootView)
        }
        // Strategy 3 – position-based: bottom-most small interactive view
        if let bottomView = findBottomComposerView(in: rootView) {
            print("[ZendeskMessaging] strategy=positionBased \(type(of: bottomView)) h=\(Int(bottomView.bounds.height))")
            bottomView.alpha = 0
            bottomView.isUserInteractionEnabled = false
            return true
        }
        return false
    }

    /// Hides the composer container that directly owns [inputView].
    /// If that container is suspiciously tall (> 45 % of rootView height),
    /// climbs one level higher. Uses alpha + disabling interaction instead of
    /// isHidden so that any SDK-driven layout updates have no visual effect.
    @discardableResult
    private func hideComposerContainer(of inputView: UIView, rootView: UIView) -> Bool {
        guard let container = inputView.superview else { return false }
        let rootH = rootView.bounds.height
        let target: UIView
        if rootH > 0 && container.bounds.height > rootH * 0.45 {
            target = container.superview ?? container
        } else {
            target = container
        }
        target.alpha = 0
        target.isUserInteractionEnabled = false
        print("[ZendeskMessaging] hideComposerContainer — hid \(type(of: target)) h=\(Int(target.bounds.height))")
        return true
    }

    // MARK: - View Search Helpers

    /// Depth-first search: first UITextField anywhere in the subtree.
    private func findFirstTextField(in view: UIView) -> UITextField? {
        if let tf = view as? UITextField { return tf }
        for sub in view.subviews {
            if let found = findFirstTextField(in: sub) { return found }
        }
        return nil
    }

    /// Depth-first search: first UITextView with isEditable == true.
    private func findFirstEditableTextView(in view: UIView) -> UITextView? {
        if let tv = view as? UITextView, tv.isEditable { return tv }
        for sub in view.subviews {
            if let found = findFirstEditableTextView(in: sub) { return found }
        }
        return nil
    }

    /// Position-based fallback: returns the view whose frame (in rootView
    /// coordinates) has the highest minY, is less than 45 % of rootView's
    /// height, is at least 20 pt tall, interactive, and visible.
    private func findBottomComposerView(in rootView: UIView) -> UIView? {
        let rootH = rootView.bounds.height
        guard rootH > 0 else { return nil }

        var best: UIView?
        var bestMinY: CGFloat = -1

        func visit(_ view: UIView) {
            guard view !== rootView,
            !view.isHidden,
            view.alpha > 0,
            view.isUserInteractionEnabled else { return }

            let frame = rootView.convert(view.bounds, from: view)
            let h = frame.height

            if h > 20 && h < rootH * 0.45 && frame.minY > rootH * 0.55 {
                if frame.minY > bestMinY {
                    bestMinY = frame.minY
                    best = view
                }
            }
            view.subviews.forEach { visit($0) }
        }
        visit(rootView)
        return best
    }

    // MARK: - Show Messaging UI

    /// Show the most recent conversation (default show).
    func show(
    rootViewController: UIViewController?,
    viewMode: String?,
    exitAction exitActionString: String?,
    flutterResult: @escaping FlutterResult
    ) {
        guard let messaging = Zendesk.instance?.messaging else {
            flutterResult(sdkNotInitializedError()); return
        }
        let vc = messaging.messagingViewController(
            .showMostRecentConversation(
                exitAction: wantsReturnToList(exitActionString) ? .returnToConversationList : .close
            )
        )
        present(viewController: vc, on: rootViewController,
            viewMode: viewMode, flutterResult: flutterResult)
    }

    /// Show a specific conversation by ID.
    /// When `isClosed` is `true` the composer input bar is hidden so the user
    /// cannot send new messages into a closed conversation.
    func showConversation(
    conversationId: String,
    rootViewController: UIViewController?,
    viewMode: String?,
    exitAction exitActionString: String?,
    isClosed: Bool = false,
    flutterResult: @escaping FlutterResult
    ) {
        guard let messaging = Zendesk.instance?.messaging else {
            flutterResult(sdkNotInitializedError()); return
        }
        let vc = messaging.messagingViewController(
            .showConversation(
                conversationId: conversationId,
                exitAction: wantsReturnToList(exitActionString) ? .returnToConversationList : .close
            )
        )
        present(viewController: vc, on: rootViewController,
            viewMode: viewMode, readOnly: isClosed, flutterResult: flutterResult)
    }

    /// Show the conversation list (multi-conversations).
    func showConversationList(
    rootViewController: UIViewController?,
    viewMode: String?,
    exitAction exitActionString: String?,
    flutterResult: @escaping FlutterResult
    ) {
        guard let messaging = Zendesk.instance?.messaging else {
            flutterResult(sdkNotInitializedError()); return
        }
        let vc = messaging.messagingViewController(.showConversationList)
        present(viewController: vc, on: rootViewController,
            viewMode: viewMode, flutterResult: flutterResult)
    }

    /// Start a new conversation.
    func startNewConversation(
    rootViewController: UIViewController?,
    viewMode: String?,
    exitAction exitActionString: String?,
    flutterResult: @escaping FlutterResult
    ) {
        guard let messaging = Zendesk.instance?.messaging else {
            flutterResult(sdkNotInitializedError()); return
        }
        let vc = messaging.messagingViewController(
            .showNewConversation(
                exitAction: wantsReturnToList(exitActionString) ? .returnToConversationList : .close
            )
        )
        present(viewController: vc, on: rootViewController,
            viewMode: viewMode, flutterResult: flutterResult)
    }

    // MARK: - Authentication

    func loginUser(jwt: String, flutterResult: @escaping FlutterResult) {
        Zendesk.instance?.loginUser(with: jwt) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let user):
                    self?.flutterPlugin?.isLoggedIn = true
                    let userData: [String: Any?] = [
                        "id": user.id,
                        "externalId": user.externalId,
                        "authenticationType": "jwt",
                    ]
                    self?.cachedUser = userData
                    flutterResult([
                        "id": user.id as Any,
                        "externalId": user.externalId as Any,
                    ])
                case .failure(let error):
                    flutterResult(FlutterError(
                        code: "login_error",
                        message: error.localizedDescription,
                        details: nil))
                }
            }
        }
    }

    func logoutUser(flutterResult: @escaping FlutterResult) {
        Zendesk.instance?.logoutUser { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.flutterPlugin?.isLoggedIn = false
                    self?.cachedUser = nil
                    flutterResult(nil)
                case .failure(let error):
                    flutterResult(FlutterError(
                        code: "logout_error",
                        message: error.localizedDescription,
                        details: nil))
                }
            }
        }
    }

    func getCurrentUser(flutterResult: @escaping FlutterResult) {
        if let user = cachedUser {
            flutterResult(user)
        } else {
            flutterResult(nil)
        }
    }

    // MARK: - Unread Messages

    func getUnreadMessageCount() -> Int {
        return Zendesk.instance?.messaging?.getUnreadMessageCount() ?? 0
    }

    func getUnreadMessageCountForConversation(_ conversationId: String) -> Int {
        // The SDK does not expose per-conversation count via a direct API;
        // return the total count as the closest available approximation.
        return getUnreadMessageCount()
    }

    func listenMessageCountChanged() {
        // On iOS the event observer is registered during initialize().
        // This method exists for API symmetry with Android — it is a no-op here.
    }

    // MARK: - Connection Status

    func getConnectionStatus() -> String {
        return lastConnectionStatus
    }

    // MARK: - Conversation Metadata

    func setConversationTags(tags: [String]) {
        Zendesk.instance?.messaging?.setConversationTags(tags)
    }

    func clearConversationTags() {
        Zendesk.instance?.messaging?.clearConversationTags()
    }

    func setConversationFields(fields: [String: String]) {
        Zendesk.instance?.messaging?.setConversationFields(fields)
    }

    func clearConversationFields() {
        Zendesk.instance?.messaging?.clearConversationFields()
    }

    // MARK: - Lifecycle

    func invalidate() {
        Zendesk.instance?.removeEventObserver(self)
        Zendesk.invalidate()
        isPresenting = false
        cachedUser = nil
        lastConnectionStatus = "unknown"
        flutterPlugin?.isInitialized = false
        flutterPlugin?.isLoggedIn = false
    }

    // MARK: - Push Notifications

    private func setupPushNotifications() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Register an APNs device token from a raw Data object.
    func updatePushNotificationTokenData(_ deviceToken: Data) {
        PushNotifications.updatePushNotificationToken(deviceToken)
    }

    /// Register an APNs device token from a Base64-encoded string.
    func updatePushNotificationTokenString(_ tokenString: String) {
        guard let tokenData = Data(base64Encoded: tokenString) else {
            print("[ZendeskMessaging] Invalid base64 APNs token")
            return
        }
        PushNotifications.updatePushNotificationToken(tokenData)
    }

    func shouldBeDisplayed(_ messageData: [String: Any]) -> String {
        let stringData = messageData.compactMapValues { $0 as? String }
        let result = PushNotifications.shouldBeDisplayed(stringData)
        switch result {
        case .messagingShouldDisplay:    return "messagingShouldDisplay"
        case .messagingShouldNotDisplay: return "messagingShouldNotDisplay"
        default:                         return "notFromMessaging"
        }
    }

    func handleNotification(_ messageData: [String: Any]) -> Bool {
        let stringData = messageData.compactMapValues { $0 as? String }
        let result = PushNotifications.shouldBeDisplayed(stringData)
        return result == .messagingShouldDisplay
    }

    func handleNotificationTap(
    _ messageData: [String: Any],
    rootViewController: UIViewController?,
    completion: ((Bool) -> Void)? = nil
    ) {
        let stringData = messageData.compactMapValues { $0 as? String }
        PushNotifications.handleTap(stringData, completion: nil)
        completion?(true)
    }

    // MARK: - Event Observer

    private func setupEventObserver() {
        Zendesk.instance?.addEventObserver(self) { [weak self] event in
            guard let self else { return }

            let now = Int(Date().timeIntervalSince1970 * 1000)
            var payload: [String: Any] = ["timestamp": now]

            switch event {

            case .unreadMessageCountChanged(let count):
                payload["type"] = "unreadMessageCountChanged"
                payload["totalUnreadCount"] = count

            case .authenticationFailed(let error):
                payload["type"] = "authenticationFailed"
                payload["errorCode"] = "auth_error"
                payload["errorMessage"] = error.localizedDescription
                payload["isJwtExpired"] = false

            case .connectionStatusChanged(let status):
                let statusString = self.connectionStatusString(status)
                self.lastConnectionStatus = statusString
                payload["type"] = "connectionStatusChanged"
                payload["status"] = statusString

            case .sendMessageFailed(let error):
                payload["type"] = "sendMessageFailed"
                payload["errorMessage"] = error.localizedDescription

            case .conversationStarted(_, _, let id):
                payload["type"] = "conversationStarted"
                payload["conversationId"] = id ?? ""

            case .conversationOpened(_, _, let id):
                payload["type"] = "conversationOpened"
                payload["conversationId"] = id ?? ""

            case .messagesShown(_, _, let id, _):
                payload["type"] = "messagesShown"
                payload["conversationId"] = id ?? ""
                payload["messages"] = [] as [[String: Any]]

            default:
                return // Unhandled event — do not emit
            }

            DispatchQueue.main.async {
                self.channel.invokeMethod("onEvent", arguments: payload)
            }
        }
    }

    private func connectionStatusString(_ status: ZendeskConnectionStatus) -> String {
        switch status {
        case .connected:           return "connected"
        case .disconnected:        return "disconnected"
        case .connectingRealtime:  return "connectingRealtime"
        case .connectedRealtime:   return "connectedRealtime"
        default:                   return "unknown"
        }
    }

    // MARK: - Error Helpers

    private func sdkNotInitializedError() -> FlutterError {
        return FlutterError(
            code: "not_initialized",
            message: "Zendesk SDK is not initialized",
            details: nil)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension ZendeskMessaging: UNUserNotificationCenterDelegate {

    public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let result = PushNotifications.shouldBeDisplayed(
            notification.request.content.userInfo as? [String: String] ?? [:]
        )
        if result == .messagingShouldDisplay {
            completionHandler([.banner, .sound, .badge])
        } else {
            completionHandler([])
        }
    }

    public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo as? [String: String] ?? [:]
        if PushNotifications.shouldBeDisplayed(userInfo) == .messagingShouldDisplay {
            PushNotifications.handleTap(userInfo, completion: nil)
        }
        completionHandler()
    }
}
