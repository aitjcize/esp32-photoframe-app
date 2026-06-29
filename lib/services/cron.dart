// Cron schedule helpers shared by the rotation-schedule editor.
//
// Mirrors the firmware engine (esp32-photoframe main/cron.{c,h}): simplified
// 3-field expressions "minute hour day-of-week", with *, a, a-b, */n, a-b/n and
// comma lists; day-of-week 0/7 = Sunday. Ported from the device webapp's
// cron.js (kept in sync).

class CronRule {
  final Set<int> minute;
  final Set<int> hour;
  final Set<int> dow;

  CronRule(this.minute, this.hour, this.dow);
}

const _ranges = [
  [0, 59], // minute
  [0, 23], // hour
  [0, 6], // day of week
];

final _termRe = RegExp(r'^(\*|\d+)(?:-(\d+))?(?:/(\d+))?$');

Set<int>? _parseField(String field, int lo, int hi, bool isDow) {
  if (field.isEmpty) return null;
  final out = <int>{};
  for (final term in field.split(',')) {
    final m = _termRe.firstMatch(term);
    if (m == null) return null;
    int start;
    int end;
    var step = 1;
    if (m.group(1) == '*') {
      start = lo;
      end = hi;
    } else {
      start = int.parse(m.group(1)!);
      end = m.group(2) != null ? int.parse(m.group(2)!) : start;
      if (m.group(2) == null && m.group(3) != null) end = hi;
    }
    if (m.group(3) != null) {
      step = int.parse(m.group(3)!);
      if (step <= 0) return null;
    }
    if (isDow) {
      if (start == 7) start = 0;
      if (end == 7) end = 0;
    }
    if (start < lo || end > hi || start > end) return null;
    for (var v = start; v <= end; v += step) {
      out.add(v);
    }
  }
  return out;
}

CronRule? parseCron(String expr) {
  final fields = expr.trim().split(RegExp(r'\s+'));
  if (fields.length != 3) return null;
  final sets = <Set<int>>[];
  for (var i = 0; i < 3; i++) {
    final s = _parseField(fields[i], _ranges[i][0], _ranges[i][1], i == 2);
    if (s == null) return null;
    sets.add(s);
  }
  return CronRule(sets[0], sets[1], sets[2]);
}

bool isValidCron(String expr) => parseCron(expr) != null;

bool _matches(CronRule r, DateTime d) {
  if (!r.minute.contains(d.minute)) return false;
  if (!r.hour.contains(d.hour)) return false;
  // DateTime.weekday: Mon=1..Sun=7; cron dow: Sun=0..Sat=6.
  return r.dow.contains(d.weekday % 7);
}

class QuietHours {
  final bool enabled;
  final int start; // minutes since midnight
  final int end;
  const QuietHours(this.enabled, this.start, this.end);
}

bool _inQuiet(DateTime d, QuietHours? sleep) {
  if (sleep == null || !sleep.enabled) return false;
  final cur = d.hour * 60 + d.minute;
  if (sleep.start > sleep.end) return cur >= sleep.start || cur < sleep.end;
  return cur >= sleep.start && cur < sleep.end;
}

const _horizonMin = 8 * 24 * 60;

/// Next [count] rotation times from [from], across all cron [exprs], applying an
/// optional quiet-hours mask. Mirrors the firmware scan (minute granularity,
/// <60s drift guard).
List<DateTime> nextRuns(List<String> exprs,
    {DateTime? from, int count = 5, QuietHours? sleep}) {
  final rules = exprs.map(parseCron).whereType<CronRule>().toList();
  if (rules.isEmpty) return [];
  final base = from ?? DateTime.now();
  final t0 = base.millisecondsSinceEpoch;
  final startMs = ((t0 + 1) / 60000).ceil() * 60000;
  final runs = <DateTime>[];
  for (var i = 0; i < _horizonMin && runs.length < count; i++) {
    final d = DateTime.fromMillisecondsSinceEpoch(startMs + i * 60000);
    if (d.millisecondsSinceEpoch - t0 < 60000) continue;
    if (!rules.any((r) => _matches(r, d))) continue;
    if (_inQuiet(d, sleep)) continue;
    runs.add(d);
  }
  return runs;
}

