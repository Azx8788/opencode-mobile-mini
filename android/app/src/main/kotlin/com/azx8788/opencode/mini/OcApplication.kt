package com.azx8788.opencode.mini

import android.app.Application

/** Installed before activities/services so foreground service failures survive. */
class OcApplication : Application() {
    override fun onCreate() {
        try { NativeCrashStore(filesDir).install() } catch (_: Throwable) { }
        super.onCreate()
    }
}
