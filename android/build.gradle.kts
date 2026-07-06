// AGP 9 has built-in Kotlin support: applying the separate
// org.jetbrains.kotlin.android plugin is rejected outright ("no longer
// required for Kotlin support since AGP 9.0", kotl.in/gradle/agp-built-in-kotlin).
// AGP 9.2's built-in Kotlin defaults to KGP 2.2.10; pin the higher 2.4.0 the
// project targets (docs/EXECUTION-PLAN.md §0) via the documented buildscript
// classpath override. Version catalog accessors (`libs.*`) are not resolvable
// inside `buildscript {}`, so this literal must be kept in sync by hand with
// `gradle/libs.versions.toml`'s `kotlin` entry.
buildscript {
    dependencies {
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.0")
    }
}

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.ktfmt) apply false
}
