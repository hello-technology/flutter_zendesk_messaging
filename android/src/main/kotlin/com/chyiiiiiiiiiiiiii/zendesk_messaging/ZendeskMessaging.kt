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
import zendesk.android.events.ZendeskEvent
import zendesk.android.events.ZendeskEventListener
import zendesk.android.messaging.MessagingScreen
import zendesk.messaging.android.DefaultMessagingFactory
import zendesk.messaging.android.push.PushNotifications
import zendesk.messaging.android.push.PushResponsibility

class ZendeskMessaging(
    private val plugin: ZendeskMessagingPlugin,
    private val channel: MethodChannel,
) {
    companion object {
        const val TAG = "[ZendeskMessaging]"
        const val ON_EVENT = "onEvent"

        // How many times to retry hiding the composer, and the interval between retries.
        private const val COMPOSER_HIDE_MAX_RETRIES = 20
        private const val COMPOSER_HIDE_RETRY_DELAY_MS = 150L
    }

    // Guard against duplicate event listener registration
    private var eventListenerRegistered = false

    // Cached user after loginUser success
    private var cachedUser: Map<String, Any?>? = null

    // Last known connection status
    private var lastConnectionStatus = "unknown"

    private val zendeskEventListener = ZendeskEventListener { event ->
        try {
            handleZendeskEvent(event)
        } catch (e: Exception) {
            Log.e(TAG, "Error handling ZendeskEvent: ${e.message}")
        }
    }


    // Initialization


    fun initialize(channelKey: String, result: MethodChannel.Result) {
        val activity = plugin.activity ?: run {
            result.error("no_activity", "Activity is null", null)
            return
        }
        try {
            Zendesk.initialize(
                activity,
                channelKey,
                successCallback = {
                    plugin.isInitialized = true
                    listenMessageCountChanged()
                    Log.d(TAG, "Initialized successfully")
                    result.success(null)
                },
                failureCallback = { error ->
                    plugin.isInitialized = false
                    Log.e(TAG, "Initialization failed: ${error.message}")
                    result.error("initialize_error", error.message, null)
                },
                messagingFactory = DefaultMessagingFactory()
            )
        } catch (e: Exception) {
            result.error("initialize_exception", e.message, null)
        }
    }

    fun invalidate() {
        try {
            if (eventListenerRegistered) {
                Zendesk.instance.removeEventListener(zendeskEventListener)
                eventListenerRegistered = false
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error removing event listener: ${e.message}")
        }
        try {
            Zendesk.invalidate()
        } catch (e: Exception) {
            Log.w(TAG, "Error invalidating Zendesk: ${e.message}")
        }
        plugin.isInitialized = false
        plugin.isLoggedIn = false
        cachedUser = null
        lastConnectionStatus = "unknown"
        Log.d(TAG, "SDK invalidated")
    }


    // Exit Action Helper


    private fun resolveExitAction(exitAction: String?): MessagingScreen.ExitAction {
        return if (exitAction == "return_to_conversation_list") {
            MessagingScreen.ExitAction.ReturnToConversationList
        } else {
            MessagingScreen.ExitAction.Close
        }
    }


    // Messaging UI


    fun show(exitAction: String?) {
        val activity = plugin.activity ?: return
        Zendesk.instance.messaging.showMessaging(
            activity,
            MessagingScreen.MostRecentActiveConversation(
                onExit = resolveExitAction(exitAction)
            )
        )
        Log.d(TAG, "show() — exitAction=$exitAction")
    }

    fun showConversation(conversationId: String, exitAction: String?, isClosed: Boolean = false) {
        val activity = plugin.activity ?: return
        Zendesk.instance.messaging.showMessaging(
            activity,
            MessagingScreen.Conversation(
                id = conversationId,
                onExit = resolveExitAction(exitAction)
            )
        )
        // showMessaging() launches a new Activity. We register a one-shot
        // ActivityLifecycleCallbacks so we are notified the moment that new
        // Activity is resumed and its views are ready, then retry hiding the
        // composer until we find it (or exhaust our attempts).
        if (isClosed) {
            scheduleComposerHide(activity.application)
        }
        Log.d(
            TAG,
            "showConversation() — id=$conversationId exitAction=$exitAction isClosed=$isClosed"
        )
    }

    fun showConversationList(exitAction: String?) {
        val activity = plugin.activity ?: return
        Zendesk.instance.messaging.showMessaging(
            activity,
            MessagingScreen.ConversationsList
        )
        Log.d(TAG, "showConversationList() — exitAction=$exitAction")
    }

    fun startNewConversation(exitAction: String?) {
        val activity = plugin.activity ?: return
        Zendesk.instance.messaging.showMessaging(
            activity,
            MessagingScreen.NewConversation(
                onExit = resolveExitAction(exitAction)
            )
        )
        Log.d(TAG, "startNewConversation() — exitAction=$exitAction")
    }


    // Composer Hiding


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


    // Authentication


    fun loginUser(jwt: String, result: MethodChannel.Result) {
        try {
            Zendesk.instance.loginUser(
                jwt,
                { user ->
                    plugin.isLoggedIn = true
                    cachedUser = mapOf(
                        "id" to user.id,
                        "externalId" to user.externalId,
                        "authenticationType" to "jwt",
                    )
                    Log.d(TAG, "User logged in: ${user.id}")
                    result.success(mapOf("id" to user.id, "externalId" to user.externalId))
                },
                { error ->
                    Log.e(TAG, "Login failure: ${error.message}")
                    result.error("login_error", error.message, null)
                }
            )
        } catch (e: Exception) {
            result.error("login_exception", e.message, null)
        }
    }

    fun logoutUser(result: MethodChannel.Result) {
        try {
            Zendesk.instance.logoutUser(
                {
                    plugin.isLoggedIn = false
                    cachedUser = null
                    removeEventListener()
                    Log.d(TAG, "User logged out")
                    result.success(null)
                },
                { error ->
                    Log.e(TAG, "Logout failure: ${error.message}")
                    result.error("logout_error", error.message, null)
                }
            )
        } catch (e: Exception) {
            result.error("logout_exception", e.message, null)
        }
    }

    fun getCurrentUser(result: MethodChannel.Result) {
        result.success(cachedUser)
    }


    // Unread Messages


    fun getUnreadMessageCount(): Int {
        return try {
            Zendesk.instance.messaging.getUnreadMessageCount()
        } catch (e: Exception) {
            Log.e(TAG, "Error getting unread count: ${e.message}")
            0
        }
    }

    fun getUnreadMessageCountForConversation(conversationId: String): Int {
        // The Zendesk Android SDK does not expose a per-conversation count API;
        // return the total count as the nearest available value.
        return getUnreadMessageCount()
    }

    fun listenMessageCountChanged() {
        if (eventListenerRegistered) {
            Log.d(TAG, "Event listener already registered — skipping duplicate registration")
            return
        }
        try {
            Zendesk.instance.addEventListener(zendeskEventListener)
            eventListenerRegistered = true
            Log.d(TAG, "Event listener registered")
        } catch (e: Exception) {
            Log.e(TAG, "Error registering event listener: ${e.message}")
        }
    }

    private fun removeEventListener() {
        if (!eventListenerRegistered) return
        try {
            Zendesk.instance.removeEventListener(zendeskEventListener)
            eventListenerRegistered = false
            Log.d(TAG, "Event listener removed")
        } catch (e: Exception) {
            Log.w(TAG, "Error removing event listener: ${e.message}")
        }
    }


    // Connection Status


    fun getConnectionStatus(): String = lastConnectionStatus


    // Conversation Metadata


    fun setConversationTags(tags: List<String>) {
        try {
            Zendesk.instance.messaging.setConversationTags(tags)
        } catch (e: Exception) {
            Log.e(TAG, "Error setting tags: ${e.message}")
        }
    }

    fun clearConversationTags() {
        try {
            Zendesk.instance.messaging.clearConversationTags()
        } catch (e: Exception) {
            Log.e(TAG, "Error clearing tags: ${e.message}")
        }
    }

    fun setConversationFields(fields: Map<String, String>) {
        try {
            Zendesk.instance.messaging.setConversationFields(fields)
        } catch (e: Exception) {
            Log.e(TAG, "Error setting fields: ${e.message}")
        }
    }

    fun clearConversationFields() {
        try {
            Zendesk.instance.messaging.clearConversationFields()
        } catch (e: Exception) {
            Log.e(TAG, "Error clearing fields: ${e.message}")
        }
    }


    // Push Notifications


    fun updatePushNotificationToken(token: String) {
        try {
            PushNotifications.updatePushNotificationToken(token)
            Log.d(TAG, "Push notification token updated")
        } catch (e: Exception) {
            Log.e(TAG, "Error updating push token: ${e.message}")
        }
    }

    fun shouldBeDisplayed(data: Map<String, String>): String {
        return try {
            when (PushNotifications.shouldBeDisplayed(data)) {
                PushResponsibility.MESSAGING_SHOULD_DISPLAY ->
                    "messagingShouldDisplay"

                PushResponsibility.MESSAGING_SHOULD_NOT_DISPLAY ->
                    "messagingShouldNotDisplay"

                else -> "notFromMessaging"
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error in shouldBeDisplayed: ${e.message}")
            "notFromMessaging"
        }
    }

    fun handleNotification(context: Context, data: Map<String, String>): Boolean {
        return try {
            when (PushNotifications.shouldBeDisplayed(data)) {
                PushResponsibility.MESSAGING_SHOULD_DISPLAY -> {
                    PushNotifications.displayNotification(context, data)
                    true
                }

                else -> false
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error handling notification: ${e.message}")
            false
        }
    }

    fun handleNotificationTap(context: Context, data: Map<String, String>) {
        // The Android SDK handles notification taps automatically via a PendingIntent
        // set up by PushNotifications.displayNotification(). If called manually
        // (e.g. from a background message), open the most recent conversation.
        try {
            val activity = plugin.activity
            if (activity != null) {
                Zendesk.instance.messaging.showMessaging(
                    activity,
                    MessagingScreen.MostRecentActiveConversation(
                        onExit = MessagingScreen.ExitAction.Close
                    )
                )
            }
            Log.d(TAG, "handleNotificationTap — opened most recent conversation")
        } catch (e: Exception) {
            Log.e(TAG, "Error handling notification tap: ${e.message}")
        }
    }


    // Zendesk Event Handling


    private fun handleZendeskEvent(event: ZendeskEvent) {
        val now = System.currentTimeMillis()

        try {
            when (event) {

                is ZendeskEvent.UnreadMessageCountChanged -> {
                    channel.invokeMethod(
                        ON_EVENT, mapOf(
                            "type" to "unreadMessageCountChanged",
                            "timestamp" to now,
                            "totalUnreadCount" to event.currentUnreadCount,
                        )
                    )
                }

                is ZendeskEvent.AuthenticationFailed -> {
                    channel.invokeMethod(
                        ON_EVENT, mapOf(
                            "type" to "authenticationFailed",
                            "timestamp" to now,
                            "errorCode" to "auth_error",
                            "errorMessage" to (event.error.message ?: "Unknown error"),
                            "isJwtExpired" to false,
                        )
                    )
                }

                is ZendeskEvent.FieldValidationFailed -> {
                    val errors = event.errors.mapNotNull { it.message }
                    channel.invokeMethod(
                        ON_EVENT, mapOf(
                            "type" to "fieldValidationFailed",
                            "timestamp" to now,
                            "errors" to errors,
                        )
                    )
                }

                is ZendeskEvent.ConnectionStatusChanged -> {
                    val status = event.connectionStatus.toString().lowercase()
                    lastConnectionStatus = status
                    channel.invokeMethod(
                        ON_EVENT, mapOf(
                            "type" to "connectionStatusChanged",
                            "timestamp" to now,
                            "status" to status,
                        )
                    )
                }

                is ZendeskEvent.SendMessageFailed -> {
                    channel.invokeMethod(
                        ON_EVENT, mapOf(
                            "type" to "sendMessageFailed",
                            "timestamp" to now,
                            "errorMessage" to (event.cause.message ?: "Unknown error"),
                        )
                    )
                }

                is ZendeskEvent.ConversationAdded -> {
                    channel.invokeMethod(
                        ON_EVENT, mapOf(
                            "type" to "conversationAdded",
                            "timestamp" to now,
                            "conversationId" to event.conversationId,
                        )
                    )
                }

                is ZendeskEvent.ConversationStarted -> {
                    channel.invokeMethod(
                        ON_EVENT, mapOf(
                            "type" to "conversationStarted",
                            "timestamp" to now,
                            "conversationId" to event.conversationId,
                        )
                    )
                }

                is ZendeskEvent.MessagingOpened -> {
                    channel.invokeMethod(
                        ON_EVENT, mapOf(
                            "type" to "messagingOpened",
                            "timestamp" to now,
                        )
                    )
                }

                is ZendeskEvent.MessagingClosed -> {
                    channel.invokeMethod(
                        ON_EVENT, mapOf(
                            "type" to "messagingClosed",
                            "timestamp" to now,
                        )
                    )
                }

                is ZendeskEvent.NotificationOpened -> {
                    channel.invokeMethod(
                        ON_EVENT, mapOf(
                            "type" to "notificationOpened",
                            "timestamp" to now,
                            "conversationId" to event.data.conversationId,
                        )
                    )
                }

                else -> Log.d(TAG, "Unhandled event: $event")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error emitting ZendeskEvent: ${e.message}")
        }
    }
}