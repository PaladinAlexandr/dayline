package app.dayline.dayline
import android.app.*
import android.appwidget.*
import android.content.*
import android.net.Uri
import android.os.Bundle
import android.widget.RemoteViews
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

class AgendaWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { updateAll(context) }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) { updateAll(context) }
    override fun onReceive(context: Context, intent: Intent) { super.onReceive(context, intent); if (intent.action == "app.dayline.WIDGET_REFRESH") updateAll(context) }
    companion object {
        private fun open(context: Context, add: Boolean): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).putExtra("new", add).setData(Uri.parse(if (add) "dayline://new" else "dayline://home")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context); val ids = manager.getAppWidgetIds(ComponentName(context, AgendaWidget::class.java))
            if (ids.isEmpty()) return
            val upcoming = Occurrences.upcoming(context); val ru = Locale.forLanguageTag("ru")
            for (id in ids) {
                val views = RemoteViews(context.packageName, R.layout.agenda_widget)
                views.setTextViewText(R.id.widget_date, LocalDate.now().format(DateTimeFormatter.ofPattern("EEEE, d MMMM", ru)))
                views.setOnClickPendingIntent(R.id.widget_header, open(context, false)); views.setOnClickPendingIntent(R.id.widget_add, open(context, true)); views.setEmptyView(R.id.widget_list, R.id.widget_empty)
                val template = Intent(context, MainActivity::class.java).setAction("app.dayline.OPEN_ITEM").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                views.setPendingIntentTemplate(R.id.widget_list, PendingIntent.getActivity(context, id, template, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE))
                val rows = RemoteViews.RemoteCollectionItems.Builder().setHasStableIds(true).setViewTypeCount(1)
                for (o in upcoming) {
                    val item = o.item; val row = RemoteViews(context.packageName, R.layout.agenda_row)
                    row.setTextViewText(R.id.row_title, item.getString("title"))
                    val date = o.start.toLocalDate(); val dateText = when (date) { LocalDate.now() -> "Сегодня"; LocalDate.now().plusDays(1) -> "Завтра"; else -> date.format(DateTimeFormatter.ofPattern("d MMM", ru)) }
                    row.setTextViewText(R.id.row_time, "$dateText · ${o.time}${if (o.endMillis < System.currentTimeMillis()) " · просрочено" else ""}")
                    row.setTextViewText(R.id.row_type, if (item.optBoolean("task")) "○" else "▣")
                    val colors = intArrayOf(0xFFB9E879.toInt(), 0xFF92B9FF.toInt(), 0xFFC6A8FA.toInt(), 0xFFFFB480.toInt(), 0xFFF298B1.toInt())
                    row.setTextColor(R.id.row_type, colors[item.optInt("color", 0).coerceIn(0, 4)])
                    row.setOnClickFillInIntent(R.id.row_root, Intent().putExtra("itemId", item.getString("id")))
                    val stableId = (item.getString("id") + date.toString()).fold(1125899906842597L) { hash, ch -> 31 * hash + ch.code }
                    rows.addItem(stableId, row)
                }
                views.setRemoteAdapter(R.id.widget_list, rows.build()); manager.updateAppWidget(id, views)
            }
            val now = System.currentTimeMillis(); val midnight = LocalDate.now().plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
            val boundary = upcoming.map { it.endMillis + 1000 }.filter { it > now }.minOrNull() ?: midnight
            val alarm = Intent(context, AgendaWidget::class.java).setAction("app.dayline.WIDGET_REFRESH")
            val pending = PendingIntent.getBroadcast(context, 94, alarm, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            context.getSystemService(AlarmManager::class.java).set(AlarmManager.RTC, minOf(midnight, boundary, now + 1800000), pending)
        }
    }
}
