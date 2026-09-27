import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'model.dart';
import 'store.dart';
import 'editor.dart';

const accent = Color(0xFFC5F27C);
const palette = [
  Color(0xFFB9E879),
  Color(0xFF92B9FF),
  Color(0xFFC6A8FA),
  Color(0xFFFFB480),
  Color(0xFFF298B1),
];
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(DaylineApp(store: PlannerStore()));
}

class DaylineApp extends StatefulWidget {
  final PlannerStore store;
  const DaylineApp({super.key, required this.store});
  @override
  State<DaylineApp> createState() => _DaylineAppState();
}

class _DaylineAppState extends State<DaylineApp> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.store.initialize());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final dark = widget.store.dark;
      final scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF87B648),
        brightness: dark ? Brightness.dark : Brightness.light,
        primary: dark ? accent : const Color(0xFF486C21),
        surface: dark ? const Color(0xFF121A18) : const Color(0xFFF7F9F2),
      );
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Dayline',
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: scheme,
          scaffoldBackgroundColor: scheme.surface,
          appBarTheme: const AppBarTheme(
            centerTitle: false,
            scrolledUnderElevation: 0,
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: scheme.surfaceContainer,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
          ),
          cardTheme: CardThemeData(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
          ),
          navigationBarTheme: NavigationBarThemeData(
            backgroundColor: scheme.surface,
            indicatorColor: scheme.primaryContainer,
          ),
        ),
        home: PlannerHome(store: widget.store),
      );
    },
  );
}

class PlannerHome extends StatefulWidget {
  final PlannerStore store;
  const PlannerHome({super.key, required this.store});
  @override
  State<PlannerHome> createState() => _PlannerHomeState();
}

