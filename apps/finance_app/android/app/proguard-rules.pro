# Applied to release builds by the Flutter Gradle plugin.

# google_mlkit_text_recognition references the optional Chinese, Devanagari,
# Japanese and Korean recognisers. Only the Latin recogniser is bundled, so
# R8 must not fail on the absent classes.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
