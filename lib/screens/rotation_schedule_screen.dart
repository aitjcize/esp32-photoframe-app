import 'package:flutter/material.dart';

import '../services/cron.dart';

/// Full-screen editor for the rotation schedule. Pops with the compiled
/// `List<String>` of cron expressions (or null if cancelled).
class RotationScheduleScreen extends StatefulWidget {
  final List<String> initial;
  final QuietHours? sleep;
  // False when the device runs pre-cron firmware, which only understands a
  // single every-day interval. Drives an advisory banner.
  final bool supportsCron;
  const RotationScheduleScreen({
    super.key,
    required this.initial,
    this.sleep,
    this.supportsCron = true,
  });

  @override
  State<RotationScheduleScreen> createState() => _RotationScheduleScreenState();
}

class _RotationScheduleScreenState extends State<RotationScheduleScreen> {
  late List<ScheduleCard> _cards;

  @override
  void initState() {
    super.initState();
    if (widget.supportsCron) {
      _cards = cardsFromCron(widget.initial);
    } else {
      // Pre-cron firmware only understands a single every-day interval. Derive
      // it from the current schedule and edit it with the simplified form, so
      // the user never builds something the device can't run.
      final seconds = cronToInterval(widget.initial) ?? 3600;
      _cards = [_intervalCard(seconds)];
    }
  }

  ScheduleCard _intervalCard(int seconds) {
    final card = ScheduleCard();
    card.mode = 'interval';
    card.daysMode = 'everyday';
    card.fromHour = 0;
    card.toHour = 23;
    if (seconds >= 3600 && seconds % 3600 == 0) {
      card.unit = 'hours';
      card.every = seconds ~/ 3600;
    } else {
      card.unit = 'minutes';
      card.every = seconds < 60 ? 1 : seconds ~/ 60;
    }
    return card;
  }

  List<String> get _compiled => compileCards(_cards);
  int get _totalRules => _compiled.length;

  static const _dayOrder = [1, 2, 3, 4, 5, 6, 0]; // Mon..Sun (cron dow)

  List<int> _everyItems(String unit) => unit == 'hours'
      ? const [1, 2, 3, 4, 6, 8, 12]
      : const [5, 10, 15, 20, 30];

  // Preset steps for the given unit, guaranteeing the current value is present
  // (a device-derived interval may not be one of the presets).
  List<int> _everyItemsFor(String unit, int current) {
    final base = List<int>.from(_everyItems(unit));
    if (!base.contains(current)) {
      base
        ..add(current)
        ..sort();
    }
    return base;
  }

