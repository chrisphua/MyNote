# kotlinx.serialization keeps its serializers in companion objects that R8
# cannot see are used; without these the app crashes on first sync in release.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class io.mynote.** {
    *** Companion;
}
-keepclasseswithmembers class io.mynote.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class io.mynote.core.**$$serializer { *; }

# Room generates implementations reflectively from these.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
