package com.cinemacore.app.data.api.apis

import com.cinemacore.app.data.api.infrastructure.CollectionFormats.*
import retrofit2.http.*
import retrofit2.Response
import okhttp3.RequestBody
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

import com.cinemacore.app.data.api.models.Health200Response
import com.cinemacore.app.data.api.models.Version200Response

interface SystemApi {
    /**
     * GET health
     * Liveness probe
     * 
     * Responses:
     *  - 200: Service is up
     *
     * @return [Health200Response]
     */
    @GET("health")
    suspend fun health(): Response<Health200Response>

    /**
     * GET version
     * Build version
     * 
     * Responses:
     *  - 200: Build version
     *
     * @return [Version200Response]
     */
    @GET("version")
    suspend fun version(): Response<Version200Response>

}
