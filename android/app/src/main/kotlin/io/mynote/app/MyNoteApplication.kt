package io.mynote.app

import android.app.Application

class MyNoteApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        // Billing connects eagerly so the paywall has prices ready the first
        // time it is opened, rather than showing empty placeholders.
        container.billing.connect()
    }
}
