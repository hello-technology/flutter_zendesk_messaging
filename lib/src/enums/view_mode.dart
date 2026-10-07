/// Presentation style for the Zendesk Messaging UI.
///
/// Controls how the messaging screen is presented on iOS.
/// Android always presents as a full-screen Activity and ignores this setting.
///
/// ## Usage
///
/// ```dart
/// await ZendeskMessaging.show(viewMode: ZendeskViewMode.pageSheet);
/// ```
enum ZendeskViewMode {
  /// Full-screen presentation (default).
  ///
  /// Recommended for a dedicated conversation experience.
  fullscreen,

  /// System-default sheet presentation.
  ///
  /// Uses [pageSheet] on iOS 15+ and [formSheet] on older versions.
  sheet,

  /// Page sheet presentation (iOS 13+).
  ///
  /// Shows as a card that partially reveals the screen below.
  pageSheet,

  /// Form sheet presentation.
  ///
  /// Shows as a centered modal form.
  formSheet,

  /// Automatic system-determined presentation.
  automatic;

  /// The string value sent to the native platform.
  String get nativeValue => name;
}
