package com.chyiiiiiiiiiiiiii.zendesk_messaging

import android.app.Activity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

/** ZendeskMessagingPlugin */
class ZendeskMessagingPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    private val tag = "[ZendeskMessagingPlugin]"

    private lateinit var channel: MethodChannel
    private lateinit var zendeskMessaging: ZendeskMessaging

    var activity: Activity? = null
    var isInitialized: Boolean = false
    var isLoggedIn: Boolean = false


    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "zendesk_messaging")
        channel.setMethodCallHandler(this)
        zendeskMessaging = ZendeskMessaging(this, channel)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // Shared presentation params (Android only uses exitAction; viewMode is iOS-only)
        val exitAction: String? = call.argument("exitAction")

        when (call.method) {
            "initialize" -> {
                val channelKey = call.argument<String>("channelKey")
                if (channelKey.isNullOrEmpty()) {
                    result.error("invalid_args", "channelKey is required", null)
                    return
                }
                zendeskMessaging.initialize(channelKey, result)
            }

            "show" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                try {
                    zendeskMessaging.show(exitAction)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("show_error", e.message, null)
                }
            }

            "showConversation" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                val conversationId = call.argument<String>("conversationId")
                if (conversationId.isNullOrEmpty()) {
                    result.error("invalid_args", "conversationId is required", null)
                    return
                }
                val isClosed: Boolean = call.argument<Boolean>("isClosed") ?: false
                try {
                    zendeskMessaging.showConversation(conversationId, exitAction, isClosed)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("show_conversation_error", e.message, null)
                }
            }

            "showConversationList" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                try {
                    zendeskMessaging.showConversationList(exitAction)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("show_conversation_list_error", e.message, null)
                }
            }

            "startNewConversation" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                try {
                    zendeskMessaging.startNewConversation(exitAction)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("start_conversation_error", e.message, null)
                }
            }

            "loginUser" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                val jwt = call.argument<String>("jwt")
                if (jwt.isNullOrEmpty()) {
                    result.error("invalid_args", "jwt is required", null)
                    return
                }
                zendeskMessaging.loginUser(jwt, result)
            }

            "logoutUser" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                zendeskMessaging.logoutUser(result)
            }

            "getCurrentUser" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                zendeskMessaging.getCurrentUser(result)
            }

            "getUnreadMessageCount" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                result.success(zendeskMessaging.getUnreadMessageCount())
            }

            "getUnreadMessageCountForConversation" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                val conversationId = call.argument<String>("conversationId")
                if (conversationId.isNullOrEmpty()) {
                    result.error("invalid_args", "conversationId is required", null)
                    return
                }
                result.success(zendeskMessaging.getUnreadMessageCountForConversation(conversationId))
            }

            "listenUnreadMessages" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                try {
                    zendeskMessaging.listenMessageCountChanged()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("listen_error", e.message, null)
                }
            }

            "getConnectionStatus" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                result.success(zendeskMessaging.getConnectionStatus())
            }

            "isInitialized" -> result.success(isInitialized)
            "isLoggedIn" -> result.success(isLoggedIn)

            "setConversationTags" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                val tags = call.argument<List<String>>("tags")
                if (tags == null) {
                    result.error("invalid_args", "tags is required", null)
                    return
                }
                try {
                    zendeskMessaging.setConversationTags(tags)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("set_tags_error", e.message, null)
                }
            }

            "clearConversationTags" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                zendeskMessaging.clearConversationTags()
                result.success(null)
            }

            "setConversationFields" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                @Suppress("UNCHECKED_CAST")
                val fields = call.argument<Map<String, String>>("fields")
                if (fields == null) {
                    result.error("invalid_args", "fields is required", null)
                    return
                }
                try {
                    zendeskMessaging.setConversationFields(fields)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("set_fields_error", e.message, null)
                }
            }

            "clearConversationFields" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                zendeskMessaging.clearConversationFields()
                result.success(null)
            }

            "invalidate" -> {
                // Intentionally idempotent — does not error when not initialized
                zendeskMessaging.invalidate()
                result.success(null)
            }

            "updatePushNotificationToken" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                val token = call.argument<String>("token")
                if (token.isNullOrEmpty()) {
                    result.error("invalid_args", "token is required", null)
                    return
                }
                try {
                    zendeskMessaging.updatePushNotificationToken(token)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("push_token_error", e.message, null)
                }
            }

            "shouldBeDisplayed" -> {
                @Suppress("UNCHECKED_CAST")
                val messageData = call.argument<Map<String, Any>>("messageData")
                if (messageData == null) {
                    result.error("invalid_args", "messageData is required", null)
                    return
                }
                try {
                    val stringData = messageData.mapValues { it.value.toString() }
                    result.success(zendeskMessaging.shouldBeDisplayed(stringData))
                } catch (e: Exception) {
                    result.error("should_be_displayed_error", e.message, null)
                }
            }

            "handleNotification" -> {
                @Suppress("UNCHECKED_CAST")
                val messageData = call.argument<Map<String, Any>>("messageData")
                if (messageData == null) {
                    result.error("invalid_args", "messageData is required", null)
                    return
                }
                val ctx = activity ?: run {
                    result.error("no_context", "Activity context is null", null)
                    return
                }
                try {
                    val stringData = messageData.mapValues { it.value.toString() }
                    result.success(zendeskMessaging.handleNotification(ctx, stringData))
                } catch (e: Exception) {
                    result.error("handle_notification_error", e.message, null)
                }
            }

            "handleNotificationTap" -> {
                if (!isInitialized) {
                    reportNotInitializedError(result); return
                }
                @Suppress("UNCHECKED_CAST")
                val messageData = call.argument<Map<String, Any>>("messageData")
                if (messageData == null) {
                    result.error("invalid_args", "messageData is required", null)
                    return
                }
                val ctx = activity ?: run {
                    result.error("no_context", "Activity context is null", null)
                    return
                }
                try {
                    val stringData = messageData.mapValues { it.value.toString() }
                    zendeskMessaging.handleNotificationTap(ctx, stringData)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("handle_notification_tap_error", e.message, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun reportNotInitializedError(result: MethodChannel.Result) {
        result.error("not_initialized", "Zendesk SDK needs to be initialized first", null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }
}