import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // Le plugin Flutter doit être appliqué après les plugins Android et Kotlin.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

// Clés de signature lues depuis key.properties (jamais commité dans git)
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "com.azexpress.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    signingConfigs {
        create("release") {
            keyAlias      = keyProperties["keyAlias"]      as String? ?: "az_express"
            keyPassword   = keyProperties["keyPassword"]   as String? ?: ""
            storeFile     = rootProject.file(keyProperties["storeFile"] as String? ?: "app/release.keystore")
            storePassword = keyProperties["storePassword"] as String? ?: ""
        }
    }

    defaultConfig {
        // Build de test isolé (test-env/) : -PazTestSuffix=.test installe l'app
        // à côté de la production au lieu de la remplacer. Sans la propriété,
        // l'identifiant reste com.azexpress.app (aucun changement pour les releases).
        applicationId = "com.azexpress.app" + (project.findProperty("azTestSuffix") as String? ?: "")
        minSdk        = flutter.minSdkVersion
        targetSdk     = flutter.targetSdkVersion
        versionCode   = flutter.versionCode
        versionName   = flutter.versionName
        // Build de test : JAMAIS la clé Google Maps de production (cartes désactivées, ou clé de test
        // explicitement fournie par -PazTestMapsKeyFile (fichier temporaire : la cle ne figure pas dans la ligne de
        // commande) ou, pour les scripts historiques, par -PazTestMapsKey).
        manifestPlaceholders["MAPS_API_KEY"] =
            if (project.hasProperty("azTestSuffix")) {
                val testMapsKeyFile = project.findProperty("azTestMapsKeyFile") as String?
                if (testMapsKeyFile != null) project.file(testMapsKeyFile).readText().trim()
                else (project.findProperty("azTestMapsKey") as String? ?: "")
            } else localProperties.getProperty("MAPS_API_KEY", "")
    }

    // Build de test sur émulateurs (test-env/) : manifeste de debug dédié (HTTP clair local,
    // télémétrie coupée). Sans -PazTestSuffix, aucun changement.
    if (project.hasProperty("azTestSuffix")) {
        sourceSets.getByName("debug").manifest.srcFile("src/azTest/AndroidManifest.xml")
    }

    buildTypes {
        release {
            isMinifyEnabled   = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            isMinifyEnabled = false
        }
    }
}

flutter {
    source = "../.."
}
