package com.cinemacore.app.data

import com.cinemacore.app.data.api.apis.BrowseApi
import com.cinemacore.app.data.api.apis.SystemApi
import com.cinemacore.app.data.api.apis.TitleApi
import com.cinemacore.app.data.api.models.Page as WirePage
import com.cinemacore.app.data.api.models.PlayInfo as WirePlayInfo
import com.cinemacore.app.data.api.models.Seasons200Response
import com.cinemacore.app.data.api.models.Subject as WireSubject
import com.cinemacore.app.domain.CatalogRepository
import com.cinemacore.app.domain.CinemacoreError
import com.cinemacore.app.domain.Page
import com.cinemacore.app.domain.PlayInfo
import com.cinemacore.app.domain.Season
import com.cinemacore.app.domain.Subject
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import retrofit2.Response
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

/**
 * The gateway client. All MovieBox traffic on Android goes through the Go
 * gateway; the direct iOS signing/session path is deliberately not ported.
 */
class GatewayCatalogRepository(
    baseUrl: String,
    okHttpClient: OkHttpClient,
) : CatalogRepository {
    private val normalizedBase = normalizeBaseUrl(baseUrl)
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        explicitNulls = false
        coerceInputValues = true
    }
    private val retrofit = Retrofit.Builder()
        .baseUrl(normalizedBase)
        .client(okHttpClient)
        .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
        .build()

    private val browse: BrowseApi = retrofit.create(BrowseApi::class.java)
    private val title: TitleApi = retrofit.create(TitleApi::class.java)
    private val system: SystemApi = retrofit.create(SystemApi::class.java)

    override val sourceName: String
        get() = runCatching { java.net.URI(normalizedBase).host }.getOrNull() ?: normalizedBase

    override val isLive: Boolean
        get() = true

    override suspend fun home(): Page = call { browse.home() }.let(ApiMappers::page)

    override suspend fun search(query: String): List<Subject> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        return call { browse.search(trimmed) }.items.map(ApiMappers::subject)
    }

    override suspend fun detail(id: String): Subject =
        call { title.detail(id) }.let(ApiMappers::subject)

    override suspend fun seasons(subjectId: String): List<Season> =
        call { title.seasons(subjectId) }.seasons.let(ApiMappers::seasons)

    override suspend fun play(
        subjectId: String,
        season: Int?,
        episode: Int?,
    ): PlayInfo = call { title.play(subjectId, season, episode) }.let(ApiMappers::playInfo)

    override suspend fun suggestions(query: String): List<String> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        return call { browse.searchSuggestions(trimmed) }.items
    }

    suspend fun version(): String = call { system.version() }.version

    private suspend fun <T> call(block: suspend () -> Response<T>): T {
        try {
            val response = block()
            if (!response.isSuccessful) throw errorFor(response)
            return response.body() ?: throw CinemacoreError.Decoding("Empty response body.")
        } catch (error: CinemacoreError) {
            throw error
        } catch (error: CancellationException) {
            throw error
        } catch (error: SocketTimeoutException) {
            throw CinemacoreError.TimedOut
        } catch (error: SerializationException) {
            throw CinemacoreError.Decoding(error.message)
        } catch (error: IOException) {
            throw CinemacoreError.Offline
        } catch (error: Exception) {
            throw CinemacoreError.Unknown(error.message)
        }
    }

    private fun errorFor(response: Response<*>): CinemacoreError {
        val raw = runCatching { response.errorBody()?.string() }.getOrNull()
        val body = raw?.let {
            runCatching { json.parseToJsonElement(it).jsonObject }.getOrNull()
        }
        val code = body?.get("code")?.jsonPrimitive?.contentOrNull
        val message = body?.get("message")?.jsonPrimitive?.contentOrNull
        return when (response.code()) {
            404 -> CinemacoreError.NotFound
            else -> CinemacoreError.Http(response.code(), code, message)
        }
    }

    companion object {
        fun normalizeBaseUrl(raw: String): String {
            val withScheme = raw.trim().ifEmpty { "http://10.0.2.2:8080" }
                .let { if (it.startsWith("http://") || it.startsWith("https://")) it else "http://$it" }
            return withScheme.trimEnd('/') + "/"
        }

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build()
    }
}

private val kotlinx.serialization.json.JsonPrimitive.contentOrNull: String?
    get() = runCatching { content }.getOrNull()
