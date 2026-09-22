import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. key.properties (and the keystore it points at) are
// git-ignored on purpose — see android/key.properties.example for the
// format. If it's missing (e.g. a fresh clone before it's been set up),
// falls back to the debug key so `flutter build apk --release` still
// works, just unsigned for real distribution.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasKeystoreProperties = keystorePropertiesFile.exists()
if (hasKeystoreProperties) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.soozyyy.vspomusic.vspo_music"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.soozyyy.vspomusic.vspo_music"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasKeystoreProperties) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Uses the dedicated vspo-release keystore when key.properties
            // is present (local dev with it set up, or CI with it written
            // from a secret) — this keeps every build signed with the same
            // key, so installing a newer APK over an older one always works
            // as an update instead of failing with a signature mismatch.
            // Falls back to the debug key otherwise, so the project still
            // builds out of the box before key.properties exists.
            signingConfig = if (hasKeystoreProperties) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    // MediaSessionCompat + MediaStyle notifications, for lock-screen and
    // hardware media-button controls. Nothing else here pulls this in
    // transitively — this is the module's first and only direct dependency.
    implementation("androidx.media:media:1.7.0")
}

flutter {
    source = "../.."
}
