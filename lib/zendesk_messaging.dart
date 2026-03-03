/// Zendesk Messaging SDK Flutter Plugin.
///
/// A Flutter plugin for integrating Zendesk Messaging SDK into your mobile
/// applications. Provides in-app customer support messaging with
/// multi-conversation support, real-time events, and JWT authentication.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:zendesk_messaging/zendesk_messaging.dart';
///
/// // 1. Initialize
/// await ZendeskMessaging.initialize(
///   androidChannelKey: 'your_android_key',
///   iosChannelKey: 'your_ios_key',
/// );
///
/// // 2. Subscribe to events
/// ZendeskMessaging.eventStream.listen((event) {
///   if (event is UnreadMessageCountChanged) {
///     print('Unread: ${event.totalUnreadCount}');
///   }
/// });
///
/// // 3. Start listening (required to receive UnreadMessageCountChanged)
/// await ZendeskMessaging.listenUnreadMessages();
///
/// // 4. Show messaging UI
/// await ZendeskMessaging.show();
/// ```
///
/// ## View Mode & Exit Action (iOS)
///
/// ```dart
/// // Sheet presentation with back-to-list navigation
/// await ZendeskMessaging.show(
///   viewMode: ZendeskViewMode.pageSheet,
///   exitAction: ZendeskExitAction.returnToConversationList,
/// );
///
/// // Specific conversation from a list
/// await ZendeskMessaging.showConversation(
///   conversationId: 'conv_abc123',
///   exitAction: ZendeskExitAction.returnToConversationList,
/// );
/// ```
library zendesk_messaging;

// Enums
export 'src/enums/authentication_type.dart';
export 'src/enums/connection_status.dart';
export 'src/enums/exit_action.dart';
export 'src/enums/push_responsibility.dart';
export 'src/enums/view_mode.dart';
export 'src/events/event_parser.dart';
// Events (zendesk_event.dart includes all event classes via part files)
export 'src/events/zendesk_event.dart';
// Models
export 'src/models/zendesk_login_response.dart';
export 'src/models/zendesk_message.dart';
export 'src/models/zendesk_user.dart';
// Main API
export 'src/zendesk_messaging.dart';
// Config
export 'src/zendesk_messaging_config.dart';
