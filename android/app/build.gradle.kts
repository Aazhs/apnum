plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "dev.apnum.android"
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.apnum.android"
        minSdk = 28
        targetSdk = 37
        // scripts/release.sh passes -PappVersionName and -PappVersionCode.
        versionCode = (project.findProperty("appVersionCode") as String?)?.toInt() ?: 1
        versionName = (project.findProperty("appVersionName") as String?) ?: "0.1.0"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation("androidx.compose.material:material-icons-core")
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.service)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.code.scanner)
    // The Rust bindings need JNA's Android build.
    implementation("net.java.dev.jna:jna:5.17.0@aar")

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}

// The Rust link core is built outside Gradle. Fail early, with the fix, if it is missing.
val checkRustLibs by tasks.registering {
    val files = listOf("arm64-v8a", "x86_64").map {
        layout.projectDirectory.file("src/main/jniLibs/$it/libapnum_link.so").asFile
    }
    doLast {
        val missing = files.filter { !it.exists() }
        if (missing.isNotEmpty()) {
            throw GradleException(
                "The Rust link library is missing for ${missing.joinToString { it.parentFile.name }}. " +
                    "From the repository root, run: scripts/build-rust.sh android"
            )
        }
    }
}
tasks.matching { it.name == "preBuild" }.configureEach { dependsOn(checkRustLibs) }
