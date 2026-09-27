package app.dayline.dayline

import android.Manifest
import android.app.*
import android.appwidget.AppWidgetManager
import android.content.*
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private lateinit var bridge: MethodChannel
    private var folderResult: MethodChannel.Result? = null
    private val io = Executors.newSingleThreadExecutor()
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.dayline/native")
        Reminders.channels(this)
        bridge.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "load" -> result.success(Storage.prefs(this).getString("data", null))
                    "launch" -> result.success(mapOf("id" to intent.getStringExtra("itemId"), "new" to intent.getBooleanExtra("new", false)))
                    "save" -> {
                        val raw = call.arguments as String
                        io.execute {
                            try {
                                JSONObject(raw).getJSONArray("items")
                                val old = Storage.items(this)
                                if (!Storage.prefs(this).edit().putString("data", raw).commit()) error("Не удалось записать данные")
                                val current = Storage.items(this).associateBy { it.getString("id") }
                                Reminders.cancel(this, old.filter { current[it.getString("id")]?.toString() != it.toString() })
                                Reminders.schedule(this); AgendaWidget.updateAll(this)
                                runOnUiThread { result.success(null) }
                            } catch (e: Exception) { runOnUiThread { result.error("SAVE", e.message, null) } }
                        }
                    }
                    "status" -> result.success(mapOf(
                        "notifications" to getSystemService(NotificationManager::class.java).areNotificationsEnabled(),
                        "exact" to getSystemService(AlarmManager::class.java).canScheduleExactAlarms(),
                        "vault" to (Storage.prefs(this).getString("vault", null) != null)))
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 80)
                        else startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                        result.success(null)
                    }
                    "requestExact" -> {
                        if (!getSystemService(AlarmManager::class.java).canScheduleExactAlarms()) startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
                        result.success(null)
                    }
                    "testNotification" -> { Reminders.test(this); result.success(null) }
                    "pinWidget" -> {
                        val manager = AppWidgetManager.getInstance(this)
                        if (manager.isRequestPinAppWidgetSupported) { manager.requestPinAppWidget(ComponentName(this, AgendaWidget::class.java), null, null); result.success(null) }
                        else result.error("WIDGET", "Удерживайте пустое место главного экрана → Виджеты → Dayline", null)
                    }
                    "connectVault" -> {
                        if (folderResult != null) result.error("BUSY", "Выбор папки уже открыт", null)
                        else { folderResult = result; startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION), 81) }
                    }
                    "disconnectVault" -> { Storage.prefs(this).edit().remove("vault").commit(); result.success(null) }
                    "readVault" -> io.execute {
                        try { val content = if (Vault.exists(this)) Vault.read(this) else null; runOnUiThread { result.success(content) } }
                        catch (e: Exception) { runOnUiThread { result.error("VAULT", e.message, null) } }
                    }
                    "listVaultFolders" -> io.execute {
                        try { val folders = Vault.folders(this); runOnUiThread { result.success(folders) } }
                        catch (e: Exception) { runOnUiThread { result.error("VAULT_FOLDERS", e.message, null) } }
                    }
                    "writeVault" -> {
                        val args = call.arguments as Map<*, *>
                        io.execute {
                            try { Vault.write(this, args["expected"] as String, args["content"] as String); runOnUiThread { result.success(null) } }
                            catch (e: Exception) { runOnUiThread { result.error("VAULT", e.message, null) } }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("ANDROID", e.message, null) }
        }
    }
    override fun onResume() { super.onResume(); if (::bridge.isInitialized) io.execute { Reminders.schedule(this) } }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent); setIntent(intent)
        if (::bridge.isInitialized) { if (intent.getBooleanExtra("new", false)) bridge.invokeMethod("new", null) else intent.getStringExtra("itemId")?.let { bridge.invokeMethod("open", it) } }
    }
    @Deprecated("Android callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 81) return
        val pending = folderResult ?: return; folderResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) { pending.success(false); return }
        try {
            val uri = data.data!!
            contentResolver.takePersistableUriPermission(uri, data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
            if (!Storage.prefs(this).edit().putString("vault", uri.toString()).commit()) error("Не удалось сохранить папку")
            pending.success(true)
        } catch (e: Exception) { pending.error("VAULT", e.message, null) }
    }
}

object Vault {
    // Only folder names are read. Notes and plugin directories are never scanned.
    fun folders(c: Context): List<String> {
        val tree = tree(c)
        val queue = java.util.ArrayDeque<Pair<String, String>>()
        val visited = mutableSetOf<String>()
        val folders = mutableListOf<String>()
        queue.add(DocumentsContract.getTreeDocumentId(tree) to "")
        while (queue.isNotEmpty()) {
            val (parentId, parentPath) = queue.removeFirst()
            if (!visited.add(parentId)) continue
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
            c.contentResolver.query(children, arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val name = cursor.getString(1) ?: continue
                    if (cursor.getString(2) != DocumentsContract.Document.MIME_TYPE_DIR || name.startsWith(".")) continue
                    val path = if (parentPath.isEmpty()) name else "$parentPath/$name"
                    folders.add(path)
                    check(folders.size <= 10000) { "В хранилище больше 10 000 папок. Выберите нужную подпапку." }
                    queue.add(cursor.getString(0) to path)
                }
            } ?: error("Нет доступа к списку папок")
        }
        return folders.sortedWith(String.CASE_INSENSITIVE_ORDER)
    }
    fun exists(c: Context): Boolean = document(c, false) != null
    private fun tree(c: Context): Uri = Uri.parse(Storage.prefs(c).getString("vault", null) ?: error("Папка не подключена"))
    private fun document(c: Context, create: Boolean): Uri? {
        val tree = tree(c); val rootId = DocumentsContract.getTreeDocumentId(tree)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, rootId)
        c.contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) if (cursor.getString(1) == "Dayline.md") return DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0))
        } ?: error("Нет доступа к папке")
        return if (create) DocumentsContract.createDocument(c.contentResolver, DocumentsContract.buildDocumentUriUsingTree(tree, rootId), "text/markdown", "Dayline.md") ?: error("Не удалось создать Dayline.md") else null
    }
    fun read(c: Context): String {
        val uri = document(c, false) ?: return ""
        return c.contentResolver.openInputStream(uri)?.use { stream ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val n = stream.read(buffer)
                if (n < 0) break
                require(output.size() + n <= 2 * 1024 * 1024) { "Dayline.md больше 2 МБ" }
                output.write(buffer, 0, n)
            }
            output.toString("UTF-8")
        } ?: error("Не удалось прочитать Dayline.md")
    }
    fun write(c: Context, expected: String, content: String) {
        check(read(c) == expected) { "Файл изменился в Obsidian. Повторите синхронизацию." }
        if (content == expected) return
        java.io.File(c.filesDir, "Dayline-before-sync.md").writeText(expected)
        val uri = document(c, true)!!
        try {
            c.contentResolver.openOutputStream(uri, "wt")?.use { it.write(content.toByteArray(Charsets.UTF_8)) } ?: error("Не удалось записать Dayline.md")
            check(read(c) == content) { "Проверка записи Dayline.md не пройдена" }
        } catch (e: Exception) {
            try { c.contentResolver.openOutputStream(uri, "wt")?.use { it.write(expected.toByteArray(Charsets.UTF_8)) } } catch (_: Exception) { }
            throw e
        }
    }
}
