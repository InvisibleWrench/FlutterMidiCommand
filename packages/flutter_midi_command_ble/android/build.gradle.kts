plugins {
    id("com.android.library")
}

rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

android {
    namespace = "com.invisiblewrench.fluttermidicommand.ble"
    compileSdk = 34

    defaultConfig {
        minSdk = 21
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}
