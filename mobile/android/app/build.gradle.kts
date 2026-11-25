plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.cinemacore.app"
    compileSdk = 37 // Compose 1.12 (BOM 2026.08.00) requires API 37; targetSdk stays at 36.

    defaultConfig {
        applicationId = "com.cinemacore.app"
        minSdk = 24
        targetSdk = 36
        // CI sets these from the tag in one shared step. Local builds stay on
        // the dev fallback; the app never hardcodes a release number.
        val appVersionName = System.getenv("APP_FULL_VERSION") ?: "0.0.0-dev"
        val appVersionCode = System.getenv("APP_BUILD_NUMBER")?.toIntOrNull() ?: 1
        val appCommit = System.getenv("APP_COMMIT") ?: "local"
        versionCode = appVersionCode
        versionName = appVersionName
        buildConfigField("String", "GIT_COMMIT", "\"$appCommit\"")

        buildConfigField("String", "DEFAULT_GATEWAY", "\"http://10.0.2.2:8080\"")
        buildConfigField(
            "String",
            "STREAMHYPE_PUBLIC_TMDB_KEY",
            "\"90b2cae8d7161e8ba0f3836240d7d352\"",
        )
        val tmdbEnvironmentKey = System.getenv("TMDB_API_KEY").orEmpty()
        buildConfigField(
            "String",
            "TMDB_ENV_KEY",
            "\"${tmdbEnvironmentKey.replace("\\", "\\\\").replace("\"", "\\\"")}\"",
        )
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += setOf(
            "/META-INF/{AL2.0,LGPL2.1}",
            "/META-INF/DEPENDENCIES",
        )
    }

    // No keystore ships in the repo. Release builds fall back to the debug key
    // so they stay installable; CI/local can supply a real key through env.
    signingConfigs {
        create("release") {
            val keystorePath = System.getenv("CINEMACORE_KEYSTORE")
            if (keystorePath != null) {
                storeFile = file(keystorePath)
                storePassword = System.getenv("CINEMACORE_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("CINEMACORE_KEY_ALIAS")
                keyPassword = System.getenv("CINEMACORE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (System.getenv("CINEMACORE_KEYSTORE") != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.viewmodel.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons)
    debugImplementation(libs.androidx.compose.ui.tooling)

    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)

    implementation(libs.okhttp)
    implementation(libs.okhttp.logging)
    implementation(libs.retrofit)
    implementation(libs.retrofit.kotlinx)
    implementation(libs.retrofit.scalars)

    implementation(libs.coil.compose)

    implementation(libs.media3.exoplayer)
    implementation(libs.media3.exoplayer.hls)
    implementation(libs.media3.exoplayer.dash)
    implementation(libs.media3.session)
    implementation(libs.media3.ui)
    implementation(libs.media3.datasource.okhttp)
    implementation(libs.androidx.webkit)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.kotlinx.serialization.json)
}
