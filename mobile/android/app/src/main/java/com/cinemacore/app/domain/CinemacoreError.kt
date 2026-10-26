package com.cinemacore.app.domain

/** Typed failures at the repository boundary. Screens decide presentation. */
sealed class CinemacoreError(message: String? = null) : Exception(message) {
    data object Offline : CinemacoreError("You appear to be offline.")

    data object TimedOut : CinemacoreError("The request took too long.")

    data object Cancelled : CinemacoreError("The request was cancelled.")

    data object NotFound : CinemacoreError("That title could not be found.")

    data class BadURL(val value: String) : CinemacoreError("That address is not valid.")

    data class Http(
        val status: Int,
        val code: String? = null,
        val upstreamMessage: String? = null,
    ) : CinemacoreError(upstreamMessage ?: "The server answered $status.")

    data class Upstream(val detail: String? = null) : CinemacoreError(
        detail?.takeIf { it.isNotBlank() } ?: "The provider is unavailable.",
    )

    data class Decoding(val detail: String? = null) : CinemacoreError(
        detail?.takeIf { it.isNotBlank() } ?: "The response could not be read.",
    )

    data class Unknown(val detail: String? = null) : CinemacoreError(
        detail?.takeIf { it.isNotBlank() } ?: "Something went wrong.",
    )

    val userMessage: String
        get() = when (this) {
            Offline -> "You appear to be offline. Check the connection and try again."
            TimedOut -> "The server took too long to answer. Try again."
            Cancelled -> "The request was cancelled."
            NotFound -> "That title is no longer available."
            is BadURL -> "That address is not valid."
            is Http -> when (status) {
                401, 403 -> "This source refused the request."
                404 -> "That title is no longer available."
                429 -> "Too many requests. Wait a moment and try again."
                in 500..599 -> "The provider is having trouble right now."
                else -> "The server answered $status."
            }
            is Upstream -> detail?.takeIf { it.isNotBlank() } ?: "The provider is unavailable."
            is Decoding -> "The server sent a response this app could not read."
            is Unknown -> detail?.takeIf { it.isNotBlank() } ?: "Something went wrong."
        }

    val isRetryable: Boolean
        get() = when (this) {
            Offline, TimedOut, Cancelled -> true
            is Http -> status == 408 || status == 429 || status >= 500
            is Upstream, is Unknown -> true
            else -> false
        }

    val requiresGate: Boolean
        get() = this is Http && (status == 401 || status == 403)
}
