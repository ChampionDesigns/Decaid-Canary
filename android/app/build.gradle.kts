plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.decentespresso.decaid.canary"
    compileSdk = 36
    // ndkVersion = flutter.ndkVersion
		ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    defaultConfig {
        applicationId = "com.decentespresso.decaid.canary"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = 35
        // Use git commit count as versionCode so debug and release builds always
        // share the same monotonically increasing version, preventing downgrade uninstalls.
        versionCode = providers.exec {
            commandLine("git", "rev-list", "--count", "origin/main")
        }.standardOutput.asText.get().trim().toInt()
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = file("canary-release.keystore")
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: "442f4e4bca093a8d9c67914c"
            keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "canary"
            keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: "442f4e4bca093a8d9c67914c"
        }
    }

    buildTypes {
        getByName("release") {
            // Sign with the local canary keystore when present; CI has no
            // keystore and Gradle then emits app-release-unsigned.apk.
            if (file("canary-release.keystore").exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}




