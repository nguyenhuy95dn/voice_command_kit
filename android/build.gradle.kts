group = "com.nightsoft.voice_command_kit"
version = "0.1.0"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.nightsoft.voice_command_kit"

    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
            // libonnxruntime.so is a prebuilt dependency of the wake-word core;
            // CMake only imports it, so it has to be packaged from here.
            jniLibs.srcDirs("src/main/cpp/onnxruntime/lib")
        }
    }

    defaultConfig {
        minSdk = 24

        externalNativeBuild {
            cmake {
                cppFlags.add("-std=c++17")

                // Only the ABIs ONNX Runtime is vendored for below. Without
                // this the module tries every ABI the NDK supports and fails on
                // x86, which has no libonnxruntime.so to link against.
                // A consuming app narrows this further with its own abiFilters.
                abiFilters += setOf("arm64-v8a", "armeabi-v7a", "x86_64")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // Deliberately no jniLibs exclusion here. Dropping x86_64 would leave
    // libvoice_wakeword.so shipping for an ABI whose libonnxruntime.so is
    // missing, which fails at load rather than at build. Trimming ABIs is the
    // consuming app's call, via its own abiFilters.
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
}
