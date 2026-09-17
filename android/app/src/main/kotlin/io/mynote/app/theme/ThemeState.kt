package io.mynote.app.theme

import android.content.Context
import androidx.core.content.edit
import io.mynote.core.MyNoteJson
import io.mynote.core.ThemeSpec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.builtins.ListSerializer

enum class Appearance(val label: String) {
    SYSTEM("Match device"),
    LIGHT("Always light"),
    DARK("Always dark"),
}

/**
 * Holds the active theme and the user's custom ones.
 *
 * Presets are free. Creating, editing or importing a theme requires the
 * `theme_pro` entitlement — the gate lives in [canEdit], and the UI asks here
 * rather than checking receipts itself.
 */
class ThemeState(context: Context) {
    private val prefs = context.getSharedPreferences("mynote.theme", Context.MODE_PRIVATE)
    private val listSerializer = ListSerializer(ThemeSpec.serializer())

    private val _current = MutableStateFlow(ThemeSpec.defaultTheme)
    val current: StateFlow<ThemeSpec> = _current.asStateFlow()

    private val _custom = MutableStateFlow<List<ThemeSpec>>(emptyList())
    val custom: StateFlow<List<ThemeSpec>> = _custom.asStateFlow()

    private val _appearance = MutableStateFlow(Appearance.SYSTEM)
    val appearance: StateFlow<Appearance> = _appearance.asStateFlow()

    /** Flipped by billing; themes stay selectable but not editable. */
    @Volatile
    var canEdit: Boolean = false

    init {
        _appearance.value = runCatching {
            Appearance.valueOf(prefs.getString(KEY_APPEARANCE, null) ?: "SYSTEM")
        }.getOrDefault(Appearance.SYSTEM)

        _custom.value = prefs.getString(KEY_CUSTOM, null)
            ?.let { raw -> runCatching { MyNoteJson.decodeFromString(listSerializer, raw) }.getOrNull() }
            ?.map { it.sanitized() }
            .orEmpty()

        val selectedId = prefs.getString(KEY_SELECTED, ThemeSpec.defaultTheme.id)
        _current.value = all().firstOrNull { it.id == selectedId } ?: ThemeSpec.defaultTheme
    }

    fun all(): List<ThemeSpec> = ThemeSpec.presets + _custom.value

    fun setAppearance(value: Appearance) {
        _appearance.value = value
        prefs.edit { putString(KEY_APPEARANCE, value.name) }
    }

    fun select(spec: ThemeSpec) {
        _current.value = spec.sanitized()
        prefs.edit { putString(KEY_SELECTED, spec.id) }
    }

    /** Returns null when the user has not paid — the caller shows the paywall. */
    fun saveCustom(spec: ThemeSpec): ThemeSpec? {
        if (!canEdit) return null
        val clean = spec.sanitized().copy(isPreset = false)
        _custom.value = _custom.value.filterNot { it.id == clean.id } + clean
        persist()
        if (_current.value.id == clean.id) _current.value = clean
        return clean
    }

    fun deleteCustom(spec: ThemeSpec) {
        _custom.value = _custom.value.filterNot { it.id == spec.id }
        persist()
        if (_current.value.id == spec.id) select(ThemeSpec.defaultTheme)
    }

    /** Start a new theme from what is on screen, so editing feels like tweaking. */
    fun draftFromCurrent(): ThemeSpec {
        val base = _current.value
        return base.copy(
            id = java.util.UUID.randomUUID().toString(),
            name = if (base.isPreset) "${base.name} Custom" else base.name,
            isPreset = false,
        )
    }

    private fun persist() {
        prefs.edit {
            putString(KEY_CUSTOM, MyNoteJson.encodeToString(listSerializer, _custom.value))
        }
    }

    private companion object {
        const val KEY_SELECTED = "selected"
        const val KEY_APPEARANCE = "appearance"
        const val KEY_CUSTOM = "custom"
    }
}
