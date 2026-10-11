package github.realtvop.aonsoku.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp

sealed interface NativeDialog {
    data class Confirm(val title: String, val message: String, val action: () -> Unit) : NativeDialog
    data class Form(val title: String, val fields: List<NativeField>, val submit: suspend (Map<String, String>) -> Unit) : NativeDialog
    data class Choose(val title: String, val choices: List<Pair<String, () -> Unit>>) : NativeDialog
    data class Info(val title: String, val text: String) : NativeDialog
}
data class NativeField(val key: String, val label: String, val value: String = "", val toggle: Boolean = false, val secret: Boolean = false)

@Composable
fun NativeDialogs(model: AonsokuViewModel) {
    val dialog by model.dialog.collectAsState()
    val dismiss = { model.dialog.value = null }
    when (val d = dialog) {
        is NativeDialog.Confirm -> AlertDialog(onDismissRequest = dismiss, title = { Text(L(d.title)) }, text = { Text(L(d.message)) }, confirmButton = { TextButton({ dismiss(); d.action() }) { Text("Confirm") } }, dismissButton = { TextButton(dismiss) { Text("Cancel") } })
        is NativeDialog.Info -> AlertDialog(onDismissRequest = dismiss, title = { Text(L(d.title)) }, text = { Text(d.text, Modifier.verticalScroll(rememberScrollState())) }, confirmButton = { TextButton(dismiss) { Text("Close") } })
        is NativeDialog.Choose -> AlertDialog(onDismissRequest = dismiss, title = { Text(L(d.title)) }, text = { Column(Modifier.verticalScroll(rememberScrollState())) { d.choices.forEach { (label, action) -> TextButton({ dismiss(); action() }, Modifier.fillMaxWidth()) { Text(L(label)) } } } }, confirmButton = { TextButton(dismiss) { Text("Cancel") } })
        is NativeDialog.Form -> {
            val values = remember(d) { mutableStateMapOf<String, String>().apply { d.fields.forEach { put(it.key, it.value) } } }
            var busy by remember(d) { mutableStateOf(false) }
            AlertDialog(onDismissRequest = { if (!busy) dismiss() }, title = { Text(L(d.title)) }, text = {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    d.fields.forEach { field ->
                        if (field.toggle) Row { Text(field.label, Modifier.weight(1f)); Switch(values[field.key] == "true", { values[field.key] = it.toString() }) }
                        else OutlinedTextField(values[field.key].orEmpty(), { values[field.key] = it }, label = { Text(L(field.label)) }, visualTransformation = if (field.secret) PasswordVisualTransformation() else VisualTransformation.None, modifier = Modifier.fillMaxWidth())
                    }
                }
            }, confirmButton = { TextButton({ busy = true; model.launch { try { d.submit(values.toMap()); if (model.dialog.value === d) dismiss() } finally { busy = false } } }, enabled = !busy) { Text(if (busy) "Saving…" else "Save") } }, dismissButton = { TextButton(dismiss, enabled = !busy) { Text("Cancel") } })
        }
        null -> Unit
    }
}
