import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'enums/connection_status.dart';
import 'enums/exit_action.dart';
import 'enums/push_responsibility.dart';
import 'enums/view_mode.dart';
import 'events/event_parser.dart';
import 'events/zendesk_event.dart';
import 'models/zendesk_login_response.dart';
import 'models/zendesk_user.dart';
import 'zendesk_messaging_config.dart';

/// Zendesk Messaging SDK Flutter Plugin.
///
/// Provides access to Zendesk Messaging functionality including:
/// - User authentication (login/logout)
/// - Messaging UI display (with view mode and exit action on iOS)
/// - Multi-conversation navigation
/// - Unread message count tracking
/// - Event streams for various SDK events
/// - Conversation tags and fields
///
/// ## Quick Start
///
/// ```dart
/// // Initialize
/// await ZendeskMessaging.initialize(
///   androidChannelKey: 'your_android_key',
///   iosChannelKey: 'your_ios_key',
/// );
///
/// // Show messaging UI (full-screen, default)
/// await ZendeskMessaging.show();
///
/// // Show as a page sheet on iOS, return to list on exit
/// await ZendeskMessaging.show(
///   viewMode: ZendeskViewMode.pageSheet,
///   exitAction: ZendeskExitAction.returnToConversationList,
/// );
///
/// // Listen to events
/// ZendeskMessaging.eventStream.listen((event) {
///   switch (event) {
///     case UnreadMessageCountChanged(:final totalUnreadCount):
///       print('Unread: $totalUnreadCount');
///     case AuthenticationFailed(:final isJwtExpired):
///       if (isJwtExpired) refreshToken();
///     case MessagingClosed():
///       onChatClosed();
///     default:
///       break;
///   }
/// });
///
/// await ZendeskMessaging.listenUnreadMessages();
/// ```
///
/// ## Error Handling
///
/// All methods that can fail will throw exceptions. Wrap calls in try-catch:
///
/// ```dart
/// try {
///   await ZendeskMessaging.loginUser(jwt: token);
/// } catch (e) {
///   // Handle error
/// }
/// ```
///
/// ## Logging
///
/// Configure logging via [ZendeskMessagingConfig]:
///
/// ```dart
/// ZendeskMessagingConfig.enableLogging = true;
/// ```
class ZendeskMessaging {
  ZendeskMessaging._();

  static const MethodChannel _channel = MethodChannel('zendesk_messaging');

  // Stream controllers
  static final StreamController<int> _unreadMessagesCountController = StreamController<int>.broadcast();
  static final StreamController<ZendeskEvent> _eventController = StreamController<ZendeskEvent>.broadcast();

  /// Legacy stream of unread message count changes.
  ///
  /// Maintained for backwards compatibility.
  /// For new code, prefer using [eventStream] and listening for
  /// [UnreadMessageCountChanged] events.
  static Stream<int> get unreadMessagesCountStream => _unreadMessagesCountController.stream;

  /// Broadcast stream of all Zendesk SDK events.
  ///
  /// Listen to this stream to receive all events from the Zendesk SDK.
  /// Use pattern matching to handle specific event types:
  ///
  /// ```dart
  /// ZendeskMessaging.eventStream.listen((event) {
  ///   switch (event) {
  ///     case UnreadMessageCountChanged(:final totalUnreadCount):
  ///       badge.value = totalUnreadCount;
  ///     case AuthenticationFailed(:final errorMessage, :final isJwtExpired):
  ///       if (isJwtExpired) refreshAndRelogin();
  ///     case MessagingClosed():
  ///       onChatClosed();
  ///     case ConnectionStatusChanged(:final status):
  ///       print('Connection: $status');
  ///     default:
  ///       break;
  ///   }
  /// });
  /// ```
  static Stream<ZendeskEvent> get eventStream => _eventController.stream;

  // ============================================================================
  // Initialization
  // ============================================================================

