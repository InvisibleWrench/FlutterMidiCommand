plugins {
    id("com.android.library")
    id("kotlin-android")
}

dependencies {
    implementation("com.github.weliem:blessed-kotlin:3.0.8")
    implementation("com.jakewharton.timber:timber:5.0.1")
}

rootProject.allprojects {
    repositories {
        google()
        jcenter()
        mavenCentral()
        maven { setUrl("https://jitpack.io") }
    }
}

android {
    namespace = "com.invisiblewrench.flutter_midi_command_example"
    compileSdk = 34 // use flutter.compileSdkVersion  when Flutter 3.27.0 is widely used

    sourceSets {
        getByName("main").java.srcDirs("src/main/kotlin")
        getByName("test").java.srcDirs("src/test/kotlin")
    }
    defaultConfig {
        minSdkVersion(21)
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_1_8.toString()
    }

    dependencies {
        testImplementation("org.jetbrains.kotlin:kotlin-test")
        testImplementation("org.mockito:mockito-core:5.0.0")
    }
}

tasks.withType<Test> {
    useJUnitPlatform()

    testLogging {
        events("passed", "skipped", "failed", "standardOut", "standardError")
        outputs.upToDateWhen { false }
        showStandardStreams = true
    }
}
