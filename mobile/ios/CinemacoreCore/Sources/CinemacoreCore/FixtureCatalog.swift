import Foundation

/// The catalog the app ships with, so every screen is navigable before the
/// provider gateway is finished.
///
/// The data is a hand-curated slice of real catalogue metadata: 50 titles
/// (42 films, 8 series), seven home rails built from them, real season/episode
/// trees for the series, and a deterministic playback ladder per title. Lookups
/// are pure and total — only `playInfo` and `detail(id:)` fail, and only for an
/// id this catalog does not carry.
///
/// Every remote-looking value points at a host we control or at a reserved
/// domain: posters use seeded `picsum.photos` URLs (the one URL the demo path
/// really fetches) and playback uses `cdn.cinemacore.test`. `.test` is a
/// reserved TLD that cannot resolve, so the player — which is wired to these
/// URLs — fails at the network layer until the gateway serves real streams.
public struct FixtureCatalogRepository: CatalogRepository {
    public init() {}

    public var sourceName: String { "Bundled catalog" }
    public var isLive: Bool { false }

    public func home() async throws(CinemacoreError) -> Page {
        Page(sections: Self.sections)
    }

    public func search(_ query: String) async throws(CinemacoreError) -> [Subject] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return Self.allSubjects.filter { subject in
            subject.title.lowercased().contains(needle)
                || subject.genres.contains { $0.lowercased().contains(needle) }
        }
    }

    public func detail(id: String) async throws(CinemacoreError) -> Subject {
        guard let subject = Self.subjectsByID[id] else {
            throw .http(status: 404, code: "not_found", message: "Unknown title.")
        }
        return subject
    }

    public func seasons(subjectID: String) async throws(CinemacoreError) -> [Season] {
        Self.seasonsBySubjectID[subjectID] ?? []
    }

    public func playInfo(
        subjectID: String,
        season: Int?,
        episode: Int?
    ) async throws(CinemacoreError) -> PlayInfo {
        guard let subject = Self.subjectsByID[subjectID] else {
            throw .upstream("No playback source for this title.")
        }
        return Self.playback(for: subject)
    }

    public func suggestions(for query: String) async throws(CinemacoreError) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let matches = Self.allSubjects.filter { $0.title.lowercased().contains(needle) }
        // Prefix hits read as the stronger suggestion, so they lead.
        let ordered = matches.filter { $0.title.lowercased().hasPrefix(needle) }
            + matches.filter { !$0.title.lowercased().hasPrefix(needle) }
        var titles: [String] = []
        for subject in ordered where !titles.contains(subject.title) {
            titles.append(subject.title)
            if titles.count == 8 { break }
        }
        return titles
    }

    // MARK: - Titles

    // Films, oldest first within each era.

    private static let dune = movie(
        "Dune", 2021, 8.0,
        genres: ["Sci-Fi", "Adventure"],
        synopsis: "Paul Atreides is thrust into a war for the desert planet Arrakis, the only source of the spice that powers interstellar travel.",
        minutes: 155,
        dubs: ["English", "Hindi", "Tamil"]
    )

    private static let dunePartTwo = movie(
        "Dune: Part Two", 2024, 8.5,
        genres: ["Sci-Fi", "Adventure"],
        synopsis: "Paul Atreides unites with the Fremen to wage war on House Harkonnen and the emperor who betrayed his family.",
        minutes: 166,
        dubs: ["English", "Hindi", "Tamil"],
        cast: people(
            ("Timothée Chalamet", "Paul Atreides"),
            ("Zendaya", "Chani"),
            ("Rebecca Ferguson", "Lady Jessica")
        )
    )

    private static let oppenheimer = movie(
        "Oppenheimer", 2023, 8.3,
        genres: ["Biography", "Drama", "History"],
        synopsis: "J. Robert Oppenheimer leads the Manhattan Project and then spends the rest of his life reckoning with what it built.",
        minutes: 180,
        cast: people(
            ("Cillian Murphy", "J. Robert Oppenheimer"),
            ("Emily Blunt", "Kitty Oppenheimer"),
            ("Robert Downey Jr.", "Lewis Strauss")
        )
    )

    private static let theDarkKnight = movie(
        "The Dark Knight", 2008, 9.0,
        genres: ["Action", "Crime", "Drama"],
        synopsis: "Batman, Gordon and Harvey Dent take on the Joker, whose appetite for chaos pushes Gotham to the edge.",
        minutes: 152,
        cast: people(
            ("Christian Bale", "Bruce Wayne"),
            ("Heath Ledger", "The Joker"),
            ("Aaron Eckhart", "Harvey Dent")
        )
    )

    private static let theGodfather = movie(
        "The Godfather", 1972, 9.2,
        genres: ["Crime", "Drama"],
        synopsis: "The ageing patriarch of a New York crime family hands control to his reluctant youngest son.",
        minutes: 175,
        cast: people(
            ("Marlon Brando", "Vito Corleone"),
            ("Al Pacino", "Michael Corleone")
        )
    )

    private static let theShawshankRedemption = movie(
        "The Shawshank Redemption", 1994, 9.3,
        genres: ["Drama"],
        synopsis: "A banker sentenced to life for a murder he did not commit builds a quiet life, and a patient plan, inside Shawshank prison.",
        minutes: 142,
        cast: people(
            ("Tim Robbins", "Andy Dufresne"),
            ("Morgan Freeman", "Ellis 'Red' Redding")
        )
    )

    private static let pulpFiction = movie(
        "Pulp Fiction", 1994, 8.9,
        genres: ["Crime", "Drama"],
        synopsis: "Two hitmen, a boxer and a gangster's wife collide across a handful of Los Angeles stories told out of order.",
        minutes: 154,
        cast: people(
            ("John Travolta", "Vincent Vega"),
            ("Samuel L. Jackson", "Jules Winnfield"),
            ("Uma Thurman", "Mia Wallace")
        )
    )

    private static let inception = movie(
        "Inception", 2010, 8.8,
        genres: ["Action", "Sci-Fi", "Thriller"],
        synopsis: "A thief who steals secrets from dreams is hired to plant an idea in a rival's mind instead.",
        minutes: 148,
        cast: people(
            ("Leonardo DiCaprio", "Dom Cobb"),
            ("Joseph Gordon-Levitt", "Arthur"),
            ("Elliot Page", "Ariadne")
        )
    )

    private static let interstellar = movie(
        "Interstellar", 2014, 8.7,
        genres: ["Adventure", "Drama", "Sci-Fi"],
        synopsis: "With Earth dying, a former pilot flies through a wormhole to find humanity a new home.",
        minutes: 169,
        cast: people(
            ("Matthew McConaughey", "Cooper"),
            ("Anne Hathaway", "Brand")
        )
    )

    private static let theMatrix = movie(
        "The Matrix", 1999, 8.7,
        genres: ["Action", "Sci-Fi"],
        synopsis: "A hacker learns his world is a simulation and joins a rebellion against the machines that built it.",
        minutes: 136,
        cast: people(
            ("Keanu Reeves", "Neo"),
            ("Laurence Fishburne", "Morpheus"),
            ("Carrie-Anne Moss", "Trinity")
        )
    )

    private static let goodfellas = movie(
        "Goodfellas", 1990, 8.7,
        genres: ["Biography", "Crime", "Drama"],
        synopsis: "Henry Hill rises through the New York mob and watches the life he chose slowly turn on him.",
        minutes: 145
    )

    private static let se7en = movie(
        "Se7en", 1995, 8.6,
        genres: ["Crime", "Drama", "Mystery"],
        synopsis: "Two detectives hunt a killer who stages his murders around the seven deadly sins.",
        minutes: 127,
        cast: people(
            ("Brad Pitt", "Detective David Mills"),
            ("Morgan Freeman", "Detective William Somerset")
        )
    )

    private static let theSilenceOfTheLambs = movie(
        "The Silence of the Lambs", 1991, 8.6,
        genres: ["Crime", "Drama", "Thriller"],
        synopsis: "A young FBI trainee seeks the counsel of an imprisoned cannibal to catch another serial killer.",
        minutes: 118,
        cast: people(
            ("Jodie Foster", "Clarice Starling"),
            ("Anthony Hopkins", "Dr. Hannibal Lecter")
        )
    )

    private static let parasite = movie(
        "Parasite", 2019, 8.5,
        genres: ["Drama", "Thriller"],
        synopsis: "A poor Seoul family insinuates itself into the household of the wealthy Parks, with consequences nobody planned.",
        minutes: 132
    )

    private static let spiritedAway = movie(
        "Spirited Away", 2001, 8.6,
        genres: ["Animation", "Adventure", "Family"],
        synopsis: "A sullen ten-year-old wanders into a world of spirits and must work in a bathhouse to free her parents.",
        minutes: 125,
        dubs: ["English", "Japanese"]
    )

    private static let fellowshipOfTheRing = movie(
        "The Lord of the Rings: The Fellowship of the Ring", 2001, 8.9,
        genres: ["Adventure", "Fantasy"],
        synopsis: "A hobbit leaves the Shire with eight companions to destroy a ring that could doom Middle-earth.",
        minutes: 178,
        cast: people(
            ("Elijah Wood", "Frodo Baggins"),
            ("Ian McKellen", "Gandalf")
        )
    )

    private static let returnOfTheKing = movie(
        "The Lord of the Rings: The Return of the King", 2003, 9.0,
        genres: ["Adventure", "Fantasy"],
        synopsis: "Frodo and Sam reach Mordor while Aragorn leads the last free peoples against Sauron's army.",
        minutes: 201
    )

    private static let gladiator = movie(
        "Gladiator", 2000, 8.5,
        genres: ["Action", "Adventure", "Drama"],
        synopsis: "A betrayed Roman general fights his way back through the arena to avenge his murdered family.",
        minutes: 155,
        cast: people(
            ("Russell Crowe", "Maximus"),
            ("Joaquin Phoenix", "Commodus")
        )
    )

    private static let madMaxFuryRoad = movie(
        "Mad Max: Fury Road", 2015, 8.1,
        genres: ["Action", "Adventure", "Sci-Fi"],
        synopsis: "Max and Imperator Furiosa flee a warlord across the wasteland in one long, roaring chase.",
        minutes: 120,
        dubs: ["English", "Hindi", "Spanish"]
    )

    private static let bladeRunner2049 = movie(
        "Blade Runner 2049", 2017, 8.0,
        genres: ["Action", "Drama", "Sci-Fi"],
        synopsis: "A replicant blade runner uncovers a secret that could upend what is left of society.",
        minutes: 164,
        dubs: ["English", "Hindi", "Spanish"]
    )

    private static let arrival = movie(
        "Arrival", 2016, 7.9,
        genres: ["Drama", "Mystery", "Sci-Fi"],
        synopsis: "A linguist is recruited to talk to visitors whose language rewrites how she experiences time.",
        minutes: 116
    )

    private static let whiplash = movie(
        "Whiplash", 2014, 8.5,
        genres: ["Drama", "Music"],
        synopsis: "A jazz drummer pushes himself to breaking point under a conductor who believes cruelty makes greatness.",
        minutes: 106,
        cast: people(
            ("Miles Teller", "Andrew Neiman"),
            ("J.K. Simmons", "Terence Fletcher")
        )
    )

    private static let everythingEverywhereAllAtOnce = movie(
        "Everything Everywhere All at Once", 2022, 7.8,
        genres: ["Action", "Adventure", "Comedy"],
        synopsis: "A laundromat owner in the middle of an audit discovers she is the only one who can hold the multiverse together.",
        minutes: 139,
        dubs: ["English", "Hindi", "Tamil"]
    )

    private static let getOut = movie(
        "Get Out", 2017, 7.7,
        genres: ["Horror", "Mystery", "Thriller"],
        synopsis: "A Black photographer visits his white girlfriend's family estate and finds a horror beneath the politeness.",
        minutes: 104
    )

    private static let laLaLand = movie(
        "La La Land", 2016, 8.0,
        genres: ["Comedy", "Drama", "Musical"],
        synopsis: "A jazz pianist and an aspiring actress fall in love in Los Angeles while chasing careers that pull them apart.",
        minutes: 128
    )

    private static let toyStory = movie(
        "Toy Story", 1995, 8.3,
        genres: ["Animation", "Adventure", "Comedy"],
        synopsis: "A cowboy doll's world is upended when a flashy space ranger becomes his owner's new favourite toy.",
        minutes: 81,
        dubs: ["English", "Hindi", "Spanish"]
    )

    private static let wallE = movie(
        "WALL-E", 2008, 8.4,
        genres: ["Animation", "Adventure", "Family"],
        synopsis: "A lonely trash-compacting robot follows a sleek probe across the galaxy and stumbles into saving humanity.",
        minutes: 98
    )

    private static let theGrandBudapestHotel = movie(
        "The Grand Budapest Hotel", 2014, 8.1,
        genres: ["Adventure", "Comedy", "Crime"],
        synopsis: "A legendary concierge and his lobby boy chase a stolen painting and a disputed inheritance across a vanishing Europe.",
        minutes: 99
    )

    private static let twelveAngryMen = movie(
        "12 Angry Men", 1957, 9.0,
        genres: ["Crime", "Drama"],
        synopsis: "One juror's reasonable doubt slowly turns a murder trial around in a sweltering jury room.",
        minutes: 96
    )

    private static let psycho = movie(
        "Psycho", 1960, 8.5,
        genres: ["Horror", "Mystery", "Thriller"],
        synopsis: "A woman on the run checks into the Bates Motel and meets its proprietor and his domineering mother.",
        minutes: 109
    )

    private static let casablanca = movie(
        "Casablanca", 1942, 8.5,
        genres: ["Drama", "Romance", "War"],
        synopsis: "A cynical nightclub owner in wartime Morocco must choose between the woman he loves and the cause he abandoned.",
        minutes: 102
    )

    private static let alien = movie(
        "Alien", 1979, 8.5,
        genres: ["Horror", "Sci-Fi"],
        synopsis: "The crew of the Nostromo brings something aboard that hunts them one by one.",
        minutes: 117,
        dubs: ["English", "Hindi", "Spanish"]
    )

    private static let theThing = movie(
        "The Thing", 1982, 8.2,
        genres: ["Horror", "Mystery", "Sci-Fi"],
        synopsis: "An Antarctic research team realises the creature among them can wear any of their faces.",
        minutes: 109
    )

    private static let apocalypseNow = movie(
        "Apocalypse Now", 1979, 8.5,
        genres: ["Drama", "War"],
        synopsis: "A captain travels upriver in Vietnam to find a decorated colonel who has set himself up as a god.",
        minutes: 147
    )

    private static let heat = movie(
        "Heat", 1995, 8.3,
        genres: ["Action", "Crime", "Drama"],
        synopsis: "A master thief and the detective hunting him circle each other across Los Angeles.",
        minutes: 170,
        cast: people(
            ("Al Pacino", "Lt. Vincent Hanna"),
            ("Robert De Niro", "Neil McCauley")
        )
    )

    private static let theDeparted = movie(
        "The Departed", 2006, 8.5,
        genres: ["Crime", "Drama", "Thriller"],
        synopsis: "An undercover cop and a mole inside the police race to unmask each other in Boston.",
        minutes: 151
    )

    private static let noCountryForOldMen = movie(
        "No Country for Old Men", 2007, 8.2,
        genres: ["Crime", "Drama", "Thriller"],
        synopsis: "A hunter who takes a case of drug money is pursued across Texas by a killer with his own rules.",
        minutes: 122
    )

    private static let childrenOfMen = movie(
        "Children of Men", 2006, 7.9,
        genres: ["Action", "Drama", "Sci-Fi"],
        synopsis: "In a world where humanity has stopped reproducing, a bureaucrat escorts the only pregnant woman alive to safety.",
        minutes: 109
    )

    private static let topGunMaverick = movie(
        "Top Gun: Maverick", 2022, 8.2,
        genres: ["Action", "Drama"],
        synopsis: "Maverick returns to train a squad of graduates for a mission that mirrors the one that made him.",
        minutes: 130
    )

    private static let knivesOut = movie(
        "Knives Out", 2019, 7.9,
        genres: ["Comedy", "Crime", "Mystery"],
        synopsis: "A detective picks apart a wealthy family after the patriarch dies on the night of his birthday party.",
        minutes: 130,
        cast: people(
            ("Daniel Craig", "Benoit Blanc"),
            ("Ana de Armas", "Marta Cabrera")
        )
    )

    private static let intoTheSpiderVerse = movie(
        "Spider-Man: Into the Spider-Verse", 2018, 8.4,
        genres: ["Animation", "Action", "Adventure"],
        synopsis: "Miles Morales becomes Spider-Man just as heroes from other dimensions fall into his city.",
        minutes: 117,
        dubs: ["English", "Hindi", "Spanish"]
    )

    private static let backToTheFuture = movie(
        "Back to the Future", 1985, 8.5,
        genres: ["Adventure", "Comedy", "Sci-Fi"],
        synopsis: "A teenager is accidentally sent to 1955, where he must make sure his parents still fall in love.",
        minutes: 116
    )

    // MARK: - Series

    private static let theMandalorian = series(
        "The Mandalorian", 2019, 8.7,
        genres: ["Action", "Adventure", "Sci-Fi"],
        synopsis: "A bounty hunter travels the outer rim protecting a child who is far more than he appears.",
        seasons: 3,
        cast: people(
            ("Pedro Pascal", "Din Djarin"),
            ("Giancarlo Esposito", "Moff Gideon")
        )
    )

    private static let severance = series(
        "Severance", 2022, 8.7,
        genres: ["Drama", "Mystery", "Sci-Fi"],
        synopsis: "Lumon employees have their memories surgically split between work and home, until the two halves start asking questions.",
        seasons: 2,
        cast: people(
            ("Adam Scott", "Mark Scout"),
            ("Britt Lower", "Helly R.")
        )
    )

    private static let arcane = series(
        "Arcane", 2021, 9.0,
        genres: ["Animation", "Action", "Adventure"],
        synopsis: "Two sisters end up on opposite sides of the war between the gleaming city of Piltover and the undercity of Zaun.",
        seasons: 2,
        cast: people(
            ("Hailee Steinfeld", "Vi"),
            ("Ella Purnell", "Jinx")
        )
    )

    private static let dark = series(
        "Dark", 2017, 8.7,
        genres: ["Crime", "Drama", "Mystery"],
        synopsis: "A child's disappearance in a small German town exposes a time-travel conspiracy spanning generations.",
        seasons: 3,
        dubs: ["English", "Hindi", "German"]
    )

    private static let houseOfTheDragon = series(
        "House of the Dragon", 2022, 8.4,
        genres: ["Action", "Adventure", "Drama"],
        synopsis: "The Targaryen dynasty tears itself apart over the succession to the Iron Throne.",
        seasons: 2
    )

    private static let theQueensGambit = series(
        "The Queen's Gambit", 2020, 8.5,
        genres: ["Drama"],
        synopsis: "An orphaned chess prodigy rises through the tournaments of the Cold War while fighting her own addictions.",
        seasons: 1,
        cast: people(("Anya Taylor-Joy", "Beth Harmon"))
    )

    private static let shogun = series(
        "Shogun", 2024, 8.6,
        genres: ["Adventure", "Drama", "History"],
        synopsis: "An English pilot washes up in feudal Japan and is drawn into a lord's bid to rule the country.",
        seasons: 1,
        cast: people(
            ("Hiroyuki Sanada", "Lord Yoshii Toranaga"),
            ("Anna Sawai", "Toda Mariko")
        )
    )

    private static let bandOfBrothers = series(
        "Band of Brothers", 2001, 9.3,
        genres: ["Drama", "History", "War"],
        synopsis: "Easy Company of the 101st Airborne fights from the Normandy drop zones to the end of the war in Europe.",
        seasons: 1,
        cast: people(("Damian Lewis", "Major Richard Winters"))
    )

    // MARK: - Catalog

    /// Every bundled title, films then series.
    private static let allSubjects: [Subject] = [
        dune, dunePartTwo, oppenheimer, theDarkKnight, theGodfather, theShawshankRedemption,
        pulpFiction, inception, interstellar, theMatrix, goodfellas, se7en,
        theSilenceOfTheLambs, parasite, spiritedAway, fellowshipOfTheRing, returnOfTheKing, gladiator,
        madMaxFuryRoad, bladeRunner2049, arrival, whiplash, everythingEverywhereAllAtOnce, getOut,
        laLaLand, toyStory, wallE, theGrandBudapestHotel, twelveAngryMen, psycho,
        casablanca, alien, theThing, apocalypseNow, heat, theDeparted,
        noCountryForOldMen, childrenOfMen, topGunMaverick, knivesOut, intoTheSpiderVerse, backToTheFuture,
        theMandalorian, severance, arcane, dark, houseOfTheDragon, theQueensGambit,
        shogun, bandOfBrothers,
    ]

    private static let subjectsByID: [String: Subject] = Dictionary(
        allSubjects.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    /// Episode trees for every bundled series, keyed by subject id.
    private static let seasonsBySubjectID: [String: [Season]] = Dictionary(
        [
            tree(theMandalorian, minutes: 42, seasonTitles: [
                [
                    "Chapter 1: The Mandalorian", "Chapter 2: The Child", "Chapter 3: The Sin",
                    "Chapter 4: Sanctuary", "Chapter 5: The Gunslinger", "Chapter 6: The Prisoner",
                    "Chapter 7: The Reckoning", "Chapter 8: Redemption",
                ],
                [
                    "Chapter 9: The Marshal", "Chapter 10: The Passenger", "Chapter 11: The Heiress",
                    "Chapter 12: The Siege", "Chapter 13: The Jedi", "Chapter 14: The Tragedy",
                    "Chapter 15: The Believer", "Chapter 16: The Rescue",
                ],
                [
                    "Chapter 17: The Apostate", "Chapter 18: The Mines of Mandalore", "Chapter 19: The Convert",
                    "Chapter 20: The Foundling", "Chapter 21: The Pirate", "Chapter 22: Guns for Hire",
                    "Chapter 23: The Spies", "Chapter 24: The Return",
                ],
            ]),
            tree(severance, minutes: 48, seasonTitles: [
                [
                    "Good News About Hell", "Half Loop", "In Perpetuity", "The You You Are",
                    "The Grim Barbarity of Optics and Design", "Hide and Seek", "Defiant Jazz",
                    "What's for Dinner?", "The We We Are",
                ],
                [
                    "Hello, Ms. Cobel", "Goodbye, Mrs. Selvig", "Who Is Alive?", "Woe's Hollow",
                    "Trojan's Horse", "Attila", "Chikhai Bardo", "Sweet Vitriol",
                    "The After Hours", "Cold Harbor",
                ],
            ]),
            tree(arcane, minutes: 40, seasonTitles: [
                [
                    "Welcome to the Playground", "Some Mysteries Are Better Left Unsolved",
                    "The Base Violence Necessary for Change", "Happy Progress Day!",
                    "Everybody Wants to Be My Enemy", "When These Walls Come Tumbling Down",
                    "The Boy Savior", "Oil and Water", "The Monster You Created",
                ],
                [
                    "Heavy Is the Crown", "Watch It All Burn", "Finally Got the Name Right",
                    "Paint the Town Blue", "Blisters and Bedrock", "The Message Hidden Within the Pattern",
                    "Pretend Like It's the First Time", "Killing Is a Cycle", "The Dirt Under Your Nails",
                ],
            ]),
            tree(dark, minutes: 52, seasonTitles: [
                [
                    "Secrets", "Lies", "Past and Present", "Double Lives", "Truths",
                    "Sic Mundus Creatus Est", "Crossroads", "As You Sow, so You Shall Reap",
                    "Everything Is Now", "Alpha and Omega",
                ],
                [
                    "Beginnings and Endings", "Dark Matter", "Ghosts", "The Travelers",
                    "Lost and Found", "An Endless Cycle", "The White Devil", "Endings and Beginnings",
                ],
                [
                    "Deja-vu", "The Survivors", "Adam and Eva", "The Origin", "Life and Death",
                    "Light and Shadow", "Between the Time", "The Paradise",
                ],
            ]),
            tree(houseOfTheDragon, minutes: 58, seasonTitles: [
                [
                    "The Heirs of the Dragon", "The Rogue Prince", "Second of His Name",
                    "King of the Narrow Sea", "We Light the Way", "The Princess and the Queen",
                    "Driftmark", "The Lord of the Tides", "The Green Council", "The Black Queen",
                ],
                [
                    "A Son for a Son", "Rhaenyra the Cruel", "The Burning Mill",
                    "The Red Dragon and the Gold", "Regent", "Smallfolk",
                    "The Red Sowing", "The Queen Who Ever Was",
                ],
            ]),
            tree(theQueensGambit, minutes: 60, seasonTitles: [
                [
                    "Openings", "Exchanges", "Doubled Pawns", "Middle Game",
                    "Fork", "Adjournment", "Endgame",
                ],
            ]),
            tree(shogun, minutes: 58, seasonTitles: [
                [
                    "Anjin", "Servants of Two Masters", "Tomorrow Is Tomorrow", "The Eightfold Fence",
                    "Broken to the Fist", "Ladies of the Willow World", "A Stick of Time",
                    "The Abyss of Life", "Crimson Sky", "A Dream of a Dream",
                ],
            ]),
            tree(bandOfBrothers, minutes: 58, seasonTitles: [
                [
                    "Currahee", "Day of Days", "Carentan", "Replacements", "Crossroads",
                    "Bastogne", "The Breaking Point", "The Last Patrol", "Why We Fight", "Points",
                ],
            ]),
        ],
        uniquingKeysWith: { first, _ in first }
    )

    // MARK: - Rails

    /// The seven landing rails, ordered as the home screen shows them.
    private static let sections: [Section] = [
        Section(
            title: "Trending Now",
            items: [
                dunePartTwo, oppenheimer, topGunMaverick, knivesOut, theMandalorian, dune,
                everythingEverywhereAllAtOnce, severance, arcane, parasite, madMaxFuryRoad,
                theDarkKnight, houseOfTheDragon, toyStory,
            ]
        ),
        Section(
            title: "New Releases",
            items: [
                dunePartTwo, oppenheimer, everythingEverywhereAllAtOnce, topGunMaverick, severance,
                shogun, parasite, knivesOut, bladeRunner2049, getOut, arrival, laLaLand,
            ]
        ),
        Section(
            title: "Top Rated",
            items: [
                theShawshankRedemption, theGodfather, bandOfBrothers, theDarkKnight, returnOfTheKing,
                twelveAngryMen, arcane, pulpFiction, fellowshipOfTheRing, inception, interstellar,
                goodfellas, wallE, spiritedAway,
            ]
        ),
        Section(
            title: "Action & Adventure",
            items: [
                madMaxFuryRoad, gladiator, topGunMaverick, theDarkKnight, theMatrix, inception,
                bladeRunner2049, heat, childrenOfMen, intoTheSpiderVerse, returnOfTheKing, alien,
                theMandalorian, houseOfTheDragon,
            ]
        ),
        Section(
            title: "Sci-Fi & Fantasy",
            items: [
                dune, dunePartTwo, interstellar, inception, backToTheFuture, bladeRunner2049,
                arrival, alien, theThing, childrenOfMen, fellowshipOfTheRing, severance, dark, arcane,
            ]
        ),
        Section(
            title: "Critically Acclaimed",
            items: [
                theShawshankRedemption, theGodfather, twelveAngryMen, casablanca, psycho, se7en,
                whiplash, noCountryForOldMen, theDeparted, apocalypseNow, theSilenceOfTheLambs,
                bandOfBrothers, theQueensGambit, theGrandBudapestHotel,
            ]
        ),
        Section(
            title: "Because You Watched Dune",
            items: [
                dune, dunePartTwo, interstellar, bladeRunner2049, arrival, theMatrix, alien,
                fellowshipOfTheRing, childrenOfMen, theMandalorian, theThing, dark,
            ]
        ),
    ]

    // MARK: - Playback

    /// The bundled rendition ladder, with an approximate cost per minute so
    /// sizes scale with the runtime instead of being a single repeated literal.
    private static let streamLadder: [(quality: String, megabytesPerMinute: Double)] = [
        ("480p", 3.1),
        ("720p", 6.8),
        ("1080p", 14.2),
        ("4K", 42.0),
    ]

    /// Only genuinely high-rated titles carry a `4K` rendition, as the live
    /// ladder would.
    private static let ultraHDMinimumRating = 8.9

    /// A deterministic playback payload for one title: the ladder trimmed to
    /// its rating, plus bundled subtitle tracks.
    private static func playback(for subject: Subject) -> PlayInfo {
        let minutes = Double(subject.durationMinutes ?? 45)
        var streams: [StreamRendition] = []
        for rendition in streamLadder
        where rendition.quality != "4K" || (subject.rating ?? 0) >= ultraHDMinimumRating {
            streams.append(
                StreamRendition(
                    quality: rendition.quality,
                    url: "https://cdn.cinemacore.test/\(subject.id)/\(rendition.quality.lowercased()).m3u8",
                    size: sizeLabel(megabytes: rendition.megabytesPerMinute * minutes)
                )
            )
        }
        // English and Hindi ship on every title; Spanish follows the audio dubs.
        var subtitles = [
            subtitle("English", format: "vtt", for: subject),
            subtitle("Hindi", format: "srt", for: subject),
        ]
        if subject.dubs.contains("Spanish") {
            subtitles.append(subtitle("Spanish", format: "srt", for: subject))
        }
        return PlayInfo(streams: streams, subtitles: subtitles)
    }

    private static func subtitle(_ language: String, format: String, for subject: Subject) -> SubtitleTrack {
        SubtitleTrack(
            language: language,
            url: "https://cdn.cinemacore.test/\(subject.id)/subtitles/\(language.prefix(2).lowercased()).\(format)",
            format: format
        )
    }

    private static func sizeLabel(megabytes: Double) -> String {
        if megabytes >= 1024 {
            return String(format: "%.1f GB", megabytes / 1024)
        }
        return "\(Int(megabytes.rounded())) MB"
    }

    // MARK: - Builders

    /// Provider `Subject.kind` values.
    private enum SubjectKind {
        static let movie = "1"
        static let series = "2"
    }

    /// Builds a film with a slugged id and seeded poster.
    private static func movie(
        _ title: String,
        _ year: Int,
        _ rating: Double,
        genres: [String],
        synopsis: String,
        minutes: Int,
        dubs: [String] = ["English", "Hindi"],
        cast: [CastMember] = []
    ) -> Subject {
        let identifier = slug(title, year)
        return Subject(
            id: identifier,
            title: title,
            poster: posterURL(forSlug: identifier),
            year: year,
            rating: rating,
            kind: SubjectKind.movie,
            synopsis: synopsis,
            genres: genres,
            dubs: dubs,
            durationMinutes: minutes,
            seasonCount: 1,
            cast: cast
        )
    }

    /// Builds a series whose `seasonCount` matches the tree in
    /// `seasonsBySubjectID`.
    private static func series(
        _ title: String,
        _ year: Int,
        _ rating: Double,
        genres: [String],
        synopsis: String,
        seasons: Int,
        dubs: [String] = ["English", "Hindi"],
        cast: [CastMember] = []
    ) -> Subject {
        let identifier = slug(title, year)
        return Subject(
            id: identifier,
            title: title,
            poster: posterURL(forSlug: identifier),
            year: year,
            rating: rating,
            kind: SubjectKind.series,
            synopsis: synopsis,
            genres: genres,
            dubs: dubs,
            durationMinutes: nil,
            seasonCount: seasons,
            cast: cast
        )
    }

    /// Builds one series' `id → seasons` entry from per-season episode titles,
    /// numbering episodes in order and varying the runtime slightly.
    private static func tree(
        _ subject: Subject,
        minutes: Int,
        seasonTitles: [[String]]
    ) -> (String, [Season]) {
        let tree = seasonTitles.enumerated().map { seasonIndex, titles in
            Season(
                number: seasonIndex + 1,
                episodes: titles.enumerated().map { episodeIndex, title in
                    Episode(
                        subjectID: subject.id,
                        season: seasonIndex + 1,
                        number: episodeIndex + 1,
                        title: title,
                        duration: "\(minutes + (episodeIndex % 4) * 2)m",
                        still: "https://picsum.photos/seed/\(subject.id)-s\(seasonIndex + 1)e\(episodeIndex + 1)/320/180"
                    )
                }
            )
        }
        return (subject.id, tree)
    }

    /// Pairs of `(actor, role)` for the titles whose detail screen shows a cast.
    private static func people(_ entries: (String, String)...) -> [CastMember] {
        entries.map { CastMember(name: $0.0, role: $0.1) }
    }

    /// Lowercased, dash-separated `title-year`; the subject id and poster seed.
    private static func slug(_ title: String, _ year: Int) -> String {
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }
        return "\(words.joined(separator: "-"))-\(year)"
    }

    private static func posterURL(forSlug slug: String) -> String {
        "https://picsum.photos/seed/\(slug)/400/600"
    }
}
