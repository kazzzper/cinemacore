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
        versionCode = 1
        versionName = "0.1.0"

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

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.kotlinx.serialization.json)
}