  /// Initialize the Zendesk SDK.
  ///
  /// Must be called before any other [ZendeskMessaging] methods.
  ///
  /// [androidChannelKey] The Android SDK key from Zendesk Admin Center.
  /// [iosChannelKey] The iOS SDK key from Zendesk Admin Center.
  ///
  /// Throws [ArgumentError] if channel keys are empty.
  /// Throws [PlatformException] if initialization fails.
  ///
  /// Example:
  /// ```dart
  /// await ZendeskMessaging.initialize(
  ///   androidChannelKey: 'your_android_key',
  ///   iosChannelKey: 'your_ios_key',
  /// );
  /// ```
  static Future<void> initialize({
    required String androidChannelKey,
    required String iosChannelKey,
  }) async {
    if (androidChannelKey.isEmpty || iosChannelKey.isEmpty) {
      throw ArgumentError('Channel keys cannot be empty');
    }

    try {
      _channel.setMethodCallHandler(_onMethodCall);
      await _channel.invokeMethod<void>('initialize', {
        'channelKey': Platform.isAndroid ? androidChannelKey : iosChannelKey,
      });
      ZendeskMessagingConfig.log('SDK initialized successfully');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('initialize failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Check if the Zendesk SDK is initialized.
  ///
  /// Returns `true` if initialized, `false` otherwise.
  static Future<bool> isInitialized() async {
    try {
      return await _channel.invokeMethod<bool>('isInitialized') ?? false;
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('isInitialized failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Invalidate the current Zendesk SDK instance.
  ///
  /// After calling this, [initialize] must be called again before
  /// using any other methods. This method is safe to call even when
  /// the SDK is not initialized.
  static Future<void> invalidate() async {
    try {
      await _channel.invokeMethod<void>('invalidate');
      ZendeskMessagingConfig.log('SDK invalidated');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('invalidate failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ============================================================================
  // UI Navigation
  // ============================================================================

  /// Show the messaging UI for the most recently active conversation.
  ///
  /// [viewMode] Controls the iOS modal presentation style.
  /// Ignored on Android (always full-screen Activity).
  ///
  /// [exitAction] Controls what happens when the user taps the back/close
  /// button. Use [ZendeskExitAction.returnToConversationList] when
  /// multi-conversations is enabled so users can return to the list.
  ///
  /// Throws [PlatformException] if the UI cannot be shown.
  static Future<void> show({
    ZendeskViewMode viewMode = ZendeskViewMode.fullscreen,
    ZendeskExitAction exitAction = ZendeskExitAction.close,
  }) async {
    try {
      await _channel.invokeMethod<void>('show', {
        'viewMode': viewMode.nativeValue,
        'exitAction': exitAction.nativeValue,
      });
      ZendeskMessagingConfig.log('Messaging UI shown');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('show failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Show a specific conversation by ID.
  ///
  /// Requires multi-conversations to be enabled in Zendesk Admin Center.
  ///
  /// [conversationId] The ID of the conversation to display.
  ///
  /// [viewMode] Controls the iOS modal presentation style (ignored on Android).
  ///
  /// [exitAction] Controls the back/close button behaviour. Defaults to
  /// [ZendeskExitAction.returnToConversationList] so users can navigate back
  /// to the conversation list.
  ///
  /// [isClosed] When `true`, the message composer (input field) is hidden,
  /// preventing new messages in a resolved/closed conversation.
  ///
  /// Throws [ArgumentError] if [conversationId] is empty.
  /// Throws [PlatformException] if the conversation cannot be shown.
  static Future<void> showConversation(
    String conversationId, {
    ZendeskViewMode viewMode = ZendeskViewMode.fullscreen,
    ZendeskExitAction exitAction = ZendeskExitAction.returnToConversationList,
    bool isClosed = false,
  }) async {
    if (conversationId.isEmpty) {
      throw ArgumentError('conversationId cannot be empty');
    }

    try {
      await _channel.invokeMethod<void>('showConversation', {
        'conversationId': conversationId,
        'viewMode': viewMode.nativeValue,
        'exitAction': exitAction.nativeValue,
        'isClosed': isClosed,
      });
      ZendeskMessagingConfig.log('Showing conversation: $conversationId (isClosed: $isClosed)');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('showConversation failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Show the conversation list screen.
  ///
  /// Displays the list of all conversations for the current user.
  /// Requires multi-conversations to be enabled in Zendesk Admin Center.
  ///
  /// [viewMode] Controls the iOS modal presentation style (ignored on Android).
  ///
  /// [exitAction] Controls the back/close button behaviour.
  ///
  /// Throws [PlatformException] if the list cannot be shown.
  static Future<void> showConversationList({
    ZendeskViewMode viewMode = ZendeskViewMode.fullscreen,
    ZendeskExitAction exitAction = ZendeskExitAction.close,
  }) async {
    try {
      await _channel.invokeMethod<void>('showConversationList', {
        'viewMode': viewMode.nativeValue,
        'exitAction': exitAction.nativeValue,
      });
      ZendeskMessagingConfig.log('Conversation list shown');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('showConversationList failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Start a new conversation.
  ///
  /// Opens the messaging UI to begin a new conversation.
  /// Requires multi-conversations to be enabled in Zendesk Admin Center.
  ///
  /// [viewMode] Controls the iOS modal presentation style (ignored on Android).
  ///
  /// [exitAction] Controls the back/close button behaviour.
  ///
  /// Throws [PlatformException] if a new conversation cannot be started.
  static Future<void> startNewConversation({
    ZendeskViewMode viewMode = ZendeskViewMode.fullscreen,
    ZendeskExitAction exitAction = ZendeskExitAction.close,
  }) async {
    try {
      await _channel.invokeMethod<void>('startNewConversation', {
        'viewMode': viewMode.nativeValue,
        'exitAction': exitAction.nativeValue,
      });
      ZendeskMessagingConfig.log('New conversation started');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('startNewConversation failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ============================================================================
  // Authentication
  // ============================================================================

  /// Login a user with JWT authentication.
  ///
  /// Returns a [ZendeskLoginResponse] with the user's `id` and `externalId`.
  ///
  /// Throws [ArgumentError] if [jwt] is empty.
  /// Throws [PlatformException] if login fails.
  ///
  /// Example:
  /// ```dart
  /// final response = await ZendeskMessaging.loginUser(jwt: token);
  /// print('Logged in as: ${response.id}');
  /// ```
  static Future<ZendeskLoginResponse> loginUser({required String jwt}) async {
    if (jwt.isEmpty) throw ArgumentError('JWT cannot be empty');

    try {
      final result = await _channel.invokeMethod('loginUser', {'jwt': jwt});
      final map = result == null ? <String, dynamic>{} : Map<String, dynamic>.from(result as Map);
      ZendeskMessagingConfig.log('User logged in');
      return ZendeskLoginResponse.fromMap(map);
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('loginUser failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Logout the current user.
  ///
  /// Clears user authentication and session data.
  ///
  /// Throws [PlatformException] if logout fails.
  static Future<void> logoutUser() async {
    try {
      await _channel.invokeMethod<void>('logoutUser');
      ZendeskMessagingConfig.log('User logged out');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('logoutUser failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Check if a user is currently logged in.
  ///
  /// Returns `true` if logged in, `false` otherwise.
  static Future<bool> isLoggedIn() async {
    try {
      return await _channel.invokeMethod<bool>('isLoggedIn') ?? false;
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('isLoggedIn failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Get the current user information.
  ///
  /// Returns a [ZendeskUser] if a user is logged in, or `null` for anonymous.
  static Future<ZendeskUser?> getCurrentUser() async {
    try {
      final result = await _channel.invokeMethod('getCurrentUser');
      if (result == null) return null;
      return ZendeskUser.fromMap(Map<String, dynamic>.from(result as Map));
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('getCurrentUser failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ============================================================================
  // Messages
  // ============================================================================

  /// Get the total unread message count across all conversations.
  static Future<int> getUnreadMessageCount() async {
    try {
      return await _channel.invokeMethod<int>('getUnreadMessageCount') ?? 0;
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('getUnreadMessageCount failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Get the unread message count for a specific conversation.
  ///
  /// Throws [ArgumentError] if [conversationId] is empty.
  static Future<int> getUnreadMessageCountForConversation(
    String conversationId,
  ) async {
    if (conversationId.isEmpty) {
      throw ArgumentError('conversationId cannot be empty');
    }

    try {
      return await _channel.invokeMethod<int>(
            'getUnreadMessageCountForConversation',
            {'conversationId': conversationId},
          ) ??
          0;
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('getUnreadMessageCountForConversation failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Start listening for unread message count changes and SDK events.
  ///
  /// After calling this, events will be emitted on both [eventStream] and
  /// the legacy [unreadMessagesCountStream].
  ///
  /// Call this after [initialize].
  static Future<void> listenUnreadMessages() async {
    try {
      await _channel.invokeMethod<void>('listenUnreadMessages');
      ZendeskMessagingConfig.log('Event listener started');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('listenUnreadMessages failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ============================================================================
  // Conversation Data
  // ============================================================================

  /// Set tags on the active conversation.
  ///
  /// [tags] List of tags to apply to conversations.
  ///
  /// Throws [ArgumentError] if [tags] list is empty.
  static Future<void> setConversationTags(List<String> tags) async {
    if (tags.isEmpty) throw ArgumentError('tags cannot be empty');

    try {
      await _channel.invokeMethod<void>('setConversationTags', {'tags': tags});
      ZendeskMessagingConfig.log('Conversation tags set: $tags');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('setConversationTags failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Clear all tags from the active conversation.
  static Future<void> clearConversationTags() async {
    try {
      await _channel.invokeMethod<void>('clearConversationTags');
      ZendeskMessagingConfig.log('Conversation tags cleared');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('clearConversationTags failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Set custom fields on the active conversation.
  ///
  /// Fields must match custom ticket fields configured in Zendesk Admin Center.
  ///
  /// Throws [ArgumentError] if [fields] is empty.
  static Future<void> setConversationFields(Map<String, String> fields) async {
    if (fields.isEmpty) throw ArgumentError('fields cannot be empty');

    try {
      await _channel.invokeMethod<void>('setConversationFields', {'fields': fields});
      ZendeskMessagingConfig.log('Conversation fields set');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('setConversationFields failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Clear all custom fields from the active conversation.
  static Future<void> clearConversationFields() async {
    try {
      await _channel.invokeMethod<void>('clearConversationFields');
      ZendeskMessagingConfig.log('Conversation fields cleared');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('clearConversationFields failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ============================================================================
  // Connection
  // ============================================================================

  /// Get the current SDK connection status.
  ///
  /// Returns [ZendeskConnectionStatus.unknown] until the SDK has established
  /// a connection (by opening messaging UI, logging in, or having an active
  /// conversation). For real-time updates, listen to [eventStream] for
  /// [ConnectionStatusChanged] events instead of polling this method.
  ///
  /// Example:
  /// ```dart
  /// final status = await ZendeskMessaging.getConnectionStatus();
  /// if (status == ZendeskConnectionStatus.unknown) {
  ///   // No connection has been established yet
  /// }
  /// ```
  static Future<ZendeskConnectionStatus> getConnectionStatus() async {
    try {
      final result = await _channel.invokeMethod<String>('getConnectionStatus');
      return ZendeskConnectionStatus.fromString(result);
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('getConnectionStatus failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ============================================================================
  // Push Notifications
  // ============================================================================

  /// Register a push notification token with the Zendesk SDK.
  ///
  /// - **Android**: Pass the FCM registration token string directly.
  /// - **iOS**: Pass the raw APNs device token as a Base64-encoded string.
  ///
  /// Throws [ArgumentError] if token is empty.
  /// Throws [PlatformException] if the update fails.
  ///
  /// Example:
  /// ```dart
  /// // Android (FCM)
  /// final token = await FirebaseMessaging.instance.getToken();
  /// await ZendeskMessaging.updatePushNotificationToken(token!);
  ///
  /// // Refresh
  /// FirebaseMessaging.instance.onTokenRefresh.listen(
  ///   ZendeskMessaging.updatePushNotificationToken,
  /// );
  /// ```
  ///
  /// Throws [ArgumentError] if [token] is empty.
  static Future<void> updatePushNotificationToken(String token) async {
    if (token.isEmpty) throw ArgumentError('token cannot be empty');

    try {
      await _channel.invokeMethod<void>('updatePushNotificationToken', {'token': token});
      ZendeskMessagingConfig.log('Push notification token updated');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('updatePushNotificationToken failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Check whether a push notification payload belongs to Zendesk Messaging
  /// and whether the SDK should display it.
  ///
  /// [messageData] The notification data payload.
  ///
  /// Returns a [ZendeskPushResponsibility] indicating how to handle the notification:
  /// - [ZendeskPushResponsibility.messagingShouldDisplay]: Zendesk notification, SDK can display it
  /// - [ZendeskPushResponsibility.messagingShouldNotDisplay]: Zendesk notification, but should not display
  /// - [ZendeskPushResponsibility.notFromMessaging]: Not a Zendesk notification
  ///
  /// Example:
  /// ```dart
  /// FirebaseMessaging.onMessage.listen((message) async {
  ///   final responsibility = await ZendeskMessaging.shouldBeDisplayed(message.data);
  ///   switch (responsibility) {
  ///     case ZendeskPushResponsibility.messagingShouldDisplay:
  ///       // Let Zendesk handle it
  ///       await ZendeskMessaging.handleNotification(message.data);
  ///     case ZendeskPushResponsibility.notFromMessaging:
  ///       // Handle your own notification
  ///       showLocalNotification(message);
  ///     default:
  ///       break;
  ///   }
  /// });
  /// ```
  static Future<ZendeskPushResponsibility> shouldBeDisplayed(
    Map<String, dynamic> messageData,
  ) async {
    try {
      final result = await _channel.invokeMethod<String>('shouldBeDisplayed', {'messageData': messageData});
      return ZendeskPushResponsibility.fromString(result);
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('shouldBeDisplayed failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Hand a Zendesk push notification payload to the SDK for display.
  ///
  /// Returns `true` if the SDK handled the notification.
  ///
  /// Only call after [shouldBeDisplayed] returns
  /// [ZendeskPushResponsibility.messagingShouldDisplay].
  static Future<bool> handleNotification(
    Map<String, dynamic> messageData,
  ) async {
    try {
      final result = await _channel.invokeMethod<bool>('handleNotification', {'messageData': messageData});
      ZendeskMessagingConfig.log('Notification handled: $result');
      return result ?? false;
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('handleNotification failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Handle a user tap on a Zendesk push notification.
  ///
  /// Opens the relevant conversation screen.
  ///
  /// **Note**: On iOS, when the app is in a killed state, this may not
  /// navigate to the conversation as the SDK is not initialized.
  ///
  /// Example:
  /// ```dart
  /// FirebaseMessaging.onMessageOpenedApp.listen((message) {
  ///   ZendeskMessaging.handleNotificationTap(message.data);
  /// });
  /// ```
  static Future<void> handleNotificationTap(
    Map<String, dynamic> messageData,
  ) async {
    try {
      await _channel.invokeMethod<void>('handleNotificationTap', {'messageData': messageData});
      ZendeskMessagingConfig.log('Notification tap handled');
    } catch (e, stackTrace) {
      ZendeskMessagingConfig.logError('handleNotificationTap failed', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ============================================================================
  // Method Channel Handler
  // ============================================================================

  static Future<dynamic> _onMethodCall(MethodCall call) async {
    final arguments = call.arguments != null ? Map<String, dynamic>.from(call.arguments as Map) : <String, dynamic>{};

    switch (call.method) {
      // ── Primary event channel (matches native ON_EVENT = "onEvent") ─────────
      case 'onEvent':
        final event = ZendeskEventParser.parse(arguments);
        if (event != null) {
          if (!_eventController.isClosed) {
            _eventController.add(event);
          }
          // Forward unread count to legacy stream for backwards compatibility
          if (event is UnreadMessageCountChanged && !_unreadMessagesCountController.isClosed) {
            _unreadMessagesCountController.add(event.totalUnreadCount);
          }
        } else {
          ZendeskMessagingConfig.log('Could not parse onEvent payload: $arguments');
        }

      // ── Legacy Android unread callback (kept for safety) ───────────────────
      case 'unread_messages':
        final count = arguments['messages_count'] as int?;
        if (!_unreadMessagesCountController.isClosed) {
          _unreadMessagesCountController.add(count ?? 0);
        }

      default:
        ZendeskMessagingConfig.log('Unhandled method call: ${call.method}');
    }
  }

  /// Dispose all stream controllers.
  ///
  /// Call during app shutdown. After calling this, [eventStream] and
  /// [unreadMessagesCountStream] will no longer emit events.
  static void dispose() {
    if (!_eventController.isClosed) _eventController.close();
    if (!_unreadMessagesCountController.isClosed) {
      _unreadMessagesCountController.close();
    }
    ZendeskMessagingConfig.log('Streams disposed');
  }
}
