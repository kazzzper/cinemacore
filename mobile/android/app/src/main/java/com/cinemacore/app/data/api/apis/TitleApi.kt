package com.cinemacore.app.data.api.apis

import com.cinemacore.app.data.api.infrastructure.CollectionFormats.*
import retrofit2.http.*
import retrofit2.Response
import okhttp3.RequestBody
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

import com.cinemacore.app.data.api.models.Error
import com.cinemacore.app.data.api.models.PlayInfo
import com.cinemacore.app.data.api.models.Seasons200Response
import com.cinemacore.app.data.api.models.Subject

interface TitleApi {
    /**
     * GET v1/detail/{id}
     * One title&#39;s details
     * 
     * Responses:
     *  - 200: One subject
     *  - 502: Provider call failed
     *
     * @param id 
     * @return [Subject]
     */
    @GET("v1/detail/{id}")
    suspend fun detail(@Path("id") id: kotlin.String): Response<Subject>

    /**
     * GET v1/play
     * Resolve playback sources
     * Resolved playback sources for one episode. A movie omits both season and episode, and the provider then answers with the movie stream.  When the upstream offers only its anti-piracy decoy and no recovery path yields a real manifest, this answers 502 with code &#x60;stream_unavailable&#x60; instead of returning the decoy as playable content. 
     * Responses:
     *  - 200: Streams and subtitle tracks for the requested subject
     *  - 400: Typed error envelope
     *  - 502: Provider call failed
     *
     * @param subjectId 
     * @param season  (optional)
     * @param episode  (optional)
     * @return [PlayInfo]
     */
    @GET("v1/play")
    suspend fun play(@Query("subjectId") subjectId: kotlin.String, @Query("season") season: kotlin.Int? = null, @Query("episode") episode: kotlin.Int? = null): Response<PlayInfo>

    /**
     * GET v1/detail/{id}/seasons
     * Season and episode tree
     * 
     * Responses:
     *  - 200: Season and episode tree for a series
     *  - 502: Provider call failed
     *
     * @param id 
     * @return [Seasons200Response]
     */
    @GET("v1/detail/{id}/seasons")
    suspend fun seasons(@Path("id") id: kotlin.String): Response<Seasons200Response>

}