const dayLabels = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/// One friendly rule editor. [daysMode]/[mode] compile to one or more cron
/// strings (specific-times with differing minutes split into several).
class ScheduleCard {
  String daysMode; // everyday | weekdays | weekends | custom
  Set<int> customDays; // cron dow values when daysMode == custom
  String mode; // interval | times
  int every;
  String unit; // hours | minutes
  int fromHour;
  int toHour;
  List<String> times; // "HH:MM"
  String? raw; // advanced override (single expression)

  ScheduleCard({
    this.daysMode = 'everyday',
    Set<int>? customDays,
    this.mode = 'interval',
    this.every = 12,
    this.unit = 'hours',
    this.fromHour = 0,
    this.toHour = 23,
    List<String>? times,
    this.raw,
  })  : customDays = customDays ?? <int>{1, 2, 3, 4, 5},
        times = times ?? <String>['08:00'];
}

String _daysToCron(ScheduleCard c) {
  switch (c.daysMode) {
    case 'weekdays':
      return '1-5';
    case 'weekends':
      return '0,6';
    case 'custom':
      if (c.customDays.isEmpty || c.customDays.length == 7) return '*';
      final sorted = c.customDays.toList()..sort();
      return sorted.join(',');
    default:
      return '*';
  }
}

String _hourRange(int fromHour, int toHour) {
  if (fromHour <= 0 && toHour >= 23) return '*';
  return fromHour == toHour ? '$fromHour' : '$fromHour-$toHour';
}

List<String> compileCard(ScheduleCard c) {
  final raw = c.raw;
  if (raw != null && raw.trim().isNotEmpty) return [raw.trim()];
  final dow = _daysToCron(c);

  if (c.mode == 'interval') {
    if (c.unit == 'minutes') {
      final min = c.every > 1 ? '*/${c.every}' : '*';
      return ['$min ${_hourRange(c.fromHour, c.toHour)} $dow'];
    }
    final String hr;
    if (c.fromHour <= 0 && c.toHour >= 23) {
      hr = c.every > 1 ? '*/${c.every}' : '*';
    } else {
      hr = '${_hourRange(c.fromHour, c.toHour)}/${c.every}';
    }
    return ['0 $hr $dow'];
  }

  final byMinute = <int, List<int>>{};
  for (final t in c.times) {
    final parts = t.split(':');
    if (parts.length != 2) continue;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) continue;
    byMinute.putIfAbsent(m, () => []).add(h);
  }
  final rules = <String>[];
  byMinute.forEach((m, hours) {
    final uniq = hours.toSet().toList()..sort();
    rules.add('$m ${uniq.join(',')} $dow');
  });
  return rules.isNotEmpty ? rules : ['0 * $dow'];
}

List<String> compileCards(List<ScheduleCard> cards) =>
    cards.expand(compileCard).toList();

// Backward compatibility with firmware that predates rotate_cron and still uses
// a single rotate_interval (seconds).

/// Convert a legacy rotation interval (seconds) into a single 3-field cron rule.
/// Mirrors the firmware's cron_from_legacy_interval mapping.
String intervalToCron(int seconds) {
  if (seconds >= 3600 && seconds % 3600 == 0) {
    final hours = seconds ~/ 3600;
    if (hours <= 1) return '0 * *';
    if (hours >= 24) return '0 0 *';
    return '0 */$hours *';
  }
  if (seconds >= 60 && 3600 % seconds == 0) {
    return '*/${seconds ~/ 60} * *';
  }
  return '0 * *';
}

/// Best-effort inverse: if the schedule is a single every-day interval rule,
/// return the equivalent seconds so old firmware (which only understands
/// rotate_interval) can still be driven. Returns null otherwise.
int? cronToInterval(List<String> rules) {
  if (rules.length != 1) return null;
  final f = rules[0].trim().split(RegExp(r'\s+'));
  if (f.length != 3) return null;
  final min = f[0];
  final hour = f[1];
  final dow = f[2];
  if (dow != '*') return null;
  var m = RegExp(r'^\*/(\d+)$').firstMatch(min);
  if (m != null && hour == '*') return int.parse(m.group(1)!) * 60;
  m = RegExp(r'^\*/(\d+)$').firstMatch(hour);
  if (min == '0' && m != null) return int.parse(m.group(1)!) * 3600;
  if (min == '0' && hour == '*') return 3600;
  if (min == '0' && hour == '0') return 86400;
  return null;
}

