# Room creates WorkDatabase_Impl through its public zero-argument constructor.
# Room 2.6.1's consumer rule preserves the class but does not explicitly retain
# that constructor under the release shrinker (APK 900055 startup regression).
-keep class androidx.work.impl.WorkDatabase_Impl {
    public <init>();
}

# WorkManager's default WorkerFactory reflects this exact constructor. Keep its
# descriptor as well as its persisted class name across future release builds.
-keep class com.azx8788.opencode.mini.ScheduledPromptWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}