class _PlannerHomeState extends State<PlannerHome> with WidgetsBindingObserver {
  int page = 0, view = 0, filter = 0;
  DateTime selected = dayOnly(DateTime.now());
  String query = '';
  bool editorOpen = false;
  Timer? ticker;
  PlannerStore get store => widget.store;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.addListener(onStore);
    ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void onStore() {
    if (editorOpen || !store.ready) return;
    if (store.launchNew || store.launchId != null) {
      final id = store.launchId;
      final isNew = store.launchNew;
      store.launchId = null;
      store.launchNew = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final item = store.items.where((i) => i.id == id).firstOrNull;
        if (isNew || item != null) openEditor(item: item);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        store.refreshPermissions().then((_) async {
          await store.sync();
          await store.refreshFolders();
        }),
      );
    }
  }

  @override
  void dispose() {
    ticker?.cancel();
    store.removeListener(onStore);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> openEditor({PlanItem? item, bool task = true}) async {
    editorOpen = true;
    store.editing = true;
    final saved = store.isDesktop
        ? await showDialog<PlanItem>(
            context: context,
            barrierDismissible: false,
            builder: (_) => Dialog(
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: 700,
                height: MediaQuery.sizeOf(context).height - 64,
                child: ItemEditor(
                  store: store,
                  day: selected,
                  item: item,
                  task: task,
                ),
              ),
            ),
          )
        : await Navigator.of(context).push<PlanItem>(
            MaterialPageRoute<PlanItem>(
              builder: (_) => ItemEditor(
                store: store,
                day: selected,
                item: item,
                task: task,
              ),
            ),
          );
    editorOpen = false;
    store.editing = false;
    if (saved != null && mounted) {
      setState(() {
        selected = dayOnly(saved.start);
        if (!saved.task) page = 0;
      });
    }
    unawaited(store.sync());
    onStore();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    if (store.isDesktop && MediaQuery.sizeOf(context).width >= 900) {
      return desktopShell();
    }
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: c.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.view_day_rounded, color: c.onPrimary, size: 21),
            ),
            const SizedBox(width: 10),
            const Flexible(
              child: Text(
                'dayline',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                  fontSize: 27,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (page != 2)
            IconButton(
              tooltip: 'Сегодня',
              onPressed: () =>
                  setState(() => selected = dayOnly(DateTime.now())),
              icon: const Icon(Icons.today_outlined),
            ),
          IconButton(
            tooltip: 'Синхронизация с Obsidian',
            onPressed: store.connected
                ? store.sync
                : () => setState(() => page = 2),
            icon: store.busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: !store.ready
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (store.error.isNotEmpty)
                  Material(
                    color: c.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              store.error,
                              style: TextStyle(color: c.onErrorContainer),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Подробнее',
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('Сообщение'),
                                content: SingleChildScrollView(
                                  child: Text(store.error),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('Закрыть'),
                                  ),
                                ],
                              ),
                            ),
                            icon: const Icon(Icons.info_outline),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: switch (page) {
                    0 => calendarPage(),
                    1 => tasksPage(),
                    _ => settingsPage(),
                  },
                ),
              ],
            ),
      floatingActionButton: page == 2
          ? null
          : FloatingActionButton.extended(
              onPressed: store.busy ? null : () => openEditor(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Создать'),
              backgroundColor: c.primary,
              foregroundColor: c.onPrimary,
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: page,
        onDestinationSelected: (i) => setState(() => page = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'Календарь',
          ),
          NavigationDestination(
            icon: Icon(Icons.check_circle_outline),
            selectedIcon: Icon(Icons.check_circle),
            label: 'Задачи',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_rounded),
            label: 'Настройки',
          ),
        ],
      ),
    );
  }

  Widget desktopShell() {
    final c = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
          if (!store.busy && !editorOpen) openEditor();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 210,
                child: Material(
                  color: c.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 28, 16, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.view_day_rounded,
                              color: c.primary,
                              size: 30,
                            ),
                            const SizedBox(width: 10),
                            const Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'dayline',
                                  style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                        FilledButton.icon(
                          onPressed: store.busy || !store.ready
                              ? null
                              : () => openEditor(),
                          icon: const Icon(Icons.add),
                          label: const Text('Создать'),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Ctrl + N',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            color: c.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 28),
                        for (var n = 0; n < 3; n++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              selected: page == n,
                              selectedTileColor: c.secondaryContainer,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              leading: Icon(
                                [
                                  Icons.calendar_month_outlined,
                                  Icons.check_circle_outline,
                                  Icons.tune,
                                ][n],
                              ),
                              title: Text(
                                ['Календарь', 'Задачи', 'Настройки'][n],
                              ),
                              onTap: () => setState(() => page = n),
                            ),
                          ),
                        const Spacer(),
                        Icon(
                          store.connected
                              ? Icons.folder_open
                              : Icons.folder_off_outlined,
                          color: c.primary,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          store.connected
                              ? 'Obsidian подключён'
                              : 'Подключите Obsidian\nв настройках',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          store.syncStatus,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            color: c.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Scaffold(
                  appBar: AppBar(
                    title: Text(
                      ['Ваш календарь', 'Все задачи', 'Настройки'][page],
                    ),
                    actions: [
                      TextButton.icon(
                        onPressed: () => setState(() {
                          selected = dayOnly(DateTime.now());
                          page = 0;
                        }),
                        icon: const Icon(Icons.today_outlined),
                        label: const Text('Сегодня'),
                      ),
                      IconButton(
                        tooltip: 'Синхронизация с Obsidian',
                        onPressed: store.busy
                            ? null
                            : store.connected
                            ? store.sync
                            : () => setState(() => page = 2),
                        icon: const Icon(Icons.sync),
                      ),
                      IconButton(
                        tooltip: 'Свернуть в трей',
                        onPressed: () => store.action('hideWindow'),
                        icon: const Icon(Icons.minimize),
                      ),
                      const SizedBox(width: 16),
                    ],
                  ),
                  body: !store.ready
                      ? const Center(child: CircularProgressIndicator())
                      : Column(
                          children: [
                            if (store.error.isNotEmpty)
                              Material(
                                color: c.errorContainer,
                                child: ListTile(
                                  leading: const Icon(Icons.error_outline),
                                  title: SelectableText(store.error),
                                ),
                              ),
                            Expanded(
                              child: page == 0
                                  ? desktopCalendar()
                                  : Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 900,
                                        ),
                                        child: page == 1
                                            ? tasksPage()
                                            : settingsPage(),
                                      ),
                                    ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget desktopCalendar() {
    final all = agenda(
      store.items,
      selected,
      DateTime(selected.year, selected.month, selected.day + 1),
    );
    final active = all.where((o) => !o.done).toList();
    final c = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 24, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 330,
            child: ListView(
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: monthGrid(),
                  ),
                ),
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.diamond_outlined, color: c.primary),
                        const SizedBox(height: 12),
                        const Text(
                          'Планы рядом с заметками',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          store.connected
                              ? 'Общий Dayline.md связывает календарь с вашим хранилищем Obsidian.'
                              : 'Выберите папку Obsidian в настройках, чтобы видеть один план на телефоне и компьютере.',
                          style: TextStyle(
                            color: c.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: ListView(
              children: [
                Text(
                  '${selected.day} ${months[selected.month - 1]}',
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${weekdays[selected.weekday - 1]} · ${all.length} дел',
                  style: TextStyle(color: c.onSurfaceVariant),
                ),
                const SizedBox(height: 18),
                if (active.isNotEmpty) focusCard(active),
                if (active.isNotEmpty) const SizedBox(height: 22),
                const Text(
                  'План на день',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                if (all.isEmpty)
                  empty(
                    Icons.wb_sunny_outlined,
                    'Место для ваших планов',
                    'Создайте задачу или событие на выбранную дату.',
                  ),
                for (final o in all)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: itemCard(o, timeline: true),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget calendarPage() {
    final all = agenda(
      store.items,
      selected,
      DateTime(selected.year, selected.month, selected.day + 1),
    );
    final active = all.where((o) => !o.done).toList();
    final done = all.where((o) => o.item.task && o.done).length;
    final tasks = all.where((o) => o.item.task).length;
    final c = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 100),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${selected.day} ${months[selected.month - 1]}',
                    style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.3,
                    ),
                  ),
                  Text(
                    '${['Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье'][selected.weekday - 1]} · ${selected.year}',
                    style: TextStyle(color: c.onSurfaceVariant, fontSize: 14),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: c.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                '$done / $tasks\nзадач',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        SegmentedButton<int>(
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 0, label: Text('Неделя')),
            ButtonSegment(value: 1, label: Text('Месяц')),
            ButtonSegment(value: 2, label: Text('День')),
          ],
          selected: {view},
          onSelectionChanged: (v) => setState(() => view = v.first),
        ),
        const SizedBox(height: 14),
        if (view == 1)
          monthGrid()
        else if (view == 0)
          weekStrip()
        else
          dayNavigation(),
        const SizedBox(height: 22),
        if (active.isNotEmpty) focusCard(active),
        if (active.isNotEmpty) const SizedBox(height: 24),
        Row(
          children: [
            const Expanded(
              child: Text(
                'План на день',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${all.length} дел',
              style: TextStyle(color: c.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (all.isEmpty)
          empty(
            Icons.wb_sunny_outlined,
            'Место для ваших планов',
            'Добавьте событие с интервалом времени\nили задачу на этот день.',
          ),
        ...all.map(
          (o) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: itemCard(o, timeline: view == 2),
          ),
        ),
      ],
    );
  }

  Widget focusCard(List<Occurrence> active) {
    final now = DateTime.now();
    final o =
        active.where((o) => o.end.isAfter(now)).firstOrNull ?? active.first;
    final c = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Ближайшее: ${o.item.title}',
      child: InkWell(
        onTap: () => openEditor(item: o.item),
        borderRadius: BorderRadius.circular(26),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: c.primaryContainer,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 20,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.north_east_rounded,
                        size: 18,
                        color: c.onPrimaryContainer,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        'В ФОКУСЕ',
                        style: TextStyle(
                          color: c.onPrimaryContainer,
                          fontSize: 11,
                          letterSpacing: 1.8,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    o.time,
                    style: TextStyle(
                      color: c.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                o.item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.onPrimaryContainer,
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.5,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(
                    o.item.task
                        ? Icons.check_circle_outline
                        : Icons.event_outlined,
                    size: 15,
                    color: c.onPrimaryContainer,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      o.item.category,
                      style: TextStyle(color: c.onPrimaryContainer),
                    ),
                  ),
                  if (o.item.reminders.isNotEmpty)
                    Icon(
                      Icons.notifications_active_outlined,
                      size: 18,
                      color: c.onPrimaryContainer,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget dayNavigation() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      IconButton(
        tooltip: 'Предыдущий день',
        onPressed: () => setState(
          () => selected = DateTime(
            selected.year,
            selected.month,
            selected.day - 1,
          ),
        ),
        icon: const Icon(Icons.chevron_left),
      ),
      const Text('Расписание по времени'),
      IconButton(
        tooltip: 'Следующий день',
        onPressed: () => setState(
          () => selected = DateTime(
            selected.year,
            selected.month,
            selected.day + 1,
          ),
        ),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );
  Widget weekStrip() {
    final monday = DateTime(
      selected.year,
      selected.month,
      selected.day - selected.weekday + 1,
    );
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Предыдущая неделя',
              onPressed: () => setState(
                () => selected = DateTime(
                  selected.year,
                  selected.month,
                  selected.day - 7,
                ),
              ),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '${monthNames[selected.month - 1]} ${selected.year}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Следующая неделя',
              onPressed: () => setState(
                () => selected = DateTime(
                  selected.year,
                  selected.month,
                  selected.day + 7,
                ),
              ),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Row(
          children: List.generate(
            7,
            (i) => Expanded(
              child: dateCell(
                DateTime(monday.year, monday.month, monday.day + i),
                weekday: true,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget dateCell(DateTime d, {bool weekday = false}) {
    final c = Theme.of(context).colorScheme;
    final chosen = dayOnly(d) == selected,
        today = dayOnly(d) == dayOnly(DateTime.now());
    final has = store.items.any((i) => i.occursOn(d));
    return Padding(
      padding: const EdgeInsets.all(2),
      child: InkWell(
        onTap: () => setState(() => selected = d),
        onLongPress: () {
          setState(() => selected = d);
          openEditor();
        },
        borderRadius: BorderRadius.circular(18),
        child: Container(
          constraints: BoxConstraints(minHeight: weekday ? 82 : 48),
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: chosen ? c.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: today && !chosen ? Border.all(color: c.primary) : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (weekday)
                Text(
                  weekdays[d.weekday - 1],
                  style: TextStyle(
                    fontSize: 11,
                    color: chosen ? c.onPrimary : c.onSurfaceVariant,
                  ),
                ),
              if (weekday) const SizedBox(height: 8),
              Text(
                '${d.day}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: chosen ? c.onPrimary : c.onSurface,
                ),
              ),
              const SizedBox(height: 5),
              Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: has
                      ? (chosen ? c.onPrimary : c.primary)
                      : Colors.transparent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget monthGrid() {
    final first = DateTime(selected.year, selected.month, 1),
        count = DateTime(selected.year, selected.month + 1, 0).day;
    final offset = first.weekday - 1, rows = ((offset + count) / 7).ceil();
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Предыдущий месяц',
              onPressed: () => setState(
                () => selected = DateTime(selected.year, selected.month - 1, 1),
              ),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '${monthNames[selected.month - 1]} ${selected.year}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: 'Следующий месяц',
              onPressed: () => setState(
                () => selected = DateTime(selected.year, selected.month + 1, 1),
              ),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Row(
          children: weekdays
              .map(
                (d) => Expanded(
                  child: Text(
                    d,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              )
              .toList(),
        ),
        ...List.generate(
          rows,
          (r) => Row(
            children: List.generate(7, (i) {
              final n = r * 7 + i - offset + 1;
              return Expanded(
                child: n < 1 || n > count
                    ? const SizedBox(height: 56)
                    : dateCell(DateTime(selected.year, selected.month, n)),
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget itemCard(Occurrence o, {bool timeline = false}) {
    final i = o.item,
        c = Theme.of(context).colorScheme,
        color = palette[i.color];
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => openEditor(item: i),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 16, 12),
          child: Row(
            children: [
              if (timeline)
                SizedBox(
                  width: 54,
                  child: Text(
                    i.allDay ? 'ДЕНЬ' : clockText(o.start),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (i.task)
                Checkbox(
                  value: o.done,
                  onChanged: store.busy ? null : (_) => store.toggle(o),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Icon(Icons.event_rounded, color: color, size: 21),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      i.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                        decoration: o.done ? TextDecoration.lineThrough : null,
                        color: o.done ? c.onSurfaceVariant : c.onSurface,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          o.time,
                          style: TextStyle(
                            color: c.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          '· ${i.category}',
                          style: TextStyle(
                            color: c.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        if (i.repeat != 'none')
                          Icon(
                            Icons.repeat_rounded,
                            size: 14,
                            color: c.onSurfaceVariant,
                          ),
                        if (i.reminders.isNotEmpty)
                          Icon(
                            Icons.notifications_none,
                            size: 14,
                            color: c.onSurfaceVariant,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 4,
                height: 38,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              if (i.priority == 2)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.keyboard_double_arrow_up_rounded,
                    size: 18,
                    color: color,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget tasksPage() {
    final now = dayOnly(DateTime.now());
    final occurrences = <Occurrence>[];
    for (final i in store.items.where((i) => i.task)) {
      if (i.repeat == 'none') {
        occurrences.add(i.occurrence(i.start)!);
      } else {
        final upcoming = i.between(
          now,
          DateTime(now.year, now.month, now.day + 32),
        );
        if (upcoming.isNotEmpty) {
          occurrences.add(
            upcoming.firstWhere((o) => !o.done, orElse: () => upcoming.first),
          );
        }
      }
    }
    final list = occurrences.where((o) {
      final text = '${o.item.title} ${o.item.note} ${o.item.category}'
          .toLowerCase();
      return text.contains(query.toLowerCase()) &&
          switch (filter) {
            1 => !o.done && o.end.isBefore(DateTime.now()),
            2 => o.done,
            _ => !o.done,
          };
    }).toList()..sort((a, b) => a.start.compareTo(b.start));
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
      children: [
        const Text(
          'Все под контролем',
          style: TextStyle(
            fontSize: 29,
            fontWeight: FontWeight.w700,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Задачи, к которым хочется вернуться.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 22),
        TextField(
          onChanged: (v) => setState(() => query = v),
          decoration: const InputDecoration(
            hintText: 'Поиск по задачам и категориям',
            prefixIcon: Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          children: List.generate(
            3,
            (i) => ChoiceChip(
              label: Text(['В работе', 'Просрочены', 'Готово'][i]),
              selected: filter == i,
              onSelected: (_) => setState(() => filter = i),
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (list.isEmpty)
          empty(
            Icons.task_alt_rounded,
            'Здесь пока пусто',
            filter == 2
                ? 'Выполненные задачи появятся здесь.'
                : 'Создайте задачу или измените фильтр.',
          ),
        ...list.map(
          (o) => Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 8),
                  child: Text(
                    '${o.start.day} ${months[o.start.month - 1]} · ${o.start.year}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                itemCard(o),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget empty(IconData icon, String title, String subtitle) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Column(
      children: [
        Icon(icon, size: 42, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
  Widget settingsPage() {
    final c = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        const Text(
          'Ваш ритм. Ваши данные.',
          style: TextStyle(
            fontSize: 29,
            fontWeight: FontWeight.w700,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 22),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.diamond_outlined, color: c.primary),
                    const SizedBox(width: 10),
                    const Text(
                      'Obsidian',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    if (store.connected) const Icon(Icons.check_circle_outline),
                  ],
                ),
                const SizedBox(height: 14),
                const Text(
                  'Одна папка — общий план',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Выберите корневую папку хранилища Obsidian. События и задачи сохраняются в Dayline.md. Категории выбираются из папок и вложенных папок хранилища. Изменения читаются при открытии приложения и каждые 30 секунд, пока оно открыто.',
                  style: TextStyle(height: 1.5),
                ),
                const SizedBox(height: 12),
                Text(
                  store.syncStatus,
                  style: TextStyle(color: c.primary, fontSize: 12),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: store.busy
                      ? null
                      : store.connected
                      ? store.sync
                      : store.connect,
                  icon: Icon(store.connected ? Icons.sync : Icons.folder_open),
                  label: Text(
                    store.connected ? 'Синхронизировать' : 'Подключить папку',
                  ),
                ),
                if (store.connected)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(
                      'Категории из Obsidian: ${store.vaultFolders.length}',
                    ),
                    subtitle: Text(
                      store.folderError.isNotEmpty
                          ? store.folderError
                          : 'Папки и вложенные папки хранилища',
                    ),
                    trailing: store.loadingFolders
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    onTap: store.loadingFolders ? null : store.refreshFolders,
                  ),
                if (store.connected)
                  if (store.isDesktop) ...[
                    SelectableText(
                      store.permissions['vaultPath'] as String? ?? '',
                      style: TextStyle(fontSize: 12, color: c.onSurfaceVariant),
                    ),
                    TextButton.icon(
                      onPressed: () => store.action('openVault'),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Открыть папку в Проводнике'),
                    ),
                  ],
                if (store.connected)
                  TextButton(
                    onPressed: store.busy ? null : store.disconnect,
                    child: const Text('Отключить папку'),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Column(
            children: [
              if (!store.isDesktop) ...[
                ListTile(
                  leading: const Icon(Icons.widgets_outlined),
                  title: const Text('Виджет ближайших дел'),
                  subtitle: const Text('Список с прокруткой на главном экране'),
                  trailing: const Icon(Icons.add_circle_outline),
                  onTap: () => store.action('pinWidget'),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Уведомления'),
                  subtitle: Text(
                    store.permissions['notifications'] == true
                        ? 'Разрешены'
                        : 'Разрешите, чтобы получать напоминания',
                  ),
                  trailing: Icon(
                    store.permissions['notifications'] == true
                        ? Icons.check
                        : Icons.chevron_right,
                  ),
                  onTap: () => store.action('requestNotifications'),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.alarm_rounded),
                  title: const Text('Точные напоминания'),
                  subtitle: Text(
                    store.permissions['exact'] == true
                        ? 'Разрешены'
                        : 'Нужен доступ «Будильники и напоминания»',
                  ),
                  trailing: Icon(
                    store.permissions['exact'] == true
                        ? Icons.check
                        : Icons.chevron_right,
                  ),
                  onTap: () => store.action('requestExact'),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
              ] else ...[
                SwitchListTile(
                  secondary: const Icon(Icons.widgets_outlined),
                  title: const Text('Виджет на рабочем столе'),
                  subtitle: const Text(
                    'Ближайшие задачи и события на 30 дней. Работает и при свёрнутом календаре.',
                  ),
                  value: store.permissions['widgetEnabled'] == true,
                  onChanged: (value) => store.action(
                    value ? 'showDesktopWidget' : 'hideDesktopWidget',
                  ),
                ),
                const ListTile(
                  leading: Icon(Icons.desktop_windows_outlined),
                  title: Text('Напоминания Windows'),
                  subtitle: Text(
                    'Работают, пока Dayline открыт или находится в трее. Windows может скрывать уведомления в режиме «Фокусировка внимания».',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.minimize),
                  title: const Text('Свернуть в трей'),
                  subtitle: const Text(
                    'Закрытие окна также оставляет приложение в трее',
                  ),
                  onTap: () => store.action('hideWindow'),
                ),
              ],
              ListTile(
                leading: const Icon(Icons.notification_add_outlined),
                title: const Text('Проверить уведомление'),
                subtitle: const Text('Тестовое напоминание через 10 секунд'),
                onTap: () async {
                  await store.action('testNotification');
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Проверка запланирована через 10 секунд'),
                      ),
                    );
                  }
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined),
            title: const Text('Тёмная тема'),
            value: store.dark,
            onChanged: store.setDark,
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Dayline 1.1.1',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          store.isDesktop
              ? 'Данные хранятся на компьютере. Для обмена с телефоном синхронизируйте папку Obsidian вашим способом, например через Syncthing. На обоих устройствах выберите копию одного хранилища.\n\nОбмен через Dayline.md происходит каждые 30 секунд, в том числе в трее. После полного выхода из приложения синхронизация и напоминания останавливаются.'
              : 'Данные хранятся на устройстве. Нет аккаунтов, рекламы и Google Calendar. Для обмена между устройствами используйте синхронизацию самого хранилища Obsidian.\n\nВиджет показывает локальные данные; после изменений в Obsidian откройте Dayline. Свайп приложения из недавних не отключает напоминания. Принудительная остановка в настройках Android отключает их до следующего запуска.',
          style: TextStyle(
            color: c.onSurfaceVariant,
            height: 1.5,
            fontSize: 13,
          ),
        ),
        if (store.isDesktop) ...[
          const SizedBox(height: 16),
          SelectableText(
            'Локальные данные: ${store.permissions['dataPath'] ?? ''}',
            style: TextStyle(fontSize: 12, color: c.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: store.busy ? null : () => store.action('exitApp'),
            icon: const Icon(Icons.exit_to_app),
            label: const Text('Завершить работу Dayline'),
          ),
        ],
      ],
    );
  }
}
