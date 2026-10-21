# Flutter Rules
-keep class io.flutter.** { *; }

# Flutter Plugin Wrappers
-keep class com.google_mlkit_commons.** { *; }
-keep class com.google_mlkit_face_mesh_detection.** { *; }

# Google ML Kit Native SDK
-keep class com.google.mlkit.** { *; }
-keep interface com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }
-keep interface com.google.android.gms.** { *; }

# MediaPipe
-keep class com.google.mediapipe.** { *; }
-keep interface com.google.mediapipe.** { *; }

-dontwarn com.google.mlkit.**
-dontwarn com.google_mlkit_commons.**
-dontwarn com.google_mlkit_face_mesh_detection.**
-dontwarn com.google.android.gms.**
-dontwarn com.google.mediapipe.**
-dontwarn com.google.android.play.core.**
