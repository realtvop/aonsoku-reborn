package github.realtvop.aonsoku.ui.login

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.R
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.appLanguages
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.session.LoginResult
import github.realtvop.aonsoku.session.SessionManager
import kotlinx.coroutines.launch

@Composable
fun LoginScreen() {
    val graph = LocalAppGraph.current
    val strings = LocalStrings.current
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current

    var url by rememberSaveable { mutableStateOf("https://") }
    var username by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var passwordVisible by rememberSaveable { mutableStateOf(false) }
    var submitted by rememberSaveable { mutableStateOf(false) }
    var loading by remember { mutableStateOf(false) }
    var incompatibleServer by remember { mutableStateOf(false) }

    val urlError = when {
        !SessionManager.isValidServerUrl(SessionManager.normalizeServerUrl(url)) ->
            if (Regex("^https?://", RegexOption.IGNORE_CASE).containsMatchIn(url.trim())) {
                "login.form.validations.url"
            } else {
                "login.form.validations.protocol"
            }
        else -> null
    }
    val usernameError = when {
        username.isEmpty() -> "login.form.validations.username"
        username.length < 2 -> "login.form.validations.usernameLength"
        else -> null
    }
    val passwordError = when {
        password.isEmpty() -> "login.form.validations.password"
        password.length < 2 -> "login.form.validations.passwordLength"
        else -> null
    }

    fun submit(allowIncompatible: Boolean) {
        submitted = true
        if (loading || urlError != null || usernameError != null || passwordError != null) return
        focusManager.clearFocus()
        loading = true
        scope.launch {
            when (graph.session.login(url, username.trim(), password, allowIncompatible)) {
                LoginResult.Success -> {
                    graph.startSession()
                    graph.toaster.success(strings.t("toast.server.success"))
                }
                LoginResult.IncompatibleServer -> incompatibleServer = true
                LoginResult.Failed -> graph.toaster.error(strings.t("toast.server.error"))
            }
            loading = false
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .safeDrawingPadding()
            .imePadding(),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            AppTitle()
            Spacer(Modifier.height(28.dp))
            Surface(
                modifier = Modifier.widthIn(max = 460.dp).fillMaxWidth(),
                shape = MaterialTheme.shapes.extraLarge,
                color = MaterialTheme.colorScheme.surfaceContainerLow,
            ) {
                Column(modifier = Modifier.padding(24.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = t("login.form.server"),
                            style = MaterialTheme.typography.headlineSmall,
                            modifier = Modifier.weight(1f),
                        )
                        LanguageToggle()
                    }
                    Text(
                        text = t("login.form.description"),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(20.dp))

                    OutlinedTextField(
                        value = url,
                        onValueChange = { url = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text(t("login.form.url")) },
                        supportingText = {
                            Text(
                                if (submitted && urlError != null) {
                                    t(urlError)
                                } else {
                                    t("login.form.urlDescription")
                                },
                            )
                        },
                        isError = submitted && urlError != null,
                        singleLine = true,
                        enabled = !loading,
                        shape = MaterialTheme.shapes.medium,
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.None,
                            autoCorrectEnabled = false,
                            keyboardType = KeyboardType.Uri,
                            imeAction = ImeAction.Next,
                        ),
                    )
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = username,
                        onValueChange = { username = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text(t("login.form.username")) },
                        placeholder = { Text(t("login.form.usernamePlaceholder")) },
                        supportingText = if (submitted && usernameError != null) {
                            { Text(t(usernameError)) }
                        } else {
                            null
                        },
                        isError = submitted && usernameError != null,
                        singleLine = true,
                        enabled = !loading,
                        shape = MaterialTheme.shapes.medium,
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.None,
                            autoCorrectEnabled = false,
                            imeAction = ImeAction.Next,
                        ),
                    )
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text(t("login.form.password")) },
                        supportingText = if (submitted && passwordError != null) {
                            { Text(t(passwordError)) }
                        } else {
                            null
                        },
                        isError = submitted && passwordError != null,
                        singleLine = true,
                        enabled = !loading,
                        shape = MaterialTheme.shapes.medium,
                        visualTransformation = if (passwordVisible) {
                            VisualTransformation.None
                        } else {
                            PasswordVisualTransformation()
                        },
                        trailingIcon = {
                            IconButton(onClick = { passwordVisible = !passwordVisible }) {
                                Icon(
                                    imageVector = if (passwordVisible) {
                                        Icons.Rounded.VisibilityOff
                                    } else {
                                        Icons.Rounded.Visibility
                                    },
                                    contentDescription = t("login.form.password"),
                                )
                            }
                        },
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Password,
                            imeAction = ImeAction.Done,
                        ),
                        keyboardActions = KeyboardActions(
                            onNext = { focusManager.moveFocus(FocusDirection.Down) },
                            onDone = { submit(allowIncompatible = false) },
                        ),
                    )
                    Spacer(Modifier.height(20.dp))
                    Button(
                        onClick = { submit(allowIncompatible = false) },
                        enabled = !loading,
                        modifier = Modifier.fillMaxWidth().height(56.dp),
                        shapes = ButtonDefaults.shapes(),
                    ) {
                        if (loading) {
                            LoadingIndicator(
                                modifier = Modifier.size(28.dp),
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                            Spacer(Modifier.size(8.dp))
                            Text(t("login.form.connecting"))
                        } else {
                            Text(t("login.form.connect"))
                        }
                    }
                }
            }
        }
    }

    if (incompatibleServer) {
        AlertDialog(
            onDismissRequest = { incompatibleServer = false },
            title = { Text(t("server.incompatible.title")) },
            text = { Text(t("server.incompatible.description")) },
            confirmButton = {
                TextButton(
                    onClick = {
                        incompatibleServer = false
                        submit(allowIncompatible = true)
                    },
                ) {
                    Text(t("server.incompatible.skip"))
                }
            },
            dismissButton = {
                TextButton(onClick = { incompatibleServer = false }) {
                    Text(t("generic.cancel"))
                }
            },
        )
    }
}

@Composable
fun AppTitle(modifier: Modifier = Modifier) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        Image(
            painter = painterResource(R.mipmap.ic_launcher_foreground),
            contentDescription = null,
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(MaterialTheme.colorScheme.surfaceContainerHighest),
        )
        Spacer(Modifier.size(12.dp))
        Text(
            text = "Aonsoku",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun LanguageToggle() {
    val graph = LocalAppGraph.current
    val current = LocalStrings.current.language
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(Icons.Rounded.Translate, contentDescription = t("menu.language"))
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            appLanguages.forEach { language ->
                DropdownMenuItem(
                    text = {
                        Text(
                            text = "${language.flag}  ${language.nativeName}",
                            fontWeight = if (language.code == current.code) {
                                FontWeight.SemiBold
                            } else {
                                FontWeight.Normal
                            },
                        )
                    },
                    onClick = {
                        expanded = false
                        graph.settings.update { it.copy(language = language.code) }
                    },
                )
            }
        }
    }
}