ScheduleCard cardFromCron(String expr) {
  final card = ScheduleCard();
  final fields = expr.trim().split(RegExp(r'\s+'));
  if (fields.length != 3 || parseCron(expr) == null) {
    card.raw = expr.trim();
    return card;
  }
  final minF = fields[0];
  final hourF = fields[1];
  final dowF = fields[2];

  // day-of-week
  if (dowF == '*') {
    card.daysMode = 'everyday';
  } else if (dowF == '1-5') {
    card.daysMode = 'weekdays';
  } else if (dowF == '0,6' || dowF == '6,0') {
    card.daysMode = 'weekends';
  } else {
    final set = _parseField(dowF, 0, 6, true);
    card.daysMode = 'custom';
    card.customDays = set ?? {1, 2, 3, 4, 5};
  }

  final stepMin = RegExp(r'^\*/(\d+)$').firstMatch(minF);
  final stepHour = RegExp(r'^(?:\*|(\d+)-(\d+))/(\d+)$').firstMatch(hourF);

  if (stepMin != null &&
      (hourF == '*' || RegExp(r'^\d+-\d+$').hasMatch(hourF))) {
    card.mode = 'interval';
    card.unit = 'minutes';
    card.every = int.parse(stepMin.group(1)!);
    if (hourF == '*') {
      card.fromHour = 0;
      card.toHour = 23;
    } else {
      final hp = hourF.split('-');
      card.fromHour = int.parse(hp[0]);
      card.toHour = int.parse(hp[1]);
    }
    return card;
  }

  if (minF == '0' && stepHour != null) {
    card.mode = 'interval';
    card.unit = 'hours';
    card.every = int.parse(stepHour.group(3)!);
    card.fromHour =
        stepHour.group(1) != null ? int.parse(stepHour.group(1)!) : 0;
    card.toHour =
        stepHour.group(2) != null ? int.parse(stepHour.group(2)!) : 23;
    return card;
  }

  if (RegExp(r'^\d+$').hasMatch(minF) && RegExp(r'^[\d,]+$').hasMatch(hourF)) {
    card.mode = 'times';
    final m = minF.padLeft(2, '0');
    card.times = hourF.split(',').map((h) => '${h.padLeft(2, '0')}:$m').toList()
      ..sort();
    return card;
  }

  card.raw = expr.trim();
  return card;
}

List<ScheduleCard> cardsFromCron(List<String>? exprs) {
  if (exprs == null || exprs.isEmpty) return [ScheduleCard()];
  return exprs.map(cardFromCron).toList();
}

String _daysLabel(ScheduleCard c) {
  switch (c.daysMode) {
    case 'weekdays':
      return 'weekdays';
    case 'weekends':
      return 'weekends';
    case 'custom':
      if (c.customDays.isEmpty || c.customDays.length == 7) return 'every day';
      final sorted = c.customDays.toList()..sort();
      return sorted.map((d) => dayLabels[d]).join(', ');
    default:
      return 'every day';
  }
}

String _hour12(int h) {
  final ampm = h < 12 ? 'AM' : 'PM';
  final hr = h % 12 == 0 ? 12 : h % 12;
  return '$hr $ampm';
}

String _timeLabel(String hhmm) {
  final parts = hhmm.split(':');
  final h = int.tryParse(parts[0]) ?? 0;
  final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
  final ampm = h < 12 ? 'AM' : 'PM';
  final hr = h % 12 == 0 ? 12 : h % 12;
  return '$hr:${m.toString().padLeft(2, '0')} $ampm';
}

String describeCard(ScheduleCard c) {
  final raw = c.raw;
  if (raw != null && raw.trim().isNotEmpty) return 'Custom: ${raw.trim()}';
  final days = _daysLabel(c);
  if (c.mode == 'interval') {
    final unit = c.unit == 'hours' ? 'hours' : 'minutes';
    final every = c.every == 1
        ? 'every ${c.unit == 'hours' ? 'hour' : 'minute'}'
        : 'every ${c.every} $unit';
    final window = c.fromHour <= 0 && c.toHour >= 23
        ? ''
        : ', ${_hour12(c.fromHour)}–${_hour12(c.toHour)}';
    return 'Rotate $every$window, $days';
  }
  final times = c.times.map(_timeLabel).join(', ');
  return 'Rotate at $times, $days';
}

/// Short one-line summary of a whole schedule (for list tiles).
String summarizeSchedule(List<String> exprs) {
  if (exprs.isEmpty) return 'No schedule';
  final first = describeCard(cardFromCron(exprs[0]));
  if (exprs.length == 1) return first;
  return '$first  (+${exprs.length - 1} more)';
}
