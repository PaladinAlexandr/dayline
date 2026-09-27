import 'dart:async';
import 'package:flutter/material.dart';
import 'model.dart';
import 'store.dart';

class ItemEditor extends StatefulWidget {
  final PlannerStore store;
  final DateTime day;
  final PlanItem? item;
  final bool task;
  const ItemEditor({
    super.key,
    required this.store,
    required this.day,
    this.item,
    this.task = true,
  });
  @override
  State<ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<ItemEditor> {
  final form = GlobalKey<FormState>();
  late TextEditingController title, note, category;
  late DateTime start, end;
  late bool task, allDay;
  late int priority, color;
  late String repeat;
  late Set<int> reminders;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    final i = widget.item;
    title = TextEditingController(text: i?.title ?? '');
    note = TextEditingController(text: i?.note ?? '');
    category = TextEditingController(
      text:
          i?.category ??
          (widget.store.connected &&
                  !widget.store.vaultFolders.contains('Личное')
              ? 'Без категории'
              : 'Личное'),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.store.refreshFolders());
    });
    final now = DateTime.now();
    final h = dayOnly(widget.day) == dayOnly(now)
        ? (now.hour + 1).clamp(0, 23)
        : 9;
    start =
        i?.start ??
        DateTime(widget.day.year, widget.day.month, widget.day.day, h);
    end = i?.end ?? start.add(const Duration(hours: 1));
    task = i?.task ?? widget.task;
    allDay = i?.allDay ?? false;
    priority = i?.priority ?? 1;
    color = i?.color ?? 0;
    repeat = i?.repeat ?? 'none';
    reminders = (i?.reminders ?? [10]).toSet();
    if (allDay && i != null) end = DateTime(end.year, end.month, end.day - 1);
  }

  @override
  void dispose() {
    title.dispose();
    note.dispose();
    category.dispose();
    super.dispose();
  }

  Future<void> pickDate(bool isEnd) async {
    final old = isEnd ? end : start;
    final d = await showDatePicker(
      context: context,
      initialDate: old,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() {
      final selected = DateTime(d.year, d.month, d.day, old.hour, old.minute);
      if (isEnd) {
        end = selected;
      } else {
        final duration = end.difference(start);
        start = selected;
        end = start.add(duration);
      }
    });
  }

  Future<void> pickTime(bool isEnd) async {
    final old = isEnd ? end : start;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(old),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (t == null) return;
    setState(() {
      final selected = DateTime(old.year, old.month, old.day, t.hour, t.minute);
      if (isEnd) {
        end = selected;
      } else {
        final duration = end.difference(start);
        start = selected;
        end = start.add(duration);
      }
    });
  }

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    final s = allDay ? dayOnly(start) : start;
    final e = allDay ? DateTime(end.year, end.month, end.day + 1) : end;
    if (!e.isAfter(s)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Окончание должно быть позже начала')),
      );
      return;
    }
    if (e.difference(s).inDays > 31) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Максимальная длительность — 31 день')),
      );
      return;
    }
    if (repeat != 'none' && e.difference(s) > const Duration(days: 1)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Для повторов выберите интервал не длиннее суток'),
        ),
      );
      return;
    }
    setState(() => saving = true);
    final i = PlanItem(
      id: widget.item?.id ?? newId(),
      title: title.text.trim(),
      start: s,
      end: e,
      task: task,
      allDay: allDay,
      note: note.text.trim(),
      category: category.text.trim().isEmpty ? 'Личное' : category.text.trim(),
      repeat: repeat,
      priority: priority,
      color: color,
      reminders: reminders.toList()..sort(),
      completed: task ? widget.item?.completed ?? [] : [],
    );
    final ok = await widget.store.save(i);
    if (mounted) {
      if (ok) {
        Navigator.pop(context, i);
      } else {
        setState(() => saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.store.error.isEmpty
                  ? 'Идёт синхронизация. Повторите сохранение.'
                  : widget.store.error,
            ),
          ),
        );
      }
    }
  }

  Future<void> pickCategory() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) =>
          FolderPicker(store: widget.store, selected: category.text),
    );
    if (selected != null && mounted) setState(() => category.text = selected);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: widget.store.isDesktop
            ? IconButton(
                tooltip: 'Отмена',
                onPressed: saving ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              )
            : null,
        title: Text(widget.item == null ? 'Новое дело' : 'Редактирование'),
        actions: [
          if (widget.item != null)
            IconButton(
              tooltip: 'Удалить',
              onPressed: saving
                  ? null
                  : () async {
                      final yes = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(
                            repeat == 'none'
                                ? 'Удалить запись?'
                                : 'Удалить все повторы?',
                          ),
                          content: Text(title.text),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Отмена'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Удалить'),
                            ),
                          ],
                        ),
                      );
                      if (yes == true) {
                        final ok = await widget.store.delete(widget.item!.id);
                        if (ok && context.mounted) Navigator.pop(context);
                      }
                    },
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: FilledButton(
            onPressed: saving ? null : save,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(54),
            ),
            child: Text(
              saving ? 'Сохранение…' : 'Сохранить',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
      body: Form(
        key: form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            SegmentedButton<bool>(
              expandedInsets: EdgeInsets.zero,
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text('Задача'),
                  icon: Icon(Icons.check_circle_outline),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('Событие'),
                  icon: Icon(Icons.event_outlined),
                ),
              ],
              selected: {task},
              onSelectionChanged: (v) => setState(() => task = v.first),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: title,
              autofocus: widget.item == null,
              maxLength: 160,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                hintText: 'Что запланируем?',
                counterText: '',
              ),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Введите название' : null,
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Весь день'),
              value: allDay,
              onChanged: (v) => setState(() {
                allDay = v;
                if (v) {
                  start = dayOnly(start);
                  end = dayOnly(start);
                } else {
                  start = DateTime(start.year, start.month, start.day, 9);
                  end = start.add(const Duration(hours: 1));
                }
              }),
            ),
            timingRow('Начало', start, false),
            const SizedBox(height: 10),
            timingRow(allDay ? 'Последний день' : 'Окончание', end, true),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: repeat,
              decoration: const InputDecoration(
                labelText: 'Повтор',
                prefixIcon: Icon(Icons.repeat),
              ),
              items: repeatNames.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: (v) => setState(() => repeat = v!),
            ),
            if (widget.item != null && repeat != 'none')
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Изменения применяются ко всей серии.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            const SizedBox(height: 22),
            const Text(
              'Напоминания',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final n in [0, 5, 10, 30, 60, 1440])
                  FilterChip(
                    label: Text(
                      n == 0
                          ? 'В начале'
                          : n == 60
                          ? 'За час'
                          : n == 1440
                          ? 'За день'
                          : 'За $n мин',
                    ),
                    selected: reminders.contains(n),
                    onSelected: (v) => setState(() {
                      if (v) {
                        reminders.add(n);
                      } else {
                        reminders.remove(n);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              allDay
                  ? 'Для дел на весь день точка отсчёта — 09:00.'
                  : 'Можно выбрать несколько напоминаний.',
              style: TextStyle(fontSize: 12, color: c.onSurfaceVariant),
            ),
            const SizedBox(height: 22),
            TextFormField(
              controller: category,
              readOnly: widget.store.connected,
              onTap: widget.store.connected ? pickCategory : null,
              maxLength: widget.store.connected ? null : 120,
              maxLines: 2,
              minLines: 1,
              decoration: InputDecoration(
                labelText: widget.store.connected
                    ? 'Категория — папка Obsidian'
                    : 'Категория / проект',
                prefixIcon: const Icon(Icons.folder_outlined),
                suffixIcon: widget.store.connected
                    ? const Icon(Icons.expand_more)
                    : null,
                helperText: widget.store.connected
                    ? 'Выберите папку из хранилища'
                    : null,
                counterText: '',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: priority,
              decoration: const InputDecoration(
                labelText: 'Приоритет',
                prefixIcon: Icon(Icons.flag_outlined),
              ),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Низкий')),
                DropdownMenuItem(value: 1, child: Text('Обычный')),
                DropdownMenuItem(value: 2, child: Text('Высокий')),
              ],
              onChanged: (v) => setState(() => priority = v!),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 12,
              children: List.generate(
                5,
                (i) => Semantics(
                  label: 'Цвет ${i + 1}',
                  selected: color == i,
                  child: InkWell(
                    onTap: () => setState(() => color = i),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: [
                          const Color(0xFFB9E879),
                          const Color(0xFF92B9FF),
                          const Color(0xFFC6A8FA),
                          const Color(0xFFFFB480),
                          const Color(0xFFF298B1),
                        ][i],
                        shape: BoxShape.circle,
                      ),
                      child: color == i
                          ? const Icon(Icons.check, color: Color(0xFF172117))
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: note,
              minLines: 3,
              maxLines: 8,
              maxLength: 4000,
              decoration: const InputDecoration(
                labelText: 'Заметка',
                alignLabelWithHint: true,
                hintText: 'Детали, ссылки, идеи…',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget timingRow(String label, DateTime d, bool isEnd) => Row(
    children: [
      SizedBox(width: 100, child: Text(label)),
      Expanded(
        child: OutlinedButton(
          onPressed: () => pickDate(isEnd),
          child: Text('${d.day} ${months[d.month - 1]} ${d.year}'),
        ),
      ),
      if (!allDay) ...[
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () => pickTime(isEnd),
          child: Text(clockText(d)),
        ),
      ],
    ],
  );
}

class FolderPicker extends StatefulWidget {
  final PlannerStore store;
  final String selected;
  const FolderPicker({super.key, required this.store, required this.selected});
  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<FolderPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final store = widget.store;
      final folders = store.vaultFolders
          .where((f) => f.toLowerCase().contains(query.toLowerCase()))
          .toList();
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Папки Obsidian',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Обновить папки',
                      onPressed: store.loadingFolders
                          ? null
                          : store.refreshFolders,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: TextField(
                  onChanged: (v) => setState(() => query = v),
                  decoration: const InputDecoration(
                    hintText: 'Найти папку',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
              if (store.loadingFolders) const LinearProgressIndicator(),
              if (store.folderError.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(store.folderError),
                ),
              Expanded(
                child: ListView(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.folder_open),
                      title: const Text('Без категории'),
                      subtitle: const Text('Корень хранилища'),
                      selected: widget.selected == 'Без категории',
                      onTap: () => Navigator.pop(context, 'Без категории'),
                    ),
                    for (final folder in folders)
                      ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(folder),
                        selected: widget.selected == folder,
                        trailing: widget.selected == folder
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () => Navigator.pop(context, folder),
                      ),
                    if (folders.isEmpty && !store.loadingFolders)
                      const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                          'Папки не найдены. Создайте папку в Obsidian и нажмите обновление.',
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
