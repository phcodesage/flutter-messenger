import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Temporarily disabled for v2 build: id("com.google.gms.google-services")
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

// ---------------------------------------------------------------------------
// Decode --dart-define / --dart-define-from-file values passed by Flutter.
// Flutter base64-encodes each KEY=VALUE pair and joins them with ",".
// ---------------------------------------------------------------------------
fun dartDefines(): Map<String, String> {
    val raw = (project.findProperty("dart-defines") as? String) ?: return emptyMap()
    return raw.split(",").associate { encoded ->
        val decoded = String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
        val idx = decoded.indexOf('=')
        if (idx < 0) decoded to "" else decoded.substring(0, idx) to decoded.substring(idx + 1)
    }
}

val dartEnv: Map<String, String> = dartDefines()
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()

if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { stream ->
        keystoreProperties.load(stream)
    }
}

val isReleaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}

android {
    namespace = "com.example.flutter_messenger_v2"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.flutter_messenger_v2"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Expose BASE_URL to native Kotlin code via BuildConfig.BASE_URL.
        // api_config.dart is the single source of truth: read its defaultValue
        // at build time so the native (quick-reply) side can never drift from
        // the Dart side. A BASE_URL dart-define still wins if explicitly given,
        // because then the Dart side uses it too.
        val apiConfigDefault = file("../../lib/config/api_config.dart")
            .readLines()
            .firstOrNull { it.trimStart().startsWith("defaultValue:") }
            ?.let { Regex("'([^']+)'").find(it)?.groupValues?.get(1) }
        val baseUrl = dartEnv["BASE_URL"]
            ?: apiConfigDefault
            ?: throw GradleException("Could not read BASE_URL defaultValue from lib/config/api_config.dart")
        buildConfigField("String", "BASE_URL", "\"$baseUrl\"")
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                val storeFilePath = keystoreProperties["storeFile"]?.toString()?.trim()
                if (storeFilePath.isNullOrEmpty()) {
                    throw GradleException("android/key.properties is missing storeFile.")
                }
                storeFile = rootProject.file(storeFilePath)
                storePassword = keystoreProperties["storePassword"]?.toString()
                keyAlias = keystoreProperties["keyAlias"]?.toString()
                keyPassword = keystoreProperties["keyPassword"]?.toString()
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                if (isReleaseTaskRequested) {
                    throw GradleException(
                        "Release signing is not configured. Create android/key.properties with your stable keystore to build a release APK."
                    )
                }
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    // Temporarily disabled for v2 build: implementation(platform("com.google.firebase:firebase-bom:32.7.0"))
    // Temporarily disabled for v2 build: implementation("com.google.firebase:firebase-messaging")
    compileOnly("com.google.firebase:firebase-messaging:23.4.1")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}

flutter {
    source = "../.."
}
