import 'package:flutter_test/flutter_test.dart';
import 'package:esp32_photoframe_app/services/cron.dart';

List<int> dow(String e) => parseCron(e)!.dow.toList()..sort();
List<int> hour(String e) => parseCron(e)!.hour.toList()..sort();
List<int> minute(String e) => parseCron(e)!.minute.toList()..sort();

// Seconds until the first run from a local wall-clock time. Deltas between two
// instants are timezone-independent, so these don't depend on the runner's TZ.
int? secsUntil(List<String> exprs, List<int> t, {QuietHours? sleep}) {
  final from = DateTime(t[0], t[1], t[2], t[3], t[4], t[5]);
  final runs = nextRuns(exprs, from: from, count: 1, sleep: sleep);
  return runs.isEmpty ? null : runs.first.difference(from).inSeconds;
}

void main() {
  group('parseCron — valid', () {
    for (final e in [
      '0 */12 *',
      '*/30 8-22 1-5',
      '0,15,30,45 * *',
      '0 0 *',
      '0 9,12,18 0,6',
      '0 0 7',
      '  0   *  *  ',
      '5/10 * *',
      '0 0 5-7',
      '0 0 0-7',
    ]) {
      test('accepts "$e"', () => expect(isValidCron(e), isTrue));
    }
  });

  group('parseCron — invalid', () {
    for (final e in [
      '',
      '* *',
      '* * * *',
      '60 * *',
      '* 24 *',
      '* * 8',
      '5-2 * *',
      'a * *',
      '*/0 * *',
      '*-5 * *',
      '0 12\n*',
      '0 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 *',
    ]) {
      test(
        'rejects ${e.replaceAll("\n", "\\n")}',
        () => expect(isValidCron(e), isFalse),
      );
    }
  });

  group('day-of-week Vixie semantics', () {
    test('7 aliases Sunday', () => expect(dow('0 0 7'), [0]));
    test('5-7 is Fri-Sun', () => expect(dow('0 0 5-7'), [0, 5, 6]));
    test(
      '0-7 is every day',
      () => expect(dow('0 0 0-7'), [0, 1, 2, 3, 4, 5, 6]),
    );
  });

  group('field expansion', () {
    test(
      'bare value with step means "from a through hi"',
      () => expect(minute('5/10 * *'), [5, 15, 25, 35, 45, 55]),
    );
    test('single-hour range with step', () => expect(hour('0 8-8/2 *'), [8]));
    test(
      'windowed hours with step',
      () => expect(hour('0 9-19/2 *'), [9, 11, 13, 15, 17, 19]),
    );
  });

  group('nextRuns', () {
    test(
      'hourly -> top of next hour',
      () => expect(secsUntil(['0 * *'], [2026, 6, 27, 10, 0, 0]), 3600),
    );
    test(
      'every 12 hours',
      () => expect(secsUntil(['0 */12 *'], [2026, 6, 27, 10, 0, 0]), 7200),
    );
    test(
      'every 30 minutes',
      () => expect(secsUntil(['*/30 * *'], [2026, 6, 27, 10, 0, 0]), 1800),
    );
    test(
      'earliest of multiple rules wins',
      () => expect(
        secsUntil(['0 12 *', '30 10 *'], [2026, 6, 27, 10, 0, 0]),
        1800,
      ),
    );
    test(
      'honors an imminent match (no minimum-delay guard)',
      () => expect(secsUntil(['0 * *'], [2026, 6, 27, 10, 59, 30]), 30),
    );
    test(
      'rounds up a sub-minute start',
      () => expect(secsUntil(['0 * *'], [2026, 6, 27, 10, 0, 30]), 3570),
    );
    test(
      'returns nothing for no rules',
      () => expect(
        nextRuns([], from: DateTime(2026, 6, 27, 10, 0, 0), count: 4),
        isEmpty,
      ),
    );

    test(
      'quiet hours overnight -> wakes at window end',
      () => expect(
        secsUntil(
          ['0 * *'],
          [2026, 6, 27, 22, 30, 0],
          sleep: const QuietHours(true, 1380, 420),
        ),
        30600,
      ),
    );
    test(
      'quiet hours same-day',
      () => expect(
        secsUntil(
          ['0 * *'],
          [2026, 6, 27, 12, 30, 0],
          sleep: const QuietHours(true, 780, 840),
        ),
        5400,
      ),
    );
    test(
      'disabled quiet hours are ignored',
      () => expect(
        secsUntil(
          ['0 * *'],
          [2026, 6, 27, 22, 30, 0],
          sleep: const QuietHours(false, 1380, 420),
        ),
        1800,
      ),
    );
  });

  group('compileCard', () {
    test(
      'hours interval, all day',
      () => expect(
        compileCard(ScheduleCard(mode: 'interval', unit: 'hours', every: 2)),
        ['0 */2 *'],
      ),
    );
    test(
      'windowed hours emit explicit a-b/n',
      () => expect(
        compileCard(
          ScheduleCard(
            mode: 'interval',
            unit: 'hours',
            every: 2,
            fromHour: 8,
            toHour: 20,
          ),
        ),
        ['0 8-20/2 *'],
      ),
    );
    test(
      'single-hour window with step is not open-ended',
      () => expect(
        compileCard(
          ScheduleCard(
            mode: 'interval',
            unit: 'hours',
            every: 2,
            fromHour: 8,
            toHour: 8,
          ),
        ),
        ['0 8-8/2 *'],
      ),
    );
    test(
      'minutes interval',
      () => expect(
        compileCard(ScheduleCard(mode: 'interval', unit: 'minutes', every: 30)),
        ['*/30 * *'],
      ),
    );
    test(
      'specific times group hours by minute',
      () => expect(
        compileCard(
          ScheduleCard(
            mode: 'times',
            times: ['08:30', '20:30'],
            daysMode: 'weekdays',
          ),
        ),
        ['30 8,20 1-5'],
      ),
    );
    test(
      'cleared/half-typed time inputs are skipped',
      () => expect(
        compileCard(ScheduleCard(mode: 'times', times: ['', '12'])),
        ['0 * *'],
      ),
    );
    test(
      'emptied advanced field compiles to an invalid empty rule',
      () => expect(compileCard(ScheduleCard(raw: '')), ['']),
    );
  });

  group('cardFromCron round-trip', () {
    const cases = {
      '0 * *': '0 * *',
      '* 8-20 *': '* 8-20 *',
      '0 8-20 *': '0 8-20/1 *',
      '0 */5 *': '0 */5 *',
      '*/30 * *': '*/30 * *',
      '30 9,18 1-5': '30 9,18 1-5',
    };
    cases.forEach((expr, recompiled) {
      test('$expr stays a friendly card', () {
        final card = cardFromCron(expr);
        expect(card.raw, isNull);
        expect(compileCard(card), [recompiled]);
      });
    });
    test(
      'an unmappable expression falls back to a raw card',
      () => expect(cardFromCron('15 8-20 *').raw, '15 8-20 *'),
    );
  });

  group('legacy interval <-> cron', () {
    const toCron = {
      3600: '0 * *',
      7200: '0 */2 *',
      21600: '0 */6 *',
      86400: '0 0 *',
      1800: '*/30 * *',
      90: '*/1 * *', // integer division, not */1.5
      450: '*/7 * *',
      5400: '0 * *', // 90min not cleanly expressible -> hourly
    };
    toCron.forEach((secs, expr) {
      test('intervalToCron($secs) = $expr', () {
        expect(intervalToCron(secs), expr);
        expect(isValidCron(intervalToCron(secs)), isTrue);
      });
    });

    test('cronToInterval inverts every-day intervals', () {
      expect(cronToInterval(['0 */2 *']), 7200);
      expect(cronToInterval(['*/30 * *']), 1800);
      expect(cronToInterval(['0 * *']), 3600);
      expect(cronToInterval(['0 0 *']), 86400);
    });
    test('cronToInterval returns null for non-interval schedules', () {
      expect(cronToInterval(['0 9 1-5']), isNull);
      expect(cronToInterval(['0 8-20/2 *']), isNull);
      expect(cronToInterval(['0 9 *', '0 18 *']), isNull);
    });
  });
}
