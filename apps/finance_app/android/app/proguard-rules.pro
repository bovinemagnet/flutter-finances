# Applied to release builds by the Flutter Gradle plugin.

# google_mlkit_text_recognition references the optional Chinese, Devanagari,
# Japanese and Korean recognisers. Only the Latin recogniser is bundled, so
# R8 must not fail on the absent classes.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ML Kit finds its components by name, so renaming or removing them makes every
# recognition fail at run time with a NullPointerException, on photos and
# scanned PDFs alike. Debug builds are not shrunk and never show this.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