  Future<void> _editTime(ScheduleCard card, int idx) async {
    final parts = card.times[idx].split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(parts[0]) ?? 0,
        minute: parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        card.times[idx] =
            '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
        card.times.sort();
      });
    }
  }

  String _formatRun(DateTime d) {
    final dow = dayLabels[d.weekday % 7];
    return '$dow ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  // The device rejects the whole config on any invalid rule or a rule set
  // over the 7-rule budget, so only allow saving a schedule it will accept.
  bool get _canSave =>
      _compiled.isNotEmpty && _totalRules <= 7 && _compiled.every(isValidCron);

  @override
  Widget build(BuildContext context) {
    final upcoming = nextRuns(
      _compiled,
      sleep: widget.sleep,
      count: 4,
    ).map(_formatRun).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rotation Schedule'),
        actions: [
          TextButton(
            onPressed: _canSave
                ? () => Navigator.pop(context, _compiled)
                : null,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (!widget.supportsCron)
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  "This frame's firmware only supports a simple repeating "
                  'interval. Update the firmware for day-of-week and '
                  'specific-time schedules.',
                ),
              ),
            ),
          for (var i = 0; i < _cards.length; i++) _buildCard(i, _cards[i]),
          if (widget.supportsCron) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _totalRules >= 7
                  ? null
                  : () => setState(() => _cards.add(ScheduleCard())),
              icon: const Icon(Icons.add),
              label: const Text('Add another schedule'),
            ),
            if (_totalRules > 7)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'This uses $_totalRules rules, but the device supports at most 7. '
                  'Remove a schedule or simplify the specific times.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
          const Divider(height: 32),
          Text(
            'Upcoming rotations',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 8),
          if (upcoming.isEmpty)
            const Text(
              'No upcoming rotations for this schedule.',
              style: TextStyle(color: Colors.grey),
            )
          else ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final r in upcoming) Chip(label: Text(r))],
            ),
            const SizedBox(height: 6),
            Text(
              "Times shown in this phone's timezone; the device follows its own "
              'timezone setting.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCard(int idx, ScheduleCard card) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Schedule ${idx + 1}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                if (_cards.length > 1)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() => _cards.removeAt(idx)),
                  ),
              ],
            ),
            if (card.raw != null) _buildRaw(card) else _buildBuilder(card),
            const SizedBox(height: 8),
            Text(
              describeCard(card),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            // Raw cron editing is meaningless on pre-cron firmware.
            if (widget.supportsCron)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() {
                    if (card.raw == null) {
                      final rules = compileCard(card);
                      card.raw = rules.isNotEmpty ? rules.first : '0 */12 *';
                      // A times card with several distinct minutes compiles to
                      // several rules; split the extras into their own advanced
                      // cards so none are lost.
                      if (rules.length > 1) {
                        _cards.insertAll(
                          idx + 1,
                          rules.skip(1).map((r) => ScheduleCard(raw: r)),
                        );
                      }
                    } else {
                      // Re-derive the builder state from the edited expression
                      // when possible; unmappable ones stay in advanced mode.
                      _cards[idx] = cardFromCron(card.raw!);
                    }
                  }),
                  child: Text(
                    card.raw != null ? 'Use builder' : 'Advanced (cron)',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRaw(ScheduleCard card) {
    final valid = card.raw == null || isValidCron(card.raw!);
    return TextFormField(
      initialValue: card.raw,
      decoration: InputDecoration(
        labelText: 'Cron expression',
        helperText: 'minute hour day-of-week',
        border: const OutlineInputBorder(),
        errorText: valid ? null : 'Invalid cron expression',
      ),
      onChanged: (v) => setState(() => card.raw = v),
    );
  }

  // Simplified editor for pre-cron firmware: a single every-day interval.
  Widget _buildIntervalSimple(ScheduleCard card) {
    final items = _everyItemsFor(card.unit, card.every);
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _dropdown<int>(
          label: 'Every',
          value: items.contains(card.every) ? card.every : items.first,
          items: {for (final v in items) v: '$v'},
          onChanged: (v) => setState(() => card.every = v),
        ),
        _dropdown<String>(
          label: 'Unit',
          value: card.unit,
          items: const {'minutes': 'minutes', 'hours': 'hours'},
          onChanged: (v) => setState(() => card.unit = v),
        ),
      ],
    );
  }

  Widget _buildBuilder(ScheduleCard card) {
    if (!widget.supportsCron) return _buildIntervalSimple(card);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Days
        Wrap(
          spacing: 6,
          children: [
            for (final m in const [
              'everyday',
              'weekdays',
              'weekends',
              'custom',
            ])
              ChoiceChip(
                label: Text(_daysModeLabel(m)),
                selected: card.daysMode == m,
                onSelected: (_) => setState(() => card.daysMode = m),
              ),
          ],
        ),
        if (card.daysMode == 'custom')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              children: [
                for (final d in _dayOrder)
                  FilterChip(
                    label: Text(dayLabels[d]),
                    selected: card.customDays.contains(d),
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        card.customDays.add(d);
                      } else if (card.customDays.length > 1) {
                        // Keep at least one day — an empty set compiles to
                        // "every day", the opposite of the apparent intent.
                        card.customDays.remove(d);
                      }
                    }),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        // Mode
        Wrap(
          spacing: 6,
          children: [
            ChoiceChip(
              label: const Text('Throughout the day'),
              selected: card.mode == 'interval',
              onSelected: (_) => setState(() => card.mode = 'interval'),
            ),
            ChoiceChip(
              label: const Text('At specific times'),
              selected: card.mode == 'times',
              onSelected: (_) => setState(() => card.mode = 'times'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (card.mode == 'interval')
          _buildInterval(card)
        else
          _buildTimes(card),
      ],
    );
  }

  Widget _buildInterval(ScheduleCard card) {
    final everyItems = _everyItemsFor(card.unit, card.every);
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _dropdown<int>(
          label: 'Every',
          value: everyItems.contains(card.every)
              ? card.every
              : everyItems.first,
          items: {for (final v in everyItems) v: '$v'},
          onChanged: (v) => setState(() => card.every = v),
        ),
        _dropdown<String>(
          label: 'Unit',
          value: card.unit,
          items: const {'minutes': 'minutes', 'hours': 'hours'},
          onChanged: (v) => setState(() => card.unit = v),
        ),
        _dropdown<int>(
          label: 'From',
          value: card.fromHour,
          items: {
            for (var h = 0; h < 24; h++)
              h: '${h.toString().padLeft(2, '0')}:00',
          },
          onChanged: (v) => setState(() {
            // The device can't express a window that wraps past midnight.
            card.fromHour = v;
            if (card.toHour < v) card.toHour = v;
          }),
        ),
        _dropdown<int>(
          label: 'To',
          value: card.toHour,
          items: {
            for (var h = card.fromHour; h < 24; h++)
              h: '${h.toString().padLeft(2, '0')}:00',
          },
          onChanged: (v) => setState(() => card.toHour = v),
        ),
      ],
    );
  }

  Widget _buildTimes(ScheduleCard card) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < card.times.length; i++)
          InputChip(
            label: Text(card.times[i]),
            onPressed: () => _editTime(card, i),
            onDeleted: () => setState(() {
              card.times.removeAt(i);
              if (card.times.isEmpty) card.times.add('12:00');
            }),
          ),
        TextButton.icon(
          onPressed: () => setState(() {
            card.times.add('12:00');
            card.times.sort();
          }),
          icon: const Icon(Icons.add),
          label: const Text('Add time'),
        ),
      ],
    );
  }

  Widget _dropdown<T>({
    required String label,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T> onChanged,
  }) {
    return SizedBox(
      width: 140,
      child: DropdownButtonFormField<T>(
        value: value,
        isDense: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final e in items.entries)
            DropdownMenuItem<T>(value: e.key, child: Text(e.value)),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  String _daysModeLabel(String m) {
    switch (m) {
      case 'weekdays':
        return 'Weekdays';
      case 'weekends':
        return 'Weekends';
      case 'custom':
        return 'Custom';
      default:
        return 'Every day';
    }
  }
}
