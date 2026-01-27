import UIKit
import ZendeskSDK
import ZendeskSDKMessaging
import Flutter
import UserNotifications

public final class ZendeskMessaging: NSObject {

    // MARK: - Properties
    private weak var flutterPlugin: SwiftZendeskMessagingPlugin?
    private let channel: FlutterMethodChannel

    /// Prevents ONLY simultaneous presentation
    private var isPresenting = false
    private var currentConversationId: String?

    private enum ZendeskViewMode: String { case fullscreen, sheet, pageSheet, formSheet, automatic }

    // MARK: - Init
    init(flutterPlugin: SwiftZendeskMessagingPlugin, channel: FlutterMethodChannel) {
        self.flutterPlugin = flutterPlugin
        self.channel = channel
        super.init()
    }

    // MARK: - SDK Initialization
    func initialize(channelKey: String,
                    flutterResult: @escaping FlutterResult) {

        Zendesk.initialize(
            withChannelKey: channelKey,
            messagingFactory: DefaultMessagingFactory()
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success:
                    self.flutterPlugin?.setInitialized(true)
                    self.setupEventHandlers()
                    flutterResult(nil as Any?)

                case .failure(let error):
                    flutterResult(
                        FlutterError(
                            code: "initialize_error",
                            message: error.localizedDescription,
                            details: nil
                        )
                    )
                }
            }
        }
    }

    // MARK: - Show / Start Conversation (CORE)
    public func showConversation(
        newConversation: Bool = false,
        rootViewController: UIViewController?,
        navigationController: UINavigationController? = nil,
        viewMode: String?,
        exitAction: String?,
        preFilledFields: [String: String]? = nil,
        tags: [String]? = nil,
        useNavigation: Bool = false,
        flutterResult: @escaping FlutterResult
    ) {
        // Prevent simultaneous presentation ONLY
        if isPresenting {
            flutterResult(
                FlutterError(
                    code: "show_error",
                    message: "Messaging UI is being presented",
                    details: nil
                )
            )
            return
        }

        guard let messaging = Zendesk.instance?.messaging else {
            flutterResult(
                FlutterError(
                    code: "show_error",
                    message: "Zendesk SDK not initialized",
                    details: nil
                )
            )
            return
        }

        isPresenting = true

        // Configure conversation
        if let fields = preFilledFields {
            messaging.setConversationFields(fields)
        }
        if let tags = tags {
            messaging.setConversationTags(tags)
        }

        let vc = newConversation
            ? messaging.messagingViewController(.showNewConversation(exitAction: .close))
            : messaging.messagingViewController(.showMostRecentConversation(exitAction: .close))

        DispatchQueue.main.async {
            if useNavigation,
               let nav = navigationController ?? Self.rootNavigationController() {

                nav.pushViewController(vc, animated: true)

            } else if let root = rootViewController {

                let nav = UINavigationController(rootViewController: vc)
                nav.modalPresentationStyle = self.presentationStyle(for: viewMode)
                root.present(nav, animated: true)

            } else {
                self.isPresenting = false
                flutterResult(
                    FlutterError(
                        code: "presentation_error",
                        message: "No root view controller available",
                        details: nil
                    )
                )
                return
            }

            /// Release lock shortly after presentation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.isPresenting = false
            }

            flutterResult(["status": "conversation_presented"])
        }
    }

    // MARK: - Presentation Helpers
    private func presentationStyle(for mode: String?) -> UIModalPresentationStyle {
        let resolved = ZendeskViewMode(rawValue: mode ?? "automatic") ?? .automatic
        switch resolved {
        case .fullscreen: return .fullScreen
        case .sheet:
            if #available(iOS 15.0, *) { return .pageSheet }
            return .formSheet
        case .pageSheet: return .pageSheet
        case .formSheet: return .formSheet
        case .automatic: return .automatic
        }
    }

    private static func rootNavigationController() -> UINavigationController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .rootViewController as? UINavigationController
    }

    // MARK: - Backward Compatibility (REQUIRED BY PLUGIN)
    public func show(
        rootViewController: UIViewController?,
        navigationController: UINavigationController? = nil,
        viewMode: String?,
        exitAction: String?,
        useNavigation: Bool = false,
        flutterResult: @escaping FlutterResult
    ) {
        showConversation(
            newConversation: false,
            rootViewController: rootViewController,
            navigationController: navigationController,
            viewMode: viewMode,
            exitAction: exitAction,
            useNavigation: useNavigation,
            flutterResult: flutterResult
        )
    }

    public func startNewConversation(
        rootViewController: UIViewController?,
        navigationController: UINavigationController? = nil,
        viewMode: String?,
        exitAction: String?,
        preFilledFields: [String: String]? = nil,
        tags: [String]? = nil,
        flutterResult: @escaping FlutterResult
    ) {
        showConversation(
            newConversation: true,
            rootViewController: rootViewController,
            navigationController: navigationController,
            viewMode: viewMode,
            exitAction: exitAction,
            preFilledFields: preFilledFields,
            tags: tags,
            flutterResult: flutterResult
        )
    }

    // MARK: - Events (SDK-SAFE)
    private func setupEventHandlers() {
        Zendesk.instance?.addEventObserver(self) { [weak self] event in
            guard let self else { return }

            var payload: [String: Any] = [
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]

            switch event {

            case .conversationStarted(_, _, let id):
                self.currentConversationId = id
                payload["type"] = "conversation_started"
                payload["conversationId"] = id

            case .conversationOpened(_, _, let id):
                self.currentConversationId = id
                payload["type"] = "conversation_opened"
                payload["conversationId"] = id ?? ""

            case .messagesShown(_, _, let id, _):
                payload["type"] = "messaging_opened"
                payload["conversationId"] = id

            case .unreadMessageCountChanged(let count):
                payload["type"] = "unread_message_count_changed"
                payload["currentUnreadCount"] = count

            case .authenticationFailed(let error):
                payload["type"] = "authentication_failed"
                payload["error"] = error.localizedDescription

            case .connectionStatusChanged(let status):
                payload["type"] = "connection_status_changed"
                payload["connectionStatus"] = status.stringValue

            case .sendMessageFailed(let error):
                payload["type"] = "send_message_failed"
                payload["error"] = error.localizedDescription

            default:
                return
            }

            self.channel.invokeMethod("onEvent", arguments: payload)
        }
    }

    // MARK: - Login / Logout
    func loginUser(jwt: String,
                   flutterResult: @escaping FlutterResult) {
        Zendesk.instance?.loginUser(with: jwt) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.flutterPlugin?.setLoggedIn(true)
                    flutterResult(["id": "", "externalId": ""])
                case .failure(let error):
                    flutterResult(
                        FlutterError(
                            code: "login_error",
                            message: error.localizedDescription,
                            details: nil
                        )
                    )
                }
            }
        }
    }

    func logoutUser(flutterResult: @escaping FlutterResult) {
        Zendesk.instance?.logoutUser { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.flutterPlugin?.setLoggedIn(false)
                    flutterResult(nil as Any?)
                case .failure(let error):
                    flutterResult(
                        FlutterError(
                            code: "logout_error",
                            message: error.localizedDescription,
                            details: nil
                        )
                    )
                }
            }
        }
    }

    // MARK: - Conversation Helpers
    func setConversationTags(_ tags: [String]) {
        Zendesk.instance?.messaging?.setConversationTags(tags)
    }

    func clearConversationTags() {
        Zendesk.instance?.messaging?.clearConversationTags()
    }

    func setConversationFields(_ fields: [String: String]) {
        Zendesk.instance?.messaging?.setConversationFields(fields)
    }

    func clearConversationFields() {
        Zendesk.instance?.messaging?.clearConversationFields()
    }

    func getUnreadMessageCount() -> Int {
        Zendesk.instance?.messaging?.getUnreadMessageCount() ?? 0
    }

    // MARK: - Push Notifications
    public func setupPushNotifications() {
        UNUserNotificationCenter.current().delegate = self
    }

    public func didRegisterForRemoteNotifications(deviceToken: Data) {
        PushNotifications.updatePushNotificationToken(deviceToken)
    }

    public func didFailToRegisterForRemoteNotifications(error: Error) {
        print("❌ APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - Invalidate
    func invalidate() {
        Zendesk.instance?.removeEventObserver(self)
        Zendesk.invalidate()
        isPresenting = false
        currentConversationId = nil
        flutterPlugin?.setInitialized(false)
        flutterPlugin?.setLoggedIn(false)
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension ZendeskMessaging: UNUserNotificationCenterDelegate {

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
        @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let result = PushNotifications.shouldBeDisplayed(
            notification.request.content.userInfo
        )

        if result == .messagingShouldDisplay {
            if #available(iOS 14.0, *) {
                completionHandler([.banner, .sound, .badge])
            } else {
                completionHandler([.alert, .sound, .badge])
            }
        } else {
            completionHandler([])
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if PushNotifications.shouldBeDisplayed(
            response.notification.request.content.userInfo
        ) == .messagingShouldDisplay {
            PushNotifications.handleTap(
                response.notification.request.content.userInfo,
                completion: nil
            )
        }
        completionHandler()
    }
}
