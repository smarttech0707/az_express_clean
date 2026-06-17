# Flutter wrapper — must not be stripped or renamed
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Firebase — keep all Firebase classes intact
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# Firebase Crashlytics — required for crash symbolication
-keepattributes SourceFile,LineNumberTable
-keep public class * extends java.lang.Exception

# Google Maps
-keep class com.google.android.gms.maps.** { *; }
-keep interface com.google.android.gms.maps.** { *; }

# Kotlin coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-dontwarn kotlinx.coroutines.**

# Dart/Flutter entry points — never rename these
-keep class **.zapp.** { *; }

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Serialization — keep all Parcelable implementations
-keep class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}

# Suppress notes for missing classes from unused dependencies
-dontnote kotlinx.serialization.**
-dontwarn org.codehaus.mojo.**

# Google Play Core — classes référencées par Flutter mais non incluses
# (l'app n'utilise pas les deferred components / split APKs)
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.splitcompat.** { *; }
-keep class com.google.android.play.core.splitinstall.** { *; }
-keep class com.google.android.play.core.tasks.** { *; }

# Règles générées par R8 pour les classes manquantes
-ignorewarnings
