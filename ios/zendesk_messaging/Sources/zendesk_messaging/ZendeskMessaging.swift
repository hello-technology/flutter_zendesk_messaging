import Flutter
import UIKit
import ZendeskSDKMessaging
import ZendeskSDK
import UserNotifications

public class ZendeskMessaging: NSObject {
    private static let unreadMessages = "unread_messages"
    private static let zendeskEvent = "zendesk_event"

    let TAG = "[ZendeskMessaging]"

    private weak var zendeskPlugin: ZendeskMessagingPlugin?
    private let channel: FlutterMethodChannel
    private var lastConnectionStatus: String = "unknown"
    private weak var messagingNavController: UINavigationController?

    private static let composerHideRetryInterval: TimeInterval = 0.15

    init(flutterPlugin: ZendeskMessagingPlugin, channel: FlutterMethodChannel) {
        self.zendeskPlugin = flutterPlugin
        self.channel = channel
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dismissMessagingOnBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    func initialize(channelKey: String, flutterResult: @escaping FlutterResult) {
        print("\(self.TAG) - Channel Key - \(channelKey)\n")
        Zendesk.initialize(withChannelKey: channelKey, messagingFactory: DefaultMessagingFactory()) { result in
            DispatchQueue.main.async {
                if case let .failure(error) = result {
                    self.zendeskPlugin?.isInitialized = false
                    print("\(self.TAG) - initialize failure - \(error.localizedDescription)\n")
                    flutterResult(FlutterError(
                        code: "initialize_error",
                        message: error.localizedDescription,
                        details: nil)
                    )
                } else {
                    self.zendeskPlugin?.isInitialized = true
                    print("\(self.TAG) - initialize success")
                    flutterResult(nil)
                }
            }
        }
    }

    func invalidate() {
        Zendesk.instance?.removeEventObserver(self)
        // Clear stored user data and conversations so the next user starts
        // fresh. The no-argument overload keeps storage on iOS, while Android's
        // invalidate() always clears it; passing true matches Android.
        Zendesk.invalidate(true)
        self.zendeskPlugin?.isInitialized = false
        self.zendeskPlugin?.isLoggedIn = false
        print("\(self.TAG) - invalidate")
    }

    // ============================================================================
    // Messaging UI
    // ============================================================================

    func show(rootViewController: UIViewController?, viewMode: String?, exitAction: String?, flutterResult: @escaping FlutterResult) {
        let viewController = Zendesk.instance?.messaging?.messagingViewController(
            .showMostRecentConversation(exitAction: resolveExitAction(exitAction))
        )
        present(viewController, on: rootViewController, viewMode: viewMode, flutterResult: flutterResult)
        print("\(self.TAG) - show")
    }

    func showConversation(conversationId: String, rootViewController: UIViewController?, viewMode: String?, exitAction: String?, isClosed: Bool, flutterResult: @escaping FlutterResult) {
        let viewController = Zendesk.instance?.messaging?.messagingViewController(
            .showConversation(conversationId: conversationId, exitAction: resolveExitAction(exitAction))
        )
        present(viewController, on: rootViewController, viewMode: viewMode, readOnly: isClosed, flutterResult: flutterResult)
        print("\(self.TAG) - showConversation: \(conversationId) (isClosed: \(isClosed))")
    }

    func showConversationList(rootViewController: UIViewController?, viewMode: String?, flutterResult: @escaping FlutterResult) {
        let viewController = Zendesk.instance?.messaging?.messagingViewController(.showConversationList)
        present(viewController, on: rootViewController, viewMode: viewMode, flutterResult: flutterResult)
        print("\(self.TAG) - showConversationList")
    }

    func startNewConversation(rootViewController: UIViewController?, viewMode: String?, exitAction: String?, flutterResult: @escaping FlutterResult) {
        let viewController = Zendesk.instance?.messaging?.messagingViewController(
            .showNewConversation(exitAction: resolveExitAction(exitAction))
        )
        present(viewController, on: rootViewController, viewMode: viewMode, flutterResult: flutterResult)
        print("\(self.TAG) - startNewConversation")
    }

    private func resolveExitAction(_ exitAction: String?) -> ZendeskSDK.ExitAction {
        exitAction == "return_to_conversation_list" ? .returnToConversationList : .close
    }

    private func presentationStyle(for viewMode: String?) -> UIModalPresentationStyle {
        switch viewMode {
        case "fullscreen": return .fullScreen
        case "sheet", "pageSheet": return .pageSheet
        case "formSheet": return .formSheet
        default: return .automatic
        }
    }

    private func present(_ viewController: UIViewController?, on rootViewController: UIViewController?, viewMode: String?, readOnly: Bool = false, flutterResult: @escaping FlutterResult) {
        guard let viewController = viewController else {
            print("\(self.TAG) - Unable to create Zendesk messaging view controller")
            flutterResult(FlutterError(
                code: "show_error",
                message: "Unable to create Zendesk messaging view controller",
                details: nil)
            )
            return
        }
        guard let rootViewController = rootViewController else {
            print("\(self.TAG) - Root view controller is nil")
            flutterResult(FlutterError(
                code: "show_error",
                message: "Root view controller is nil",
                details: nil)
            )
            return
        }

        let navController = UINavigationController(rootViewController: viewController)
        navController.modalPresentationStyle = presentationStyle(for: viewMode)
        messagingNavController = navController

        let presentMessaging = {
            rootViewController.present(navController, animated: true) { [weak self, weak navController] in
                if readOnly, let navController = navController {
                    self?.forceHideComposerContinuously(in: navController)
                }
            }
        }

        DispatchQueue.main.async {
            if let presentedVC = rootViewController.presentedViewController {
                presentedVC.dismiss(animated: true, completion: presentMessaging)
            } else {
                presentMessaging()
            }
            flutterResult(nil)
        }
    }

    // Hides the composer so a closed conversation stays read-only.
    private func forceHideComposerContinuously(in vc: UIViewController) {
        // Immediate attempt
        retryReadOnly(in: vc, attemptsLeft: 50)

        // Re-apply every second while the screen is alive; the SDK can re-layout it
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

    // Zendesk only pushes while it sees the user offline. With the chat still on
    // screen the SDK keeps its realtime connection, which iOS drops silently on
    // suspend/kill, so replies are never pushed. Closing the chat disconnects it.
    @objc private func dismissMessagingOnBackground() {
        guard let navController = messagingNavController, navController.presentingViewController != nil else {
            return
        }
        navController.dismiss(animated: false)
        messagingNavController = nil
        print("\(self.TAG) - messaging dismissed on background")
    }

    func setConversationTags(tags: [String]) {
        Zendesk.instance?.messaging?.setConversationTags(tags)
        print("\(self.TAG) - setConversationTags: \(tags)")
    }

    func clearConversationTags() {
        Zendesk.instance?.messaging?.clearConversationTags()
        print("\(self.TAG) - clearConversationTags")
    }

    func loginUser(jwt: String, flutterResult: @escaping FlutterResult) {
        Zendesk.instance?.loginUser(with: jwt) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let user):
                    self.zendeskPlugin?.isLoggedIn = true
                    flutterResult([
                        "id": user.id,
                        "externalId": user.externalId,
                        "authenticationType": self.getAuthenticationType(user: user)
                    ])
                    print("\(self.TAG) - loginUser success")
                case .failure(let error):
                    print("\(self.TAG) - login failure - \(error.localizedDescription)\n")
                    flutterResult(FlutterError(
                        code: "login_error",
                        message: error.localizedDescription,
                        details: nil)
                    )
                }
            }
        }
    }

    func logoutUser(flutterResult: @escaping FlutterResult) {
        Zendesk.instance?.logoutUser { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.zendeskPlugin?.isLoggedIn = false
                    flutterResult(nil)
                    print("\(self.TAG) - logoutUser success")
                case .failure(let error):
                    print("\(self.TAG) - logout failure - \(error.localizedDescription)\n")
                    flutterResult(FlutterError(
                        code: "logout_error",
                        message: error.localizedDescription,
                        details: nil)
                    )
                }
            }
        }
    }

    func getCurrentUser(flutterResult: @escaping FlutterResult) {
        if let user = Zendesk.instance?.getCurrentUser() {
            flutterResult([
                "id": user.id,
                "externalId": user.externalId,
                "authenticationType": getAuthenticationType(user: user)
            ])
        } else {
            flutterResult(nil)
        }
    }

    private func getAuthenticationType(user: ZendeskSDK.ZendeskUser) -> String {
        switch user.authenticationType {
        case .jwt:
            return "jwt"
        default:
            return "anonymous"
        }
    }

    func getUnreadMessageCount() -> Int {
        let count = Zendesk.instance?.messaging?.getUnreadMessageCount()
        return count ?? 0
    }

    func getUnreadMessageCountForConversation(conversationId: String) -> Int {
        let count = Zendesk.instance?.messaging?.getUnreadMessageCount(conversationId: conversationId)
        return count ?? 0
    }

    func getConnectionStatus() -> String {
        return lastConnectionStatus
    }

    func listenMessageCountChanged() {
        Zendesk.instance?.addEventObserver(self, { event in
            self.handleZendeskEvent(event: event)
        })
        print("\(self.TAG) - listenMessageCountChanged - Event observer added")
    }

    private func handleZendeskEvent(event: ZendeskSDK.ZendeskEvent) {
        switch event {
        case let .unreadMessageCountChanged(currentUnreadCount):
            // Legacy callback for backwards compatibility
            self.channel.invokeMethod(
                Self.unreadMessages,
                arguments: ["messages_count": currentUnreadCount]
            )
            // New event system
            self.channel.invokeMethod(
                Self.zendeskEvent,
                arguments: [
                    "type": "unreadMessageCountChanged",
                    "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                    "totalUnreadCount": currentUnreadCount
                ]
            )

        case let .authenticationFailed(error as NSError):
            let isJwtExpired = error.localizedDescription.lowercased().contains("expired")
            self.channel.invokeMethod(
                Self.zendeskEvent,
                arguments: [
                    "type": "authenticationFailed",
                    "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                    "errorCode": "authentication_failed",
                    "errorMessage": error.localizedDescription,
                    "isJwtExpired": isJwtExpired
                ]
            )

        case let .conversationAdded(conversationId):
            self.channel.invokeMethod(
                Self.zendeskEvent,
                arguments: [
                    "type": "conversationAdded",
                    "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                    "conversationId": conversationId
                ]
            )

        case let .connectionStatusChanged(connectionStatus):
            let statusString = connectionStatus.stringValue
            self.lastConnectionStatus = statusString
            self.channel.invokeMethod(
                Self.zendeskEvent,
                arguments: [
                    "type": "connectionStatusChanged",
                    "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                    "status": statusString
                ]
            )

        case let .sendMessageFailed(error as NSError):
            self.channel.invokeMethod(
                Self.zendeskEvent,
                arguments: [
                    "type": "sendMessageFailed",
                    "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                    "errorMessage": error.localizedDescription
                ]
            )

        case let .conversationOpened(id, timestamp, conversationId):
            self.channel.invokeMethod(
                Self.zendeskEvent,
                arguments: [
                    "type": "conversationOpened",
                    "id": id.uuidString,
                    "timestamp": Int64(timestamp.timeIntervalSince1970 * 1000),
                    "conversationId": conversationId ?? ""
                ]
            )

        case let .conversationStarted(id, timestamp, conversationId):
            self.channel.invokeMethod(
                Self.zendeskEvent,
                arguments: [
                    "type": "conversationStarted",
                    "id": id.uuidString,
                    "timestamp": Int64(timestamp.timeIntervalSince1970 * 1000),
                    "conversationId": conversationId
                ]
            )

        case let .messagesShown(id, timestamp, conversationId, messages):
            let messagesData = messages.map { message -> [String: Any] in
                return [
                    "id": message.id,
                    "conversationId": conversationId
                ]
            }
            self.channel.invokeMethod(
                Self.zendeskEvent,
                arguments: [
                    "type": "messagesShown",
                    "id": id.uuidString,
                    "timestamp": Int64(timestamp.timeIntervalSince1970 * 1000),
                    "conversationId": conversationId,
                    "messages": messagesData
                ]
            )

        case let .сonversationUnreadCountChanged(id, timestamp, data):
            self.channel.invokeMethod(
                Self.zendeskEvent,
                arguments: [
                    "type": "unreadMessageCountChanged",
                    "id": id.uuidString,
                    "timestamp": Int64(timestamp.timeIntervalSince1970 * 1000),
                    "conversationId": data.conversationId ?? "",
                    "conversationUnreadCount": data.unreadCountInConversation,
                    "totalUnreadCount": data.totalUnreadMessagesCount
                ]
            )

        @unknown default:
            print("\(self.TAG) - Unknown event type")
        }
    }

    func setConversationFields(fields: [String: String]) {
        Zendesk.instance?.messaging?.setConversationFields(fields)
        print("\(self.TAG) - setConversationFields: \(fields)")
    }

    func clearConversationFields() {
        Zendesk.instance?.messaging?.clearConversationFields()
        print("\(self.TAG) - clearConversationFields")
    }

    // ============================================================================
    // Locale
    // ============================================================================

    func setLocale(locale: String) {
        UserDefaults.standard.set([locale], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
        print("\(self.TAG) - setLocale: \(locale)")
    }

    // ============================================================================
    // Push Notifications
    // ============================================================================

    /// Update the push notification token with Zendesk.
    /// Call this when receiving a new APNs device token.
    func updatePushNotificationToken(_ deviceToken: Data) {
        PushNotifications.updatePushNotificationToken(deviceToken)
        print("\(self.TAG) - updatePushNotificationToken: token updated")
    }

    /// Update the push notification token from a hex string (APNs format).
    /// The Flutter side should pass the APNs device token as a hex string,
    /// not the FCM token. Use `FirebaseMessaging.instance.getAPNSToken()`.
    func updatePushNotificationTokenString(_ token: String) {
        let hex = token.hasPrefix("0x") ? String(token.dropFirst(2)) : token
        guard hex.count.isMultiple(of: 2) else {
            print("\(self.TAG) - updatePushNotificationTokenString: token length must be even hex")
            return
        }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else {
                print("\(self.TAG) - updatePushNotificationTokenString: invalid hex char")
                return
            }
            data.append(byte)
            idx = next
        }
        PushNotifications.updatePushNotificationToken(data)
        print("\(self.TAG) - updatePushNotificationTokenString: token updated (\(data.count) bytes)")
    }

    /// Check if a push notification should be displayed by Zendesk.
    /// Returns the responsibility indicating how to handle the notification.
    func shouldBeDisplayed(_ userInfo: [AnyHashable: Any]) -> String {
        let responsibility = PushNotifications.shouldBeDisplayed(userInfo)
        let result: String
        switch responsibility {
        case .messagingShouldDisplay:
            result = "messaging_should_display"
        case .messagingShouldNotDisplay:
            result = "messaging_should_not_display"
        case .notFromMessaging:
            result = "not_from_messaging"
        @unknown default:
            result = "unknown"
        }
        print("\(self.TAG) - shouldBeDisplayed: \(result)")
        return result
    }

    /// Handle and display a push notification.
    /// Returns true if the notification was handled by Zendesk.
    func handleNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let responsibility = PushNotifications.shouldBeDisplayed(userInfo)
        if responsibility == .messagingShouldDisplay {
            print("\(self.TAG) - handleNotification: Zendesk notification detected")
            return true
        } else {
            print("\(self.TAG) - handleNotification: not a Zendesk notification")
            return false
        }
    }

    /// Handle a notification tap event.
    /// Returns the view controller to display, or nil if not a Zendesk notification.
    func handleNotificationTap(_ userInfo: [AnyHashable: Any], rootViewController: UIViewController?, completion: @escaping (Bool) -> Void) {
        let responsibility = PushNotifications.shouldBeDisplayed(userInfo)
        if responsibility == .messagingShouldDisplay {
            PushNotifications.handleTap(userInfo) { [weak self] viewController in
                guard let self = self else {
                    completion(false)
                    return
                }
                if let vc = viewController, let rootVC = rootViewController {
                    let navController = UINavigationController(rootViewController: vc)
                    DispatchQueue.main.async {
                        if let presentedVC = rootVC.presentedViewController {
                            presentedVC.dismiss(animated: true) {
                                rootVC.present(navController, animated: true, completion: nil)
                            }
                        } else {
                            rootVC.present(navController, animated: true, completion: nil)
                        }
                        completion(true)
                    }
                    print("\(self.TAG) - handleNotificationTap: opened messaging")
                } else {
                    print("\(self.TAG) - handleNotificationTap: viewController is nil (app may have been killed)")
                    completion(false)
                }
            }
        } else {
            print("\(self.TAG) - handleNotificationTap: not a Zendesk notification")
            completion(false)
        }
    }
}
