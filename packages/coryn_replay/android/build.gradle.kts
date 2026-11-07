group = "ai.coryn.replay.flutter"
version = "0.1.0"

/** The plugin's Android code: the obfuscated Coryn Android SDK module `ai.coryn.replay.internal:flutter`; only the entry point is here. **/
val corynAndroidSdkVersion = "1.1.131"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "ai.coryn.replay.flutter.pub"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 26
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("ai.coryn.replay.internal:flutter:$corynAndroidSdkVersion")
}
