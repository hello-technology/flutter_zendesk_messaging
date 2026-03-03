/// The navigation action taken when the user exits the messaging screen.
///
/// Controls what happens when the user taps the close/back button.
///
/// ## Usage
///
/// ```dart
/// // Go back to conversation list (multi-conversation mode)
/// await ZendeskMessaging.show(
///   exitAction: ZendeskExitAction.returnToConversationList,
/// );
///
/// // Close / dismiss entirely (default)
/// await ZendeskMessaging.show(
///   exitAction: ZendeskExitAction.close,
/// );
/// ```
enum ZendeskExitAction {
  /// Dismiss the messaging screen entirely (default).
  ///
  /// On iOS this pops or dismisses the view controller.
  /// On Android this finishes the Activity.
  close,

  /// Navigate back to the conversation list.
  ///
  /// Use this when showing a specific conversation so the user can
  /// return to the list instead of being dismissed. Requires
  /// multi-conversations to be enabled on your Zendesk account.
  returnToConversationList;

  /// The string value sent to the native platform.
  String get nativeValue {
    switch (this) {
      case ZendeskExitAction.close:
        return 'close';
      case ZendeskExitAction.returnToConversationList:
        return 'return_to_conversation_list';
    }
  }
}
