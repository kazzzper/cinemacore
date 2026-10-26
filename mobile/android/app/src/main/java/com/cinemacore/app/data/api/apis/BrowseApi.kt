package com.cinemacore.app.data.api.apis

import com.cinemacore.app.data.api.infrastructure.CollectionFormats.*
import retrofit2.http.*
import retrofit2.Response
import okhttp3.RequestBody
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

import com.cinemacore.app.data.api.models.Error
import com.cinemacore.app.data.api.models.Page
import com.cinemacore.app.data.api.models.Search200Response
import com.cinemacore.app.data.api.models.SearchSuggestions200Response

interface BrowseApi {
    /**
     * GET v1/home
     * Landing rails
     * 
     * Responses:
     *  - 200: Landing sections
     *  - 502: Provider call failed
     *
     * @return [Page]
     */
    @GET("v1/home")
    suspend fun home(): Response<Page>

    /**
     * GET v1/search
     * Search titles
     * 
     * Responses:
     *  - 200: Matching subjects
     *  - 400: Typed error envelope
     *  - 502: Provider call failed
     *
     * @param q 
     * @return [Search200Response]
     */
    @GET("v1/search")
    suspend fun search(@Query("q") q: kotlin.String): Response<Search200Response>

    /**
     * GET v1/search/suggestions
     * Type-ahead suggestions
     * 
     * Responses:
     *  - 200: Type-ahead terms for the query
     *  - 400: Typed error envelope
     *  - 502: Provider call failed
     *
     * @param q 
     * @return [SearchSuggestions200Response]
     */
    @GET("v1/search/suggestions")
    suspend fun searchSuggestions(@Query("q") q: kotlin.String): Response<SearchSuggestions200Response>

}
