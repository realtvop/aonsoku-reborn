package github.realtvop.aonsoku.ui.overlays

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.i18n.t

/** Validation of the radio form; each function returns an error key or null. */
object RadioFormRules {
    private val PROTOCOL = Regex("^https?://")

    fun nameError(name: String): String? =
        if (name.trim().length < 3) "radios.form.validations.name" else null

    /** The homepage is optional; a given one must be a full http(s) URL. */
    fun homePageError(url: String): String? {
        val value = url.trim()
        return when {
            value.isEmpty() -> null
            value.length < 10 -> "radios.form.validations.homepageUrlLength"
            !PROTOCOL.containsMatchIn(value) -> "login.form.validations.protocol"
            else -> null
        }
    }

    fun streamError(url: String): String? {
        val value = url.trim()
        return when {
            value.length < 10 -> "radios.form.validations.streamUrlLength"
            !PROTOCOL.containsMatchIn(value) -> "login.form.validations.protocol"
            else -> null
        }
    }
}

@Composable
fun RadioFormDialog(overlay: Overlay.RadioForm, controller: OverlayController) {
    val graph = LocalAppGraph.current
    val editing = overlay.radio
    var name by rememberSaveable { mutableStateOf(editing?.name.orEmpty()) }
    var homePage by rememberSaveable { mutableStateOf(editing?.homePageUrl.orEmpty()) }
    var stream by rememberSaveable { mutableStateOf(editing?.streamUrl.orEmpty()) }
    var submitted by rememberSaveable { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }

    val nameError = RadioFormRules.nameError(name)
    val homePageError = RadioFormRules.homePageError(homePage)
    val streamError = RadioFormRules.streamError(stream)

    fun submit() {
        submitted = true
        if (nameError != null || homePageError != null || streamError != null || saving) return
        saving = true
        val failed = { saving = false }
        if (editing == null) {
            graph.actions.createRadio(
                name = name.trim(),
                streamUrl = stream.trim(),
                homePageUrl = homePage.trim(),
                onDone = controller::dismiss,
                onFailed = failed,
            )
        } else {
            graph.actions.updateRadio(
                editing.copy(
                    name = name.trim(),
                    streamUrl = stream.trim(),
                    homePageUrl = homePage.trim(),
                ),
                onDone = controller::dismiss,
                onFailed = failed,
            )
        }
    }

    AlertDialog(
        onDismissRequest = controller::dismiss,
        title = {
            Text(t(if (editing == null) "radios.form.create.title" else "radios.form.edit.title"))
        },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                FormField(
                    value = name,
                    onValueChange = { name = it },
                    label = t("radios.table.name"),
                    errorKey = nameError.takeIf { submitted },
                )
                FormField(
                    value = homePage,
                    onValueChange = { homePage = it },
                    label = t("radios.table.homepage"),
                    errorKey = homePageError.takeIf { submitted },
                    keyboardType = KeyboardType.Uri,
                )
                FormField(
                    value = stream,
                    onValueChange = { stream = it },
                    label = t("radios.table.stream"),
                    errorKey = streamError.takeIf { submitted },
                    keyboardType = KeyboardType.Uri,
                    imeAction = ImeAction.Done,
                )
            }
        },
        confirmButton = {
            Button(onClick = ::submit, enabled = !saving) {
                Text(
                    t(
                        if (editing == null) {
                            "radios.form.create.button"
                        } else {
                            "radios.form.edit.button"
                        },
                    ),
                )
            }
        },
        dismissButton = {
            TextButton(onClick = controller::dismiss) { Text(t("generic.cancel")) }
        },
    )
}

@Composable
private fun FormField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    errorKey: String?,
    keyboardType: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Next,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth(),
        label = { Text(label) },
        singleLine = true,
        isError = errorKey != null,
        supportingText = if (errorKey != null) {
            { Text(t(errorKey)) }
        } else {
            null
        },
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = imeAction),
    )
}

@Composable
fun DeleteRadioDialog(overlay: Overlay.DeleteRadio, controller: OverlayController) {
    val graph = LocalAppGraph.current
    ConfirmDialog(
        title = t("radios.form.delete.title"),
        description = t("radios.form.delete.description"),
        onDismiss = controller::dismiss,
        onConfirm = {
            controller.dismiss()
            graph.actions.deleteRadio(overlay.radio.id)
        },
    )
}
