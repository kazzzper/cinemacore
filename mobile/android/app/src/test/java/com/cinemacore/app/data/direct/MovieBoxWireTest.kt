package com.cinemacore.app.data.direct

import com.cinemacore.app.domain.Subject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MovieBoxWireTest {
    private fun subject(raw: String): Subject? =
        MovieBoxWire.subject(Json.parseToJsonElement(raw).jsonObject)

    private fun requiredSubject(raw: String): Subject {
        val parsed = subject(raw)
        return requireNotNull(parsed) { "expected a subject from $raw" }
    }

    // MARK: - Subject

    @Test
    fun `maps a full subject and every optional block`() {
        val subject = requiredSubject(
            """
            {
              "subjectId":"42","subjectType":2,"title":"Dune","description":"Spice.",
              "releaseDate":"2021-10-22","duration":"1h 33m",
              "genre":"Sci-Fi, Adventure, , Drama","cover":{"url":"//pbcdn.example/p.jpg"},
              "imdbRatingValue":" 8.0 ","seNum":2,
              "staffList":[
                {"name":"Denis Villeneuve","character":"Director","avatarUrl":"https://img.example/a.jpg"},
                {"name":"","character":"Ignored"}
              ],
              "dubs":[
                {"lanCode":"en","lanName":"English","original":true,"subjectId":"99"},
                {"lanCode":"hi","lanName":"Hindi"},
                {"lanName":""}
              ],
              "resourceDetectors":[
                {"resourceId":"r1","source":"example.cdn"},
                {"resourceId":"","source":"ignored"}
              ]
            }
            """.trimIndent(),
        )

        assertEquals("42", subject.id)
        assertEquals("Dune", subject.title)
        assertEquals("https://pbcdn.example/p.jpg", subject.poster)
        assertEquals(2021, subject.year)
        assertEquals(8.0, subject.rating ?: Double.NaN, 0.0)
        assertEquals("series", subject.kind)
        assertEquals("Spice.", subject.synopsis)
        assertEquals(listOf("Sci-Fi", "Adventure", "Drama"), subject.genres)
        assertEquals(listOf("English", "Hindi"), subject.dubs)
        assertEquals(1, subject.dubOptions.size)
        assertEquals("99", subject.dubOptions[0].subjectId)
        assertEquals("en", subject.dubOptions[0].languageCode)
        assertTrue(subject.dubOptions[0].isOriginal)
        assertEquals(93, subject.durationMinutes)
        assertEquals(2, subject.seasonCount)
        assertEquals(1, subject.cast.size)
        assertEquals("Director", subject.cast[0].role)
        assertEquals("https://img.example/a.jpg", subject.cast[0].avatar)
        assertEquals(1, subject.resourceDetectors.size)
        assertEquals("example.cdn", subject.resourceDetectors[0].name)
    }

    @Test
    fun `falls back to name and defaults a missing season count to one`() {
        val subject = requiredSubject("""{"subjectId":"n","name":"Named","subjectType":1,"seconds":6000}""")

        assertEquals("Named", subject.title)
        assertEquals("movie", subject.kind)
        assertEquals(100, subject.durationMinutes)
        assertEquals(1, subject.seasonCount)
        assertNull(subject.rating)
        assertNull(subject.poster)
        assertNull(subject.synopsis)
    }

    @Test
    fun `accepts string covers and the layout rating field`() {
        val subject = requiredSubject(
            """{"subjectId":"alt","cover":"//cdn.example/p.jpg","imdbRate":"7.25"}""",
        )

        assertEquals("https://cdn.example/p.jpg", subject.poster)
        assertEquals(7.25, subject.rating ?: Double.NaN, 0.0)
        assertNull(subject.kind)
    }

    @Test
    fun `skips malformed nested subject blocks without losing the subject`() {
        val subject = requiredSubject(
            """
            {
              "subjectId":"tolerant","subjectType":"nonsense","cover":{},
              "releaseDate":"abcd-01-01","durationSeconds":-1,"seconds":-2,"duration":"45m",
              "seasonCount":3,"seNum":2,
              "dubs":[
                "bad",
                {"lanName":""},
                {"lanName":"French","subjectId":"d2"}
              ],
              "staffList":[
                "bad",
                {"name":"","character":"Ignored"},
                {"name":"Actor"}
              ],
              "resourceDetectors":[
                "bad",
                {"resourceId":"","source":"Ignored"},
                {"resourceId":"r1"}
              ]
            }
            """.trimIndent(),
        )

        assertEquals("tolerant", subject.id)
        assertNull(subject.poster)
        assertNull(subject.year)
        assertNull(subject.kind)
        assertEquals(45, subject.durationMinutes)
        assertEquals(3, subject.seasonCount)
        assertEquals(listOf("French"), subject.dubs)
        assertEquals(1, subject.dubOptions.size)
        assertFalse(subject.dubOptions[0].isOriginal)
        assertEquals(1, subject.cast.size)
        assertEquals("", subject.cast[0].role)
        assertNull(subject.cast[0].avatar)
        assertEquals(1, subject.resourceDetectors.size)
        assertEquals("Resource", subject.resourceDetectors[0].name)
    }

    @Test
    fun `maps helper edge cases`() {
        assertNull(MovieBoxWire.httpsURL(null))
        assertNull(MovieBoxWire.httpsURL(""))
        assertEquals("https://cdn.example/p.jpg", MovieBoxWire.httpsURL("//cdn.example/p.jpg"))
        assertEquals("http://cdn.example/p.jpg", MovieBoxWire.httpsURL("http://cdn.example/p.jpg"))

        assertNull(MovieBoxWire.year(null))
        assertNull(MovieBoxWire.year("bad"))
        assertNull(MovieBoxWire.year("abcd-01-01"))
        assertEquals(2024, MovieBoxWire.year("2024-01-01"))

        assertTrue(MovieBoxWire.splitList(null).isEmpty())
        assertTrue(MovieBoxWire.splitList(" , ").isEmpty())
        assertEquals(listOf("One", "Two"), MovieBoxWire.splitList(" One, , Two "))
    }

    @Test
    fun `maps subject types and honours an explicit kind`() {
        assertEquals("movie", requiredSubject("""{"subjectId":"a","subjectType":1}""").kind)
        assertEquals("series", requiredSubject("""{"subjectId":"b","subjectType":2}""").kind)
        assertEquals("game", requiredSubject("""{"subjectId":"c","subjectType":10}""").kind)
        assertNull(requiredSubject("""{"subjectId":"d","subjectType":9}""").kind)
        assertEquals(
            "movie",
            requiredSubject("""{"subjectId":"e","subjectType":2,"kind":"movie"}""").kind,
        )
    }

    @Test
    fun `rejects a subject without an id`() {
        assertNull(subject("""{"title":"No id"}"""))
        assertNull(subject("""{"subjectId":""}"""))
    }

    @Test
    fun `leaves absolute posters alone`() {
        val subject = requiredSubject("""{"subjectId":"p","cover":{"url":"https://cdn.example/p.jpg"}}""")
        assertEquals("https://cdn.example/p.jpg", subject.poster)
    }

    @Test
    fun `prefers exact seconds over the human duration`() {
        val exact = requiredSubject(
            """{"subjectId":"d","durationSeconds":9300,"duration":"1h"}""",
        )
        assertEquals(155, exact.durationMinutes)

        val fromLayout = requiredSubject("""{"subjectId":"e","seconds":5580}""")
        assertEquals(93, fromLayout.durationMinutes)
    }

    @Test
    fun `parses human durations`() {
        assertEquals(93, MovieBoxWire.durationMinutes(0, "1h 33m"))
        assertEquals(120, MovieBoxWire.durationMinutes(0, "2h"))
        assertEquals(45, MovieBoxWire.durationMinutes(0, "45m"))
        assertEquals(128, MovieBoxWire.durationMinutes(0, "2 hr 8 min"))
        assertEquals(0, MovieBoxWire.durationMinutes(0, null))
        assertEquals(0, MovieBoxWire.durationMinutes(0, "not a duration"))
        assertEquals(155, MovieBoxWire.durationMinutes(9300, null))
    }

    // MARK: - Home

    @Test
    fun `maps every row container in upstream order`() {
        val page = MovieBoxWire.homePage(
            """
            {
              "code":0,
              "data":{"items":[
                {"title":"Trending Movies","rankingListData":{"items":[
                  {"title":"TOP Movies","subjects":[
                    {"subjectId":"rank1","subjectType":1,"title":"Ranked","seconds":9000,
                     "imdbRatingValue":"8.1","cover":{"url":"//cdn.example/r.jpg"}},
                    {"subject":{"subjectId":"rank2","title":"Ranked Two","subjectType":2}}
                  ]}
                ]}},
                {"name":"Banner Rail","banner":{"banners":[
                  {"subject":{"subjectId":"banner1","title":"Banner","subjectType":1}}
                ]}},
                {"title":"Custom","customData":{"items":[
                  {"subject":{"subjectId":"card1","title":"Card","subjectType":2}},
                  "malformed",
                  {"subjectId":"no-type","title":"No Type"}
                ]}},
                {"title":"Mixed","list":[{"subjectId":"l1","title":"L1"}],
                 "items":[{"subject":{"subjectId":"l2","title":"L2"}}],
                 "subjects":[{"subjectId":"l3","title":"L3"}],
                 "movieList":[{"subjectId":"l4","title":"L4"}]},
                {"title":"Posts","postData":{"items":[{"subjectId":"post1"}]},
                 "playListData":{"items":[{"subjectId":"play1"}]},
                 "liveList":[{"subjectId":"live1"}]},
                "not a row",
                {"items":[]}
              ]}
            }
            """.trimIndent(),
        )

        assertEquals(4, page.sections.size)
        assertEquals(
            listOf("Trending Movies", "Banner Rail", "Custom", "Mixed"),
            page.sections.map { it.title },
        )

        val ranked = page.sections[0].items
        assertEquals(listOf("rank1", "rank2"), ranked.map { it.id })
        assertEquals(150, ranked[0].durationMinutes)
        assertEquals("https://cdn.example/r.jpg", ranked[0].poster)
        assertEquals(8.1, ranked[0].rating ?: Double.NaN, 0.0)

        assertEquals(listOf("banner1"), page.sections[1].items.map { it.id })
        assertEquals(listOf("card1", "no-type"), page.sections[2].items.map { it.id })
        assertEquals(listOf("l1", "l2", "l3", "l4"), page.sections[3].items.map { it.id })
    }

    @Test
    fun `maps the reshaped list envelope`() {
        val page = MovieBoxWire.homePage(
            """
            {"data":{"list":[
              {"title":"List Rail","list":[{"subject":{"subjectId":"s1","title":"One"}}]}
            ]}}
            """.trimIndent(),
        )

        assertEquals(1, page.sections.size)
        assertEquals("List Rail", page.sections[0].title)
        assertEquals("s1", page.sections[0].items.single().id)
    }

    @Test
    fun `turns a direct subject feed into one top picks rail`() {
        val page = MovieBoxWire.homePage(
            """
            {"data":{"items":[
              {"subjectId":"s1","subjectType":1,"title":"One"},
              {"subjectId":"s2","subjectType":2,"title":"Two"}
            ]}}
            """.trimIndent(),
        )

        assertEquals(1, page.sections.size)
        assertEquals("Top Picks", page.sections[0].title)
        assertEquals(listOf("s1", "s2"), page.sections[0].items.map { it.id })
    }

    @Test
    fun `turns a bare subject array into one top picks rail`() {
        val page = MovieBoxWire.homePage(
            """
            {"data":[
              {"subjectId":"s1","subjectType":1,"title":"One"},
              "bad",
              {"subjectId":"s2","subjectType":2,"title":"Two"}
            ]}
            """.trimIndent(),
        )

        assertEquals(1, page.sections.size)
        assertEquals("Top Picks", page.sections[0].title)
        assertEquals(listOf("s1", "s2"), page.sections[0].items.map { it.id })
    }

    @Test
    fun `keeps direct ranking entries when no nested subject list exists`() {
        val page = MovieBoxWire.homePage(
            """
            {"data":{"items":[
              {"title":"Ranked","rankingListData":{"items":[
                {"subjectId":"r1","title":"Direct","subjectType":1},
                {"subject":{"subjectId":"r2","title":"Wrapped","subjectType":2}}
              ]}}
            ]}}
            """.trimIndent(),
        )

        assertEquals(1, page.sections.size)
        assertEquals(listOf("r1", "r2"), page.sections[0].items.map { it.id })
    }

    @Test
    fun `accepts array containers and skips malformed direct-list entries`() {
        val page = MovieBoxWire.homePage(
            """
            {"data":{"items":[
              {"title":"Array Custom","customData":[{"subjectId":"c1","title":"Card"}]},
              {"title":"Array Rank","rankingListData":[
                {"subjects":[{"subjectId":"r1","title":"Ranked"}]},
                "bad"
              ]},
              {"title":"Directs","list":["bad",{"subjectId":"d1","title":"Direct"}]}
            ]}}
            """.trimIndent(),
        )

        assertEquals(listOf("Array Custom", "Array Rank", "Directs"), page.sections.map { it.title })
        assertEquals(listOf("c1"), page.sections[0].items.map { it.id })
        assertEquals(listOf("r1"), page.sections[1].items.map { it.id })
        assertEquals(listOf("d1"), page.sections[2].items.map { it.id })
    }

    @Test
    fun `returns an empty page when the data payload is not an object or has no subject`() {
        assertTrue(MovieBoxWire.homePage("""{"data":"nope"}""").isEmpty)
        assertTrue(MovieBoxWire.homePage("""{"data":{}}""").isEmpty)
        assertTrue(MovieBoxWire.homePage("""{"data":null}""").isEmpty)
    }

    @Test
    fun `maps a single subject payload`() {
        val page = MovieBoxWire.homePage("""{"data":{"subjectId":"only","title":"Only"}}""")

        assertEquals(1, page.sections.size)
        assertEquals("Only", page.sections[0].title)
        assertEquals("only", page.sections[0].items.single().id)
    }

    @Test
    fun `returns an empty page for malformed home payloads`() {
        assertTrue(MovieBoxWire.homePage("not json").isEmpty)
        assertTrue(MovieBoxWire.homePage("""{"data":[]}""").isEmpty)
        assertTrue(MovieBoxWire.homePage("""{"data":{"items":["bad"]}}""").isEmpty)
    }

    // MARK: - Search and detail

    @Test
    fun `maps search items and tolerates bad entries`() {
        val items = MovieBoxWire.searchItems(
            """
            {"data":{"items":[
              {"subjectId":"s1","title":"Dune"},
              {"subject":{"subjectId":"s2","title":"Wrapped"}},
              "bad",
              null,
              {"title":"No id"}
            ]}}
            """.trimIndent(),
        )

        assertEquals(listOf("s1", "s2"), items.map { it.id })
    }

    @Test
    fun `accepts a bare array of search subjects`() {
        val items = MovieBoxWire.searchItems(
            """{"data":[{"subjectId":"s1"},{"subject":{"subjectId":"s2"}},"bad"]}""",
        )

        assertEquals(listOf("s1", "s2"), items.map { it.id })
    }

    @Test
    fun `falls back to a direct search subject and ignores a non-object payload`() {
        assertEquals(
            listOf("s1"),
            MovieBoxWire.searchItems("""{"data":{"subjectId":"s1"}}""").map { it.id },
        )
        assertTrue(MovieBoxWire.searchItems("""{"data":"nope"}""").isEmpty())
    }

    @Test
    fun `maps a detail subject object or wrapper`() {
        val direct = MovieBoxWire.detailSubject("""{"data":{"subjectId":"d1","title":"Direct"}}""")
        assertEquals("d1", direct?.id)

        val wrapped = MovieBoxWire.detailSubject(
            """{"data":{"subject":{"subjectId":"d2","title":"Wrapped"}}}""",
        )
        assertEquals("d2", wrapped?.id)

        assertNull(MovieBoxWire.detailSubject("""{"data":"nope"}"""))
        assertNull(MovieBoxWire.detailSubject("not json"))
    }

    // MARK: - Seasons

    @Test
    fun `parses seasons with gaps and max episode fallback`() {
        val seasons = MovieBoxWire.seasons(
            """
            {"data":{"seasons":[
              {"se":1,"maxEp":3,"allEp":""},
              {"se":2,"maxEp":5,"allEp":"1,3, 5"},
              {"se":3,"maxEp":2,"allEp":"bogus"},
              {"se":4},
              {"maxEp":2,"allEp":"1"}
            ]}}
            """.trimIndent(),
        )

        assertEquals(listOf(1, 2, 3, 4), seasons.map { it.number })
        assertEquals(listOf(1, 2, 3), seasons[0].episodes.map { it.number })
        assertEquals(listOf(1, 3, 5), seasons[1].episodes.map { it.number })
        assertEquals(listOf(1, 2), seasons[2].episodes.map { it.number })
        assertTrue(seasons[3].episodes.isEmpty())
        assertEquals(2, seasons[1].episodes[0].season)
        assertEquals("", seasons[1].episodes[0].subjectId)
    }

    @Test
    fun `accepts a bare array of seasons`() {
        val seasons = MovieBoxWire.seasons("""{"data":[{"se":1,"maxEp":2}]}""")

        assertEquals(listOf(1, 2), seasons.single().episodes.map { it.number })
    }

    // MARK: - Playback

    @Test
    fun `maps streams and keeps all playback fields`() {
        val streams = MovieBoxWire.playStreams(
            """
            {"data":{"streams":[
              {"url":"https://cdn.example/x.m3u8","resolutions":"1080,720","size":"42",
               "signCookie":"c=1","format":"MP4","codecName":"hevc","unknown":"ignored"},
              "bad",
              null,
              {"url":"https://cdn.example/audio.m4a","format":"M4A","codecName":"aac"}
            ]}}
            """.trimIndent(),
        )

        assertEquals(2, streams.size)
        assertEquals("https://cdn.example/x.m3u8", streams[0].url)
        assertEquals("1080,720", streams[0].resolutions)
        assertEquals("42", streams[0].size)
        assertEquals("c=1", streams[0].signCookie)
        assertEquals("MP4", streams[0].format)
        assertEquals("hevc", streams[0].codecName)
        assertEquals("M4A", streams[1].format)
        assertNull(streams[1].signCookie)
        assertTrue(MovieBoxWire.playStreams("not json").isEmpty())
    }

    @Test
    fun `drops one malformed caption without failing the list`() {
        val captions = MovieBoxWire.captions(
            """
            {"data":{"extCaptions":[
              {"lan":"en","lanName":"English","url":"https://cdn.example/en.srt"},
              {"lan":"fr","url":"https://cdn.example/fr.vtt"},
              "malformed",
              null,
              {"lan":"de","lanName":"Deutsch","url":"https://cdn.example/de.srt"}
            ]}}
            """.trimIndent(),
        )

        assertEquals(3, captions.size)
        assertEquals("en", captions[0].lan)
        assertEquals("English", captions[0].lanName)
        assertEquals("https://cdn.example/en.srt", captions[0].url)
        assertNull(captions[1].lanName)
        assertEquals("https://cdn.example/fr.vtt", captions[1].url)
        assertEquals("Deutsch", captions[2].lanName)
    }

    @Test
    fun `accepts a bare array of captions`() {
        val captions = MovieBoxWire.captions("""{"data":[{"url":"https://cdn.example/en.srt"},"bad"]}""")

        assertEquals("https://cdn.example/en.srt", captions.single().url)
    }

    @Test
    fun `maps suggestion words`() {
        val words = MovieBoxWire.suggestions(
            """
            {"data":{"items":[
              {"word":"Dune"},{"word":"Dune: Part Two"},{"word":""},
              "bad",{"other":"ignored"}
            ]}}
            """.trimIndent(),
        )

        assertEquals(listOf("Dune", "Dune: Part Two"), words)
    }

    @Test
    fun `accepts a bare array of suggestions`() {
        val words = MovieBoxWire.suggestions("""{"data":[{"word":"One"},"bad",{"word":{}}]}""")

        assertEquals(listOf("One"), words)
    }

    // MARK: - UGC

    @Test
    fun `maps the UGC first response`() {
        val first = MovieBoxWire.ugcFirst(
            """
            {"data":{"ugcVideoId":"v1","belongToCollection":{"collectionId":"c1"}}}
            """.trimIndent(),
        )

        assertEquals("v1", first?.ugcVideoId)
        assertEquals("c1", first?.collectionId)

        val standalone = MovieBoxWire.ugcFirst("""{"data":{"ugcVideoId":"v2","belongToCollection":null}}""")
        assertEquals("v2", standalone?.ugcVideoId)
        assertNull(standalone?.collectionId)
        assertNull(MovieBoxWire.ugcFirst("not json"))
        assertNull(MovieBoxWire.ugcFirst("""{"data":"nope"}"""))
    }

    @Test
    fun `flattens UGC download resources and preserves collection markers`() {
        val json = """
            {"data":{"items":[
              {"epTitle":"S1EP1","title":"Dune S1E1","resources":[
                {"url":"https://cdn.example/ep1.mp4","resolutions":"1080","size":"1000",
                 "duration":5751,"signCookie":"c=1","codecName":"h264"},
                "bad"
              ]},
              {"title":"Special","resources":[]},
              "bad"
            ]}}
        """.trimIndent()

        val resources = MovieBoxWire.ugcDownloadResources(json)
        assertEquals(1, resources.size)
        assertEquals("https://cdn.example/ep1.mp4", resources[0].url)
        assertEquals("1080", resources[0].resolutions)
        assertEquals("1000", resources[0].size)
        assertEquals(5751, resources[0].duration)
        assertEquals("c=1", resources[0].signCookie)
        assertEquals("h264", resources[0].codecName)

        val items = MovieBoxWire.ugcCollectionItems(json)
        assertEquals(2, items.size)
        assertEquals("S1EP1", items[0].epTitle)
        assertEquals("Dune S1E1", items[0].title)
        assertEquals(1, items[0].resources.size)
        assertNull(items[1].epTitle)
        assertEquals("Special", items[1].title)
        assertTrue(items[1].resources.isEmpty())
    }

    // MARK: - Resource listing

    @Test
    fun `maps the resource listing and pager`() {
        val (list, hasMore) = MovieBoxWire.resources(
            """
            {"data":{"pager":{"hasMore":true},"list":[
              {"se":1,"ep":2,"duration":5916,"resolution":720,"size":"1200",
               "resourceLink":"https://cdn.example/ep2.mp4","resourceId":"r2","codecName":"h264"},
              "bad"
            ]}}
            """.trimIndent(),
        )

        assertTrue(hasMore)
        assertEquals(1, list.size)
        assertEquals(1, list[0].se)
        assertEquals(2, list[0].ep)
        assertEquals(5916, list[0].duration)
        assertEquals(720, list[0].resolution)
        assertEquals("1200", list[0].size)
        assertEquals("https://cdn.example/ep2.mp4", list[0].resourceLink)
        assertEquals("r2", list[0].resourceId)
        assertEquals("h264", list[0].codecName)
    }

    @Test
    fun `defaults a missing pager to no more pages`() {
        val (list, hasMore) = MovieBoxWire.resources(
            """{"data":{"list":[{"se":1,"ep":1,"resourceLink":"https://cdn.example/ep1.mp4"}]}}""",
        )

        assertFalse(hasMore)
        assertEquals(1, list.size)
        assertEquals(0, list[0].duration)
        assertEquals(0, list[0].resolution)
        assertEquals("", list[0].resourceId)
        assertNull(list[0].codecName)
    }

    @Test
    fun `accepts a bare array of resources`() {
        val (list, hasMore) = MovieBoxWire.resources("""{"data":[{"se":1,"ep":2}]}""")

        assertFalse(hasMore)
        assertEquals(2, list.single().ep)
    }

    @Test
    fun `reads a false or unknown pager value as no more pages`() {
        val (_, explicitFalse) = MovieBoxWire.resources(
            """{"data":{"pager":{"hasMore":false},"list":[]}}""",
        )
        assertFalse(explicitFalse)

        val (_, unknown) = MovieBoxWire.resources(
            """{"data":{"pager":{"hasMore":"maybe"},"list":[]}}""",
        )
        assertFalse(unknown)

        val (missing, _) = MovieBoxWire.resources("not json")
        assertTrue(missing.isEmpty())
    }

    // MARK: - Session tokens

    @Test
    fun `reads the visitor token`() {
        assertEquals("guest-token", MovieBoxWire.token("""{"code":0,"data":{"token":"guest-token"}}"""))
        assertEquals("root-token", MovieBoxWire.token("""{"token":"root-token"}"""))
        assertEquals("bare-token", MovieBoxWire.token("""{"data":"bare-token"}"""))
        assertNull(MovieBoxWire.token("""{"data":{"token":""}}"""))
        assertNull(MovieBoxWire.token("not json"))
    }

    @Test
    fun `accepts plain and JSON x-user values`() {
        assertEquals("guest-token", MovieBoxWire.xUserToken("""{"token":"guest-token"}"""))
        assertEquals("guest-token", MovieBoxWire.xUserToken("  guest-token  "))
        assertNull(MovieBoxWire.xUserToken(""))
        assertNull(MovieBoxWire.xUserToken("   "))
        assertNull(MovieBoxWire.xUserToken("{"))
        assertNull(MovieBoxWire.xUserToken("""{"user":{}}"""))
    }
}
