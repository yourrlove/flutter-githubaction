import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.lua.tech.fluttergithubaction"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "30.0.16248370"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.lua.tech.fluttergithubaction"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val propsStoreFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            val envStoreFile = System.getenv("KEYSTORE_PATH")?.let { file(it) }
            if (propsStoreFile?.exists() == true) {
                storeFile = propsStoreFile
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            } else if (envStoreFile?.exists() == true) {
                storeFile = envStoreFile
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEY_ALIAS")
                keyPassword = System.getenv("KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            val propsStoreFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            val envStoreFile = System.getenv("KEYSTORE_PATH")?.let { file(it) }
            val useReleaseKey = propsStoreFile?.exists() == true || envStoreFile?.exists() == true
            if (useReleaseKey) {
                println("🚀 SIGNING WITH CUSTOM SECURE RELEASE KEY!")
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Fallback to debug keys if secrets are not provided
                println("⚠️ NO SECURE KEY FOUND. SIGNING WITH DEFAULT DEBUG KEY.")
                signingConfig = signingConfigs.getByName("debug")
            }
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
