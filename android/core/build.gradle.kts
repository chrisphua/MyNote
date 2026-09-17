import java.time.Duration

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

// Plain JVM, not an Android library: the sync engine has no Android dependency,
// so its tests run in milliseconds on the JVM instead of needing an emulator.
kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(libs.kotlinx.coroutines.core)
    api(libs.kotlinx.serialization.json)
    // OkHttp is pure JVM, so the HTTP client lives here with the sync engine
    // instead of being duplicated in the Android module. `api` because
    // ApiClient's constructor exposes OkHttpClient to callers.
    api(libs.okhttp)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}

tasks.test {
    useJUnit()
    // A hang in ordering logic should fail the build, not stall CI.
    timeout.set(Duration.ofMinutes(5))
}
