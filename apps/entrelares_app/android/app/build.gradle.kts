plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.entrelares.entrelares_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // minSdk 26: the product's locked floor (same as the console pilot).
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Stage 3 (T-53): environments are BUILD VARIANTS — the Supabase singleton
    // initializes once per process (pilot lesson 8), so there is no runtime
    // switcher by construction. Every build now REQUIRES --flavor.
    flavorDimensions += "env"
    productFlavors {
        create("dev") {
            dimension = "env"
            // The spike id, DIFFERENT from the Play package on purpose: the
            // dev APK coexists with the store-installed app on the owner's
            // device (and its launcher label tells them apart).
            applicationId = "com.entrelares.flutter"
            manifestPlaceholders["appName"] = "Entrelares Dev"
        }
        create("prod") {
            dimension = "env"
            // The Play package — stage 0 proved it accepts a Flutter build
            // with the same upload signature. Distributing this flavor is
            // gated on the T-55 upload keystore (debug keystores are
            // per-machine, pilot lesson 2.2).
            applicationId = "com.entrelares.app"
            manifestPlaceholders["appName"] = "Entrelares"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
