# Room constructs this generated WorkManager database by its derived class name
# and public no-arg constructor during process startup. R8 otherwise removes the
# constructor as unused, crashing even before an Activity or widget can start.
-keep class androidx.work.impl.WorkDatabase_Impl {
    public <init>();
}
# The default WorkerFactory restores persisted class names and invokes this
# signature reflectively after process death. Keep that durable constructor ABI.
-keep class com.azx8788.opencode.mini.WidgetStatusWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}
