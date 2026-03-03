import Flutter
import UIKit

public class SwiftZendeskMessagingPlugin: NSObject, FlutterPlugin {
    let TAG = "[SwiftZendeskMessagingPlugin]"
    private var channel: FlutterMethodChannel
    private var zendeskMessaging: ZendeskMessaging?
    var isInitialized = false
    var isLoggedIn = false
    
    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
        self.zendeskMessaging = ZendeskMessaging(flutterPlugin: self, channel: channel)
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "zendesk_messaging",
                                           binaryMessenger: registrar.messenger())
        let instance = SwiftZendeskMessagingPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            self.processMethodCall(call, result: result)
        }
    }
    
    // MARK: - Root View Controller
    
    private var rootViewController: UIViewController? {
        // iOS 15+-safe key window lookup via connectedScenes
        if #available (iOS 13.0, *) {
            return UIApplication.shared.connectedScenes.compactMap {
                $0 as?UIWindowScene
            }.flatMap {
                $0.windows
            }.first {
                $0.isKeyWindow
            }?.rootViewController
        }
        return UIApplication.shared.delegate?.window??.rootViewController
    }
    
    // MARK: - Method Call Dispatch
    
    private func processMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let method = call.method
        let args = call.arguments as? [String: Any]
        
        // Shared presentation helpers
        let viewMode = args?["viewMode"]  as?String
        let exitAction = args?["exitAction"] as?String
        
        switch method {
            
            // ── Initialization ────────────────────────────────────────────────
        case "initialize":
            guard let channelKey = args?["channelKey"] as?String, !channelKey.isEmpty else {
                result(FlutterError(code: "invalid_args",
                                    message: "channelKey is required", details: nil))
                return
            }
            zendeskMessaging?.initialize(channelKey: channelKey, flutterResult: result)
            
            // ── Messaging UI ──────────────────────────────────────────────────
        case "show":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            zendeskMessaging?.show(
                rootViewController: rootViewController,
                viewMode: viewMode,
                exitAction: exitAction,
                flutterResult: result
            )
            
        case "showConversation":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            guard let conversationId = args?["conversationId"] as?String,
                  !conversationId.isEmpty else {
                result(FlutterError(code: "invalid_args",
                                    message: "conversationId is required", details: nil))
                return
            }
            let isClosed = args?["isClosed"] as?Bool ?? false
            zendeskMessaging?.showConversation(
                conversationId: conversationId,
                rootViewController: rootViewController,
                viewMode: viewMode,
                exitAction: exitAction,
                isClosed: isClosed,
                flutterResult: result
            )
            
        case "showConversationList":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            zendeskMessaging?.showConversationList(
                rootViewController: rootViewController,
                viewMode: viewMode,
                exitAction: exitAction,
                flutterResult: result
            )
            
        case "startNewConversation":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            zendeskMessaging?.startNewConversation(
                rootViewController: rootViewController,
                viewMode: viewMode,
                exitAction: exitAction,
                flutterResult: result
            )
            
            // ── Authentication ────────────────────────────────────────────────
        case "loginUser":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            guard let jwt = args?["jwt"] as?String, !jwt.isEmpty else {
                result(FlutterError(code: "invalid_args",
                                    message: "jwt is required", details: nil))
                return
            }
            zendeskMessaging?.loginUser(jwt: jwt, flutterResult: result)
            
        case "logoutUser":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            zendeskMessaging?.logoutUser(flutterResult: result)
            
        case "getCurrentUser":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            zendeskMessaging?.getCurrentUser(flutterResult: result)
            
            // ── Unread Messages ───────────────────────────────────────────────
        case "getUnreadMessageCount":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            result(zendeskMessaging?.getUnreadMessageCount() ?? 0)
            
        case "getUnreadMessageCountForConversation":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            guard let conversationId = args?["conversationId"] as?String,
                  !conversationId.isEmpty else {
                result(FlutterError(code: "invalid_args",
                                    message: "conversationId is required", details: nil))
                return
            }
            result(zendeskMessaging?.getUnreadMessageCountForConversation(conversationId) ?? 0)
            
        case "listenUnreadMessages":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            zendeskMessaging?.listenMessageCountChanged()
            result(nil)
            
            // ── Connection ────────────────────────────────────────────────────
        case "getConnectionStatus":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            result(zendeskMessaging?.getConnectionStatus() ?? "unknown")
            
            // ── Status ────────────────────────────────────────────────────────
        case "isInitialized":
            result(isInitialized)
            
        case "isLoggedIn":
            result(isLoggedIn)
            
            // ── Conversation Metadata ─────────────────────────────────────────
        case "setConversationTags":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            let tags = args?["tags"] as? [String] ?? []
            zendeskMessaging?.setConversationTags(tags: tags)
            result(nil)
            
        case "clearConversationTags":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            zendeskMessaging?.clearConversationTags()
            result(nil)
            
        case "setConversationFields":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            let fields = args?["fields"] as? [String: String] ?? [:]
            zendeskMessaging?.setConversationFields(fields: fields)
            result(nil)
            
        case "clearConversationFields":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            zendeskMessaging?.clearConversationFields()
            result(nil)
            
            // ── Lifecycle ─────────────────────────────────────────────────────
        case "invalidate":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            zendeskMessaging?.invalidate()
            result(nil)
            
            // ── Push Notifications ────────────────────────────────────────────
        case "updatePushNotificationToken":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            guard let token = args?["token"] as?String, !token.isEmpty else {
                result(FlutterError(code: "invalid_args",
                                    message: "token is required", details: nil))
                return
            }
            zendeskMessaging?.updatePushNotificationTokenString(token)
            result(nil)
            
        case "shouldBeDisplayed":
            guard let messageData = args?["messageData"] as? [String: Any] else {
                result(FlutterError(code: "invalid_args",
                                    message: "messageData is required", details: nil))
                return
            }
            let responsibility = zendeskMessaging?.shouldBeDisplayed(messageData) ?? "unknown"
            result(responsibility)
            
        case "handleNotification":
            guard let messageData = args?["messageData"] as? [String: Any] else {
                result(FlutterError(code: "invalid_args",
                                    message: "messageData is required", details: nil))
                return
            }
            let handled = zendeskMessaging?.handleNotification(messageData) ?? false
            result(handled)
            
        case "handleNotificationTap":
            guard isInitialized else {
                reportNotInitializedError(result); return
            }
            guard let messageData = args?["messageData"] as? [String: Any] else {
                result(FlutterError(code: "invalid_args",
                                    message: "messageData is required", details: nil))
                return
            }
            zendeskMessaging?.handleNotificationTap(messageData,
                                                    rootViewController: rootViewController) {
                _ in
                result(nil)
            }
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Helpers
    
    private func reportNotInitializedError(_ result: FlutterResult) {
        print("\(TAG) - Zendesk SDK needs to be initialized first")
        result(FlutterError(
            code: "not_initialized",
            message: "Zendesk SDK needs to be initialized first",
            details: nil))
    }
}
