package io.mynote.app

import android.app.Application

class MyNoteApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        // Eager so the paywall has a price ready the first time it is opened,
        // and so a backup starts before the user reaches for it.
        container.start()
    }
}
