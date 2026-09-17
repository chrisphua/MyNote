package io.mynote.app.ui

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.text.KeyboardOptions
import io.mynote.app.AppContainer
import io.mynote.app.auth.AuthStatus
import io.mynote.app.theme.LocalMyNoteColors
import io.mynote.app.theme.LocalMyNoteMetrics
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SignInScreen(container: AppContainer, activity: Activity, onDone: () -> Unit) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current
    val scope = rememberCoroutineScope()

    val status by container.auth.status.collectAsState()
    val error by container.auth.error.collectAsState()

    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var creating by remember { mutableStateOf(false) }

    LaunchedEffect(status) {
        if (status is AuthStatus.SignedIn) onDone()
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text("Account", color = colors.textPrimary) },
                navigationIcon = {
                    IconButton(onClick = onDone) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = colors.textSecondary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize().background(colors.background)) {
            Column(
                Modifier
                    .align(Alignment.TopCenter)
                    .widthIn(max = 440.dp)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(metrics.contentPadding),
                verticalArrangement = Arrangement.spacedBy(14.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    if (creating) "Create an account" else "Sign in",
                    color = colors.textPrimary,
                    fontSize = metrics.baseSize * 1.4f,
                    fontWeight = metrics.headingWeight,
                )
                Text(
                    "Only needed for syncing and for carrying purchases between devices. Your notes already work without it.",
                    color = colors.textSecondary,
                    fontSize = metrics.baseSize * 0.82f,
                )

                OutlinedButton(
                    onClick = {
                        scope.launch {
                            // The Web client id from google-services.json; without
                            // Firebase configured this is a no-op with a message.
                            container.auth.signInWithGoogle(activity, serverClientId = "")
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Continue with Google") }

                Field("Email", email, { email = it }, KeyboardType.Email)
                Field("Password", password, { password = it }, KeyboardType.Password, secret = true)

                Button(
                    onClick = {
                        scope.launch {
                            if (creating) container.auth.signUp(email, password)
                            else container.auth.signIn(email, password)
                        }
                    },
                    enabled = email.isNotBlank() && password.isNotBlank(),
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(if (creating) "Create account" else "Sign in") }

                error?.let {
                    Text(it, color = Color.Red, fontSize = metrics.baseSize * 0.82f)
                }

                TextButton(onClick = { creating = !creating; container.auth.clearError() }) {
                    Text(if (creating) "I already have an account" else "Create an account")
                }
                if (!creating && email.isNotBlank()) {
                    TextButton(onClick = { scope.launch { container.auth.sendPasswordReset(email) } }) {
                        Text("Reset password")
                    }
                }
            }
        }
    }
}

@Composable
private fun Field(
    label: String,
    value: String,
    onChange: (String) -> Unit,
    keyboard: KeyboardType,
    secret: Boolean = false,
) {
    val colors = LocalMyNoteColors.current
    val metrics = LocalMyNoteMetrics.current

    Box(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(metrics.cornerRadius))
            .background(colors.surface)
            .padding(12.dp)
    ) {
        if (value.isEmpty()) {
            Text(label, color = colors.textSecondary, fontSize = metrics.baseSize)
        }
        BasicTextField(
            value = value,
            onValueChange = onChange,
            singleLine = true,
            visualTransformation = if (secret) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
            keyboardOptions = KeyboardOptions(keyboardType = keyboard),
            textStyle = TextStyle(color = colors.textPrimary, fontSize = metrics.baseSize),
            cursorBrush = SolidColor(colors.accent),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}
