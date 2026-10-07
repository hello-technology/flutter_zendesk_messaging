package com.chyiiiiiiiiiiiiii.zendesk_messaging

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import io.flutter.plugin.common.MethodChannel
import zendesk.android.Zendesk
import zendesk.android.ZendeskUser
import zendesk.android.events.ZendeskEvent
import zendesk.android.events.ZendeskEventListener
import zendesk.android.messaging.MessagingScreen
import zendesk.messaging.android.DefaultMessagingFactory
import zendesk.messaging.android.push.PushNotifications
import zendesk.messaging.android.push.PushResponsibility

class ZendeskMessaging(
    private val plugin: ZendeskMessagingPlugin,
    private val channel: MethodChannel
) {
    companion object {
        const val TAG = "[ZendeskMessaging]"

        // Method channel event keys
        const val EVENT_UNREAD_MESSAGES = "unread_messages"
        const val EVENT_ZENDESK_EVENT = "zendesk_event"

        private const val COMPOSER_HIDE_MAX_RETRIES = 20
        private const val COMPOSER_HIDE_RETRY_DELAY_MS = 150L
    }

    // Event listener for all Zendesk events
    private var eventListenerRegistered = false
    private var lastConnectionStatus = "unknown"

    private val zendeskEventListener = ZendeskEventListener { zendeskEvent ->
        handleZendeskEvent(zendeskEvent)
    }

    private fun handleZendeskEvent(zendeskEvent: ZendeskEvent) {
        when (zendeskEvent) {
            is ZendeskEvent.UnreadMessageCountChanged -> {
                // Legacy callback for backwards compatibility
                channel.invokeMethod(
                    EVENT_UNREAD_MESSAGES,
                    mapOf("messages_count" to zendeskEvent.currentUnreadCount)
                )
                // New event system
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "unreadMessageCountChanged",
                        "timestamp" to System.currentTimeMillis(),
                        "totalUnreadCount" to zendeskEvent.currentUnreadCount
                    )
                )
            }

            is ZendeskEvent.AuthenticationFailed -> {
                val isJwtExpired = zendeskEvent.error.message?.contains("expired", ignoreCase = true) == true
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "authenticationFailed",
                        "timestamp" to System.currentTimeMillis(),
                        "errorCode" to "authentication_failed",
                        "errorMessage" to (zendeskEvent.error.message ?: "Unknown error"),
                        "isJwtExpired" to isJwtExpired
                    )
                )
            }

            is ZendeskEvent.FieldValidationFailed -> {
                val errorMessages = zendeskEvent.errors.map { it.toString() }
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "fieldValidationFailed",
                        "timestamp" to System.currentTimeMillis(),
                        "errors" to errorMessages
                    )
                )
            }

            is ZendeskEvent.ConnectionStatusChanged -> {
                // CONNECTED_REALTIME -> "connectedrealtime", the form Dart parses
                lastConnectionStatus = zendeskEvent.connectionStatus.name.lowercase().replace("_", "")
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "connectionStatusChanged",
                        "timestamp" to System.currentTimeMillis(),
                        "status" to lastConnectionStatus
                    )
                )
            }

            is ZendeskEvent.SendMessageFailed -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "sendMessageFailed",
                        "timestamp" to System.currentTimeMillis(),
                        "errorMessage" to (zendeskEvent.cause.message ?: "Unknown error")
                    )
                )
            }

            is ZendeskEvent.ConversationAdded -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "conversationAdded",
                        "timestamp" to System.currentTimeMillis(),
                        "conversationId" to zendeskEvent.conversationId
                    )
                )
            }

            is ZendeskEvent.ConversationStarted -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "conversationStarted",
                        "timestamp" to System.currentTimeMillis(),
                        "conversationId" to zendeskEvent.conversationId
                    )
                )
            }

            is ZendeskEvent.ConversationOpened -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "conversationOpened",
                        "timestamp" to System.currentTimeMillis(),
                        "conversationId" to zendeskEvent.conversationId
                    )
                )
            }

            is ZendeskEvent.MessagesShown -> {
                val messagesData = zendeskEvent.messages.map { message ->
                    mapOf(
                        "id" to message.id,
                        "conversationId" to zendeskEvent.conversationId
                    )
                }
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "messagesShown",
                        "timestamp" to System.currentTimeMillis(),
                        "conversationId" to zendeskEvent.conversationId,
                        "messages" to messagesData
                    )
                )
            }

            is ZendeskEvent.ProactiveMessageDisplayed -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "proactiveMessageDisplayed",
                        "timestamp" to System.currentTimeMillis(),
                        "proactiveMessageId" to "",
                        "campaignId" to null
                    )
                )
            }

            is ZendeskEvent.ProactiveMessageClicked -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "proactiveMessageClicked",
                        "timestamp" to System.currentTimeMillis(),
                        "proactiveMessageId" to "",
                        "campaignId" to null
                    )
                )
            }

            is ZendeskEvent.ConversationWithAgentRequested -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "conversationWithAgentRequested",
                        "timestamp" to System.currentTimeMillis(),
                        "conversationId" to ""
                    )
                )
            }

            is ZendeskEvent.ConversationServedByAgent -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "conversationServedByAgent",
                        "timestamp" to System.currentTimeMillis(),
                        "conversationId" to ""
                    )
                )
            }

            is ZendeskEvent.MessagingOpened -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "messagingOpened",
                        "timestamp" to System.currentTimeMillis()
                    )
                )
            }

            is ZendeskEvent.MessagingClosed -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "messagingClosed",
                        "timestamp" to System.currentTimeMillis()
                    )
                )
            }

            is ZendeskEvent.NewConversationButtonClicked -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "newConversationButtonClicked",
                        "timestamp" to System.currentTimeMillis()
                    )
                )
            }

            is ZendeskEvent.PostbackButtonClicked -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "postbackButtonClicked",
                        "timestamp" to System.currentTimeMillis(),
                        "conversationId" to "",
                        "actionName" to ""
                    )
                )
            }

            is ZendeskEvent.ConversationExtensionOpened -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "conversationExtensionOpened",
                        "timestamp" to System.currentTimeMillis(),
                        "conversationId" to "",
                        "extensionUrl" to ""
                    )
                )
            }

            is ZendeskEvent.ConversationExtensionDisplayed -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "conversationExtensionDisplayed",
                        "timestamp" to System.currentTimeMillis(),
                        "conversationId" to "",
                        "extensionUrl" to ""
                    )
                )
            }

            is ZendeskEvent.ArticleBrowserClicked -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "articleBrowserClicked",
                        "timestamp" to System.currentTimeMillis(),
                        "articleUrl" to ""
                    )
                )
            }

            is ZendeskEvent.ArticleClicked -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "articleClicked",
                        "timestamp" to System.currentTimeMillis(),
                        "articleUrl" to "",
                        "conversationId" to ""
                    )
                )
            }

            is ZendeskEvent.NotificationDisplayed -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "notificationDisplayed",
                        "timestamp" to System.currentTimeMillis(),
                        "conversationId" to ""
                    )
                )
            }

            is ZendeskEvent.NotificationOpened -> {
                channel.invokeMethod(
                    EVENT_ZENDESK_EVENT,
                    mapOf(
                        "type" to "notificationOpened",
                        "timestamp" to System.currentTimeMillis(),
                        "conversationId" to ""
                    )
                )
            }

            else -> {
                // Default branch for forward compatibility with Zendesk SDK and its `ZendeskEvent` expansion
                println("$TAG - Unknown event type: $zendeskEvent")
            }
        }
    }

    fun initialize(channelKey: String, result: MethodChannel.Result) {
        println("$TAG - Channel Key - $channelKey")
        // Zendesk.initialize requires an Activity. Guard against a null
        // Activity (background isolate / terminated state) so callers get a
        // clean error instead of a NullPointerException. Push display does
        // not need initialize — use shouldBeDisplayed/handleNotification.
        val currentActivity = plugin.activity ?: run {
            println("$TAG - initialize skipped: no Activity in this context")
            result.error(
                "no_activity",
                "Zendesk.initialize requires an Activity and cannot run without one",
                null,
            )
            return
        }
        Zendesk.initialize(
            currentActivity,
            channelKey,
            successCallback = { value ->
                plugin.isInitialized = true
                println("$TAG - initialize success - $value")
                result.success(null)
            },
            failureCallback = { error ->
                plugin.isInitialized = false
                println("$TAG - initialize failure - $error")
                result.error("initialize_error", error.message, null)
            },
            messagingFactory = DefaultMessagingFactory()
        )
    }

    fun invalidate() {
        removeEventListener()
        Zendesk.invalidate()
        lastConnectionStatus = "unknown"
        plugin.isInitialized = false
        plugin.isLoggedIn = false
        println("$TAG - invalidated")
    }

    fun show(exitAction: String?) {
        val activity = plugin.activity ?: return
        Zendesk.instance.messaging.showMessaging(
            activity,
            MessagingScreen.MostRecentActiveConversation(onExit = resolveExitAction(exitAction))
        )
        println("$TAG - show")
    }

    fun showConversation(conversationId: String, exitAction: String?, isClosed: Boolean) {
        val activity = plugin.activity ?: return
        Zendesk.instance.messaging.showMessaging(
            activity,
            MessagingScreen.Conversation(id = conversationId, onExit = resolveExitAction(exitAction))
        )
        if (isClosed) {
            scheduleComposerHide(activity.application)
        }
        println("$TAG - showConversation: $conversationId (isClosed: $isClosed)")
    }

    fun showConversationList() {
        val activity = plugin.activity ?: return
        Zendesk.instance.messaging.showMessaging(
            activity,
            MessagingScreen.ConversationsList
        )
        println("$TAG - showConversationList")
    }

    fun startNewConversation(exitAction: String?) {
        val activity = plugin.activity ?: return
        Zendesk.instance.messaging.showMessaging(
            activity,
            MessagingScreen.NewConversation(onExit = resolveExitAction(exitAction))
        )
        println("$TAG - startNewConversation")
    }

    private fun resolveExitAction(exitAction: String?): MessagingScreen.ExitAction =
        if (exitAction == "return_to_conversation_list") {
            MessagingScreen.ExitAction.ReturnToConversationList
        } else {
            MessagingScreen.ExitAction.Close
        }

    // Hides the composer so a closed conversation stays read-only.

    /**
     * Registers a one-shot [Application.ActivityLifecycleCallbacks] that fires
     * when the next Zendesk Activity is resumed.  At that point the window is
     * guaranteed to exist, so we start a retry loop that keeps trying to find
     * and hide the composer until it succeeds or retries are exhausted.
     */
    private fun scheduleComposerHide(app: Application) {
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(a: Activity) {
                // Unregister immediately — one-shot only.
                app.unregisterActivityLifecycleCallbacks(this)
                retryHideComposer(a, COMPOSER_HIDE_MAX_RETRIES)
            }

            override fun onActivityCreated(a: Activity, b: Bundle?) {}
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        })
    }

    /**
     * Tries to hide the composer in [activity].  If the view tree is not yet
     * ready (EditText not found), schedules another attempt after
     * [COMPOSER_HIDE_RETRY_DELAY_MS] ms, up to [attemptsLeft] more times.
     */
    private fun retryHideComposer(activity: Activity, attemptsLeft: Int) {
        if (attemptsLeft <= 0) {
            Log.w(TAG, "retryHideComposer — gave up after all attempts")
            return
        }
        val decorView = activity.window?.decorView ?: return
        decorView.post {
            val hidden = tryHideComposer(activity)
            if (!hidden) {
                Handler(Looper.getMainLooper()).postDelayed({
                    retryHideComposer(activity, attemptsLeft - 1)
                }, COMPOSER_HIDE_RETRY_DELAY_MS)
            }
        }
    }

    /**
     * Attempts a single hide pass.  Returns `true` if the composer was found
     * and hidden, `false` if not found yet.
     */
    private fun tryHideComposer(activity: Activity): Boolean {
        return try {
            val contentRoot = activity.window?.decorView
                ?.findViewById<ViewGroup>(android.R.id.content) ?: return false

            val editText = findFirstEditText(contentRoot) ?: return false

            // Walk up to a direct child of contentRoot so we hide the full
            // composer bar, not just the EditText itself.
            var candidate: View = editText
            while (candidate.parent != null && candidate.parent !== contentRoot) {
                candidate = candidate.parent as? View ?: break
            }

            // Only hide if the candidate sits in the bottom half of the screen
            // (guards against accidentally hiding a message input in the middle).
            val location = IntArray(2)
            candidate.getLocationInWindow(location)
            val screenMidY = contentRoot.height / 2

            if (screenMidY > 0 && location[1] > screenMidY) {
                candidate.visibility = View.GONE
            } else {
                // Fallback: hide the EditText's immediate parent container.
                (editText.parent as? View)?.visibility = View.GONE
            }

            Log.d(TAG, "tryHideComposer — composer hidden successfully")
            true
        } catch (e: Exception) {
            Log.w(TAG, "tryHideComposer — error: ${e.message}")
            false
        }
    }

    private fun findFirstEditText(view: View): EditText? {
        if (view is EditText) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findFirstEditText(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    fun getUnreadMessageCount(): Int =
        try {
            Zendesk.instance.messaging.getUnreadMessageCount()
        } catch (error: Throwable) {
            println("$TAG - getUnreadMessageCount error: ${error.message}")
            0
        }

    fun getUnreadMessageCountForConversation(conversationId: String): Int =
        try {
            Zendesk.instance.messaging.getUnreadMessageCount(conversationId)
        } catch (error: Throwable) {
            println("$TAG - getUnreadMessageCountForConversation error: ${error.message}")
            0
        }

    fun setConversationTags(tags: List<String>) {
        Zendesk.instance.messaging.setConversationTags(tags)
        println("$TAG - setConversationTags: $tags")
    }

    fun clearConversationTags() {
        Zendesk.instance.messaging.clearConversationTags()
        println("$TAG - clearConversationTags")
    }

    fun loginUser(jwt: String, result: MethodChannel.Result) {
        Zendesk.instance.loginUser(
            jwt,
            { user ->
                plugin.isLoggedIn = true
                result.success(
                    mapOf(
                        "id" to user.id,
                        "externalId" to user.externalId,
                        "authenticationType" to getAuthenticationType(user)
                    )
                )
                println("$TAG - loginUser success")
            },
            { error ->
                println("$TAG - Login failure : ${error.message}")
                result.error("login_error", error.message, null)
            }
        )
    }

    fun logoutUser(result: MethodChannel.Result) {
        Zendesk.instance.logoutUser(
            successCallback = {
                plugin.isLoggedIn = false
                result.success(null)
                println("$TAG - logoutUser success")
            },
            failureCallback = { error ->
                println("$TAG - Logout failure : ${error.message}")
                result.error("logout_error", error.message, null)
            }
        )
        removeEventListener()
    }

    fun getCurrentUser(result: MethodChannel.Result) {
        try {
            Zendesk.instance.getCurrentUser { user ->
                if (user != null) {
                    result.success(
                        mapOf(
                            "id" to user.id,
                            "externalId" to user.externalId,
                            "authenticationType" to getAuthenticationType(user)
                        )
                    )
                } else {
                    result.success(null)
                }
            }
        } catch (error: Throwable) {
            println("$TAG - getCurrentUser error: ${error.message}")
            result.success(null)
        }
    }

    private fun getAuthenticationType(user: ZendeskUser): String {
        return try {
            when (user.authenticationType) {
                zendesk.android.ZendeskAuthenticationType.Jwt -> "jwt"
                else -> "anonymous"
            }
        } catch (e: Throwable) {
            "anonymous"
        }
    }

    fun getConnectionStatus(): String = lastConnectionStatus

    fun listenMessageCountChanged() {
        if (eventListenerRegistered) return
        Zendesk.instance.addEventListener(zendeskEventListener)
        eventListenerRegistered = true
        println("$TAG - listenMessageCountChanged - Event listener added")
    }

    private fun removeEventListener() {
        if (!eventListenerRegistered) return
        Zendesk.instance.removeEventListener(zendeskEventListener)
        eventListenerRegistered = false
    }

    fun setConversationFields(fields: Map<String, String>) {
        Zendesk.instance.messaging.setConversationFields(fields)
        println("$TAG - setConversationFields: $fields")
    }

    fun clearConversationFields() {
        Zendesk.instance.messaging.clearConversationFields()
        println("$TAG - clearConversationFields")
    }

    // ============================================================================
    // Locale
    // ============================================================================

    fun setLocale(locale: String) {
        val parsedLocale = java.util.Locale.forLanguageTag(locale)
        java.util.Locale.setDefault(parsedLocale)

        // Update application context so new Activities launched by the SDK
        // inherit the correct locale for resource resolution
        plugin.activity?.applicationContext?.let { appContext ->
            val appConfig = android.content.res.Configuration(appContext.resources.configuration)
            appConfig.setLocale(parsedLocale)
            @Suppress("DEPRECATION")
            appContext.resources.updateConfiguration(appConfig, appContext.resources.displayMetrics)
        }

        // Update current activity context for immediate effect
        plugin.activity?.let { activity ->
            val config = android.content.res.Configuration(activity.resources.configuration)
            config.setLocale(parsedLocale)
            @Suppress("DEPRECATION")
            activity.resources.updateConfiguration(config, activity.resources.displayMetrics)
        }
        println("$TAG - setLocale: $locale")
    }

    // ============================================================================
    // Push Notifications
    // ============================================================================

    /**
     * Update the push notification token with Zendesk.
     * Call this when receiving a new FCM token.
     */
    fun updatePushNotificationToken(token: String) {
        try {
            PushNotifications.updatePushNotificationToken(token)
            println("$TAG - updatePushNotificationToken: token updated")
        } catch (error: Throwable) {
            println("$TAG - updatePushNotificationToken error: ${error.message}")
            throw error
        }
    }

    /**
     * Check if a push notification should be displayed by Zendesk.
     * Returns the responsibility indicating how to handle the notification.
     */
    fun shouldBeDisplayed(messageData: Map<String, String>): String {
        return try {
            val responsibility = PushNotifications.shouldBeDisplayed(messageData)
            val result = when (responsibility) {
                PushResponsibility.MESSAGING_SHOULD_DISPLAY -> "messaging_should_display"
                PushResponsibility.MESSAGING_SHOULD_NOT_DISPLAY -> "messaging_should_not_display"
                PushResponsibility.NOT_FROM_MESSAGING -> "not_from_messaging"
                else -> "unknown"
            }
            println("$TAG - shouldBeDisplayed: $result")
            result
        } catch (error: Throwable) {
            println("$TAG - shouldBeDisplayed error: ${error.message}")
            "unknown"
        }
    }

    /**
     * Handle and display a push notification.
     * Returns true if the notification was handled by Zendesk.
     */
    fun handleNotification(context: Context, messageData: Map<String, String>): Boolean {
        return try {
            val responsibility = PushNotifications.shouldBeDisplayed(messageData)
            if (responsibility == PushResponsibility.MESSAGING_SHOULD_DISPLAY) {
                PushNotifications.displayNotification(context, messageData)
                println("$TAG - handleNotification: notification displayed")
                true
            } else {
                println("$TAG - handleNotification: not a Zendesk notification")
                false
            }
        } catch (error: Throwable) {
            println("$TAG - handleNotification error: ${error.message}")
            false
        }
    }

    /**
     * Handle a notification tap event.
     * Opens the messaging UI to the relevant conversation.
     */
    fun handleNotificationTap(context: Context, messageData: Map<String, String>) {
        try {
            val responsibility = PushNotifications.shouldBeDisplayed(messageData)
            if (responsibility == PushResponsibility.MESSAGING_SHOULD_DISPLAY) {
                // Show messaging UI - the SDK will navigate to the correct conversation
                Zendesk.instance.messaging.showMessaging(
                    plugin.activity!!,
                    MessagingScreen.MostRecentActiveConversation()
                )
                println("$TAG - handleNotificationTap: opened messaging")
            } else {
                println("$TAG - handleNotificationTap: not a Zendesk notification")
            }
        } catch (error: Throwable) {
            println("$TAG - handleNotificationTap error: ${error.message}")
            throw error
        }
    }
}
