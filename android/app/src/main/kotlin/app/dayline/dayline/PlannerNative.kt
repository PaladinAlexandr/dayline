package app.dayline.dayline

import android.app.*
import android.content.*
import android.graphics.Color
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.time.*
import java.time.format.DateTimeFormatter
import java.util.Locale

object Storage {
    fun prefs(c: Context) = c.getSharedPreferences("dayline", Context.MODE_PRIVATE)
    fun items(c: Context): List<JSONObject> {
        val data = prefs(c).getString("data", null) ?: return emptyList()
        val arr = JSONObject(data).getJSONArray("items")
        return (0 until arr.length()).map { arr.getJSONObject(it) }
    }
}
data class NativeOccurrence(val item: JSONObject, val start: LocalDateTime, val end: LocalDateTime) {
    val done: Boolean get() {
        val key = if (item.optString("repeat", "none") == "none") "all" else start.toLocalDate().toString()
        val arr = item.optJSONArray("completed") ?: JSONArray()
        return (0 until arr.length()).any { arr.getString(it) == key }
    }
    val startMillis: Long get() = start.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
    val endMillis: Long get() = end.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
    val time: String get() = if (item.optBoolean("allDay")) "Весь день" else "${start.format(DateTimeFormatter.ofPattern("HH:mm"))} – ${end.format(DateTimeFormatter.ofPattern("HH:mm"))}"
}
object Occurrences {
    fun on(item: JSONObject, date: LocalDate): NativeOccurrence? {
        val base = LocalDateTime.parse(item.getString("start")); val end = LocalDateTime.parse(item.getString("end"))
        if (date.isBefore(base.toLocalDate())) return null
        val matches = when (item.optString("repeat", "none")) {
            "daily" -> true
            "weekdays" -> date.dayOfWeek.value <= 5
            "weekly" -> date.dayOfWeek == base.dayOfWeek
            "monthly" -> date.dayOfMonth == minOf(base.dayOfMonth, date.lengthOfMonth())
            else -> date == base.toLocalDate()
        }
        if (!matches) return null
        val days = java.time.temporal.ChronoUnit.DAYS.between(base.toLocalDate(), end.toLocalDate())
        return NativeOccurrence(item, date.atTime(base.toLocalTime()), date.plusDays(days).atTime(end.toLocalTime()))
    }
    fun upcoming(context: Context): List<NativeOccurrence> {
        val now = System.currentTimeMillis(); val today = LocalDate.now(); val result = mutableListOf<NativeOccurrence>()
        for (item in Storage.items(context)) {
            if (item.optString("repeat", "none") == "none") {
                val o = on(item, LocalDateTime.parse(item.getString("start")).toLocalDate())!!
                if (!o.done && (o.endMillis > now || item.optBoolean("task"))) result.add(o)
            } else for (day in -1L..30L) {
                val o = on(item, today.plusDays(day)) ?: continue
                if (!o.done && o.endMillis > now) result.add(o)
            }
        }
        return result.sortedBy { it.startMillis }.take(60)
    }
}
object Reminders {
    const val CHANNEL = "dayline_reminders"
    fun channels(context: Context) {
        val channel = NotificationChannel(CHANNEL, "Напоминания о делах", NotificationManager.IMPORTANCE_HIGH)
        channel.description = "События и задачи Dayline"; channel.enableVibration(true)
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }
    private fun pending(context: Context, id: String, minutes: Int, occurrence: String = ""): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java).setAction("app.dayline.REMIND").setData(Uri.parse("dayline://reminder/$id/$minutes"))
            .putExtra("itemId", id).putExtra("minutes", minutes).putExtra("occurrence", occurrence)
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    fun cancel(context: Context, items: List<JSONObject>) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        for (item in items) { val offsets = item.optJSONArray("reminders") ?: continue
            for (i in 0 until offsets.length()) alarms.cancel(pending(context, item.getString("id"), offsets.getInt(i))) }
    }
    private fun set(context: Context, millis: Long, pending: PendingIntent) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        try { if (alarms.canScheduleExactAlarms()) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, millis, pending)
            else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, millis, pending)
        } catch (_: SecurityException) { alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, millis, pending) }
    }
    fun schedule(context: Context) {
        val now = System.currentTimeMillis()
        data class Scheduled(val whenMs: Long, val id: String, val offset: Int, val date: String)
        val desired = mutableListOf<Scheduled>()
        for (item in Storage.items(context)) {
            val offsets = item.optJSONArray("reminders") ?: continue
            val base = LocalDateTime.parse(item.getString("start")).toLocalDate(); val from = maxOf(base, LocalDate.now().minusDays(1))
            for (index in 0 until offsets.length()) {
                val offset = offsets.getInt(index)
                val range = if (item.optString("repeat", "none") == "none") listOf(base) else (0L..370L).map { from.plusDays(it) }
                for (date in range) {
                    val o = Occurrences.on(item, date) ?: continue
                    if (o.done) continue
                    val reference = if (item.optBoolean("allDay")) date.atTime(9, 0) else o.start
                    val whenMs = reference.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli() - offset * 60000L
                    if (whenMs <= now) continue
                    desired.add(Scheduled(whenMs, item.getString("id"), offset, date.toString())); break
                }
            }
        }
        // Stay below Android's per-UID alarm limit; every delivery refills this queue.
        val queue = desired.sortedBy { it.whenMs }.take(400)
        val keys = queue.map { "${it.id}|${it.offset}" }.toSet()
        val previous = Storage.prefs(context).getStringSet("scheduledKeys", emptySet()) ?: emptySet()
        for (key in previous - keys) {
            val parts = key.split('|')
            if (parts.size == 2) context.getSystemService(AlarmManager::class.java).cancel(pending(context, parts[0], parts[1].toInt()))
        }
        for (alarm in queue) {
            set(context, alarm.whenMs, pending(context, alarm.id, alarm.offset, alarm.date))
        }
        Storage.prefs(context).edit().putStringSet("scheduledKeys", keys).apply()
    }
    fun test(context: Context) { set(context, System.currentTimeMillis() + 10000, pending(context, "__test__", 0)) }
    fun notify(context: Context, title: String, text: String, id: String) {
        channels(context)
        val intent = Intent(context, MainActivity::class.java).putExtra("itemId", id).setData(Uri.parse("dayline://item/$id")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val open = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_notification).setContentTitle(title).setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text)).setContentIntent(open).setAutoCancel(true).setColor(Color.rgb(145, 182, 92))
            .setCategory(Notification.CATEGORY_REMINDER).setVisibility(Notification.VISIBILITY_PRIVATE).build()
        try { context.getSystemService(NotificationManager::class.java).notify(id, 1, notification) } catch (_: SecurityException) { }
    }
}
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("itemId") ?: return
        if (id == "__test__") { Reminders.notify(context, "Dayline работает", "Напоминания о ваших планах будут появляться здесь.", id); return }
        val item = Storage.items(context).firstOrNull { it.getString("id") == id } ?: return
        val date = intent.getStringExtra("occurrence")?.let { LocalDate.parse(it) } ?: return
        val o = Occurrences.on(item, date)
        if (o != null && !o.done) Reminders.notify(context, item.getString("title"), "${date.format(DateTimeFormatter.ofPattern("d MMMM", Locale.forLanguageTag("ru")))} · ${o.time}\n${item.optString("note")}".trim(), id)
        Reminders.schedule(context); AgendaWidget.updateAll(context)
    }
}
class RestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) { Reminders.cancel(context, Storage.items(context)); Reminders.schedule(context); AgendaWidget.updateAll(context) }
}
