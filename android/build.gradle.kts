plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.compose.compiler) apply false
    alias(libs.plugins.ksp) apply false
    // Applied by :app only when google-services.json is present, so the repo
    // builds for anyone who clones it without Firebase credentials.
    alias(libs.plugins.google.services) apply false
}
