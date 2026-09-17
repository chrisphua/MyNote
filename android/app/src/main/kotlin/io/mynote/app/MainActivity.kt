package io.mynote.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.calculateWindowSizeClass
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import io.mynote.app.theme.Appearance
import io.mynote.app.theme.MyNoteTheme
import io.mynote.app.ui.MyNoteRoot

class MainActivity : ComponentActivity() {

    @OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val container = (application as MyNoteApplication).container

        setContent {
            val spec by container.themeState.current.collectAsState()
            val appearance by container.themeState.appearance.collectAsState()

            val dark = when (appearance) {
                Appearance.SYSTEM -> isSystemInDarkTheme()
                Appearance.LIGHT -> false
                Appearance.DARK -> true
            }

            MyNoteTheme(spec = spec, darkTheme = dark) {
                // The window size class is what drives the phone-vs-tablet
                // layout, so a foldable opening mid-session re-lays out live.
                MyNoteRoot(
                    container = container,
                    windowSizeClass = calculateWindowSizeClass(this),
                    activity = this,
                )
            }
        }
    }
}
