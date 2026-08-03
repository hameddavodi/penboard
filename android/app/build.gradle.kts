import com.ncorti.ktfmt.gradle.tasks.KtfmtCheckTask
import java.util.Properties

plugins {
    // AGP 9's built-in Kotlin support compiles Kotlin sources without a
    // separate Kotlin plugin (kotl.in/gradle/agp-built-in-kotlin); applying
    // org.jetbrains.kotlin.android alongside it is a hard error.
    alias(libs.plugins.android.application)
    alias(libs.plugins.ktfmt)
}

// Release signing: loaded from android/keystore.properties, which is
// gitignored and never committed (OSS pattern -- see keystore.properties.template).
// Contributors without that file still get a working `assembleRelease`: it
// falls back to the debug signing config below, with a build-time warning.
val keystorePropertiesFile = rootProject.file("keystore.properties")
val hasKeystoreProperties = keystorePropertiesFile.exists()
val keystoreProperties =
    Properties().apply { if (hasKeystoreProperties) load(keystorePropertiesFile.inputStream()) }

android {
    namespace = "it.aisma.penboard"
    compileSdk = 36
    buildToolsVersion = "36.0.0"

    defaultConfig {
        applicationId = "it.aisma.penboard"
        minSdk = 29
        targetSdk = 36
        versionCode = 3
        versionName = "1.1.1"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // Built-in Kotlin's jvmTarget defaults to compileOptions.targetCompatibility
    // above, so no separate kotlin { compilerOptions {} } override is needed.

    signingConfigs {
        if (hasKeystoreProperties) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig =
                if (hasKeystoreProperties) {
                    signingConfigs.getByName("release")
                } else {
                    logger.warn(
                        "penboard: android/keystore.properties not found -- signing " +
                            ":app release build type with the DEBUG key instead. This APK is " +
                            "fine for local sideloading/testing but must never be distributed " +
                            "as-is. Copy keystore.properties.template to keystore.properties " +
                            "and point it at a real release keystore to fix."
                    )
                    signingConfigs.getByName("debug")
                }
        }
    }

    lint {
        warningsAsErrors = true
        abortOnError = true
        // Deliberate, documented pins (EXECUTION-PLAN.md §0), not staleness:
        // compileSdk 36 (not 37) keeps the tablet orientation/resizability
        // opt-out that API 37 removes; targetSdk follows compileSdk for the
        // same reason; AGP/Gradle patch versions are pinned exactly as
        // verified in the plan rather than auto-tracking latest.
        disable += setOf("OldTargetApi", "GradleDependency", "AndroidGradlePluginVersion")
        // <adaptive-icon> requires the -v26 folder qualifier for AAPT2 to
        // parse it at all, regardless of minSdk (confirmed by build failure
        // when merged into a qualifier-less mipmap-anydpi/) -- lint's
        // "merge into mipmap-anydpi" suggestion does not apply here.
        disable += "ObsoleteSdkInt"
    }

    dependencyLocking { lockAllConfigurations() }
}

ktfmt { kotlinLangStyle() }

// Formatting is the source of truth (AISMA manual): a normal `check`/CI run
// must fail on unformatted code, not just when someone remembers to run
// ktfmtFormat by hand.
tasks.named("check") { dependsOn(tasks.withType(KtfmtCheckTask::class.java)) }

dependencies {
    implementation(libs.androidx.core)
    implementation(libs.androidx.appcompat)

    testImplementation(libs.junit)
}
