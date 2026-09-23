import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}
val testingBuild = System.getenv("VAACHAK_TEST_BUILD") == "1"
val testingSigning = System.getenv("VAACHAK_TEST_SIGNING_FILE")
if (testingBuild && testingSigning.isNullOrBlank()) {
    throw GradleException("Testing release requires a separate testing signing configuration.")
}
val signingFile = if (testingBuild) file(testingSigning!!) else rootProject.file("key.properties")
val releaseKeys = Properties()
if (signingFile.exists()) signingFile.inputStream().use { releaseKeys.load(it) }
if (gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) } && !signingFile.exists()) {
    throw GradleException("Release signing requires android/key.properties. Debug signing is never used for a release.")
}
android {
    namespace = "ai.vaachak.vaachak_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "ai.vaachak.vaachak_app"
        if (testingBuild) applicationIdSuffix = ".testing"
        manifestPlaceholders["appLabel"] = if (testingBuild) "VaachakAI Testing" else "VaachakAI"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (!testingBuild) ndk { abiFilters.add("arm64-v8a") }
    }
    packaging {
        jniLibs {
            // Compress native libraries for smaller APK sharing; Android extracts them at install.
            useLegacyPackaging = true
        }
    }
    signingConfigs {
        if (signingFile.exists()) create("release") {
            keyAlias = releaseKeys.getProperty("keyAlias")
            keyPassword = releaseKeys.getProperty("keyPassword")
            storeFile = file(releaseKeys.getProperty("storeFile"))
            storePassword = releaseKeys.getProperty("storePassword")
        }
    }
    buildTypes {
        release {
            if (signingFile.exists()) signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}
kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
flutter { source = "../.." }
