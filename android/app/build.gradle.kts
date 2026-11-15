import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigning = Properties()
val signingFile = rootProject.file("key.properties")
if (signingFile.exists()) signingFile.inputStream().use { releaseSigning.load(it) }
fun signingValue(property: String, environment: String): String? =
    System.getenv(environment) ?: releaseSigning.getProperty(property)
val releaseStoreFile = signingValue("storeFile", "APRI_ANDROID_KEYSTORE")
val releaseStorePassword = signingValue("storePassword", "APRI_ANDROID_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "APRI_ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "APRI_ANDROID_KEY_PASSWORD")
val hasReleaseSigning = listOf(releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
    .all { !it.isNullOrBlank() }

// A dependency can supply libraries for ABIs whose Flutter engine was not built.
// Keep the selected Flutter targets complete, including single-target previews.
val flutterTargetAbis = mapOf(
    "android-arm" to "armeabi-v7a",
    "android-arm64" to "arm64-v8a",
    "android-x64" to "x86_64",
)
val selectedAbis = (findProperty("target-platform")?.toString()?.split(",")
    ?: flutterTargetAbis.keys.toList()).map { flutterTargetAbis.getValue(it) }.toSet()

android {
    namespace = "com.bahadur.personal_finance"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    packaging {
        jniLibs.excludes += (flutterTargetAbis.values.toSet() - selectedAbis)
            .map { "lib/$it/**" }
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Stable ID preserves installed data and upgrade compatibility.
        applicationId = "com.bahadur.personal_finance"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) signingConfigs.getByName("release") else null
        }
    }
}

val verifyReleaseSigning = tasks.register("verifyReleaseSigning") {
    doLast {
        check(hasReleaseSigning) {
            "Release signing is missing. Configure private android/key.properties or APRI_ANDROID_* variables. " +
                "For local preview use flutter build apk --debug. Debug signing is never used automatically for release."
        }
    }
}
tasks.matching { it.name == "packageRelease" || it.name == "signReleaseBundle" }.configureEach {
    dependsOn(verifyReleaseSigning)
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
