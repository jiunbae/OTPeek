# JNA resolves names/layout/callbacks by reflection, including UniFFI checksum methods.
-keep class com.sun.jna.** { *; }
-keep class uniffi.otpeek.** { *; }
-dontwarn java.awt.**
