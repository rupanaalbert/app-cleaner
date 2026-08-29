import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme.dart';
import '../booking_controller.dart';

/// Scheduling.
///
/// A horizontal day strip beats a month grid here: cleans are booked days
/// ahead, not months, and a strip keeps the time slots on the same screen so
/// the price in the ledger below responds to a single tap.
///
/// Weekend days are marked in the strip rather than only surfacing a surcharge
/// at checkout — if Saturday costs more, say so while the customer is choosing
/// Saturday.
class ScheduleStep extends StatefulWidget {
  const ScheduleStep({super.key, required this.c});
  final BookingController c;

  @override
  State<ScheduleStep> createState() => _ScheduleStepState();
}

class _ScheduleStepState extends State<ScheduleStep> {
  static const _leadMinutes = 120; // must match config.booking.minLeadMinutes
  late DateTime _selectedDay;

  @override
  void initState() {
    super.initState();
    final existing = widget.c.draft.scheduledAt;
    _selectedDay = existing ?? _dayStart(DateTime.now());
  }

  DateTime _dayStart(DateTime d) => DateTime(d.year, d.month, d.day);

  List<DateTime> get _days =>
      List.generate(21, (i) => _dayStart(DateTime.now()).add(Duration(days: i)));

  /// Half-hour slots from 08:00 to 18:00, minus anything inside the lead window.
  List<DateTime> get _slots {
    final earliest = DateTime.now().add(const Duration(minutes: _leadMinutes));
    final out = <DateTime>[];
    for (var minutes = 8 * 60; minutes <= 18 * 60; minutes += 30) {
      final slot = _selectedDay.add(Duration(minutes: minutes));
      if (slot.isAfter(earliest)) out.add(slot);
    }
    return out;
  }

  bool _isWeekend(DateTime d) =>
      d.weekday == DateTime.saturday || d.weekday == DateTime.sunday;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final selected = c.draft.scheduledAt;
    final slots = _slots;

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, Sparkle.s4, 0, Sparkle.s6),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sparkle.s4),
          child: Text('When works for you?', style: Theme.of(context).textTheme.titleLarge),
        ),
        const SizedBox(height: Sparkle.s1),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Sparkle.s4),
          child: Text('Book at least 2 hours ahead. Weekends cost a little more.',
              style: TextStyle(color: Sparkle.inkSoft, fontSize: 13)),
        ),
        const SizedBox(height: Sparkle.s4),
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Sparkle.s4),
            itemCount: _days.length,
            separatorBuilder: (_, __) => const SizedBox(width: Sparkle.s2),
            itemBuilder: (context, i) {
              final day = _days[i];
              final isSelected = _dayStart(_selectedDay) == day;
              return _DayCell(
                day: day,
                selected: isSelected,
                weekend: _isWeekend(day),
                onTap: () => setState(() => _selectedDay = day),
              );
            },
          ),
        ),
        const SizedBox(height: Sparkle.s5),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sparkle.s4),
          child: Text(DateFormat('EEEE d MMMM').format(_selectedDay),
              style: Theme.of(context).textTheme.titleMedium),
        ),
        const SizedBox(height: Sparkle.s3),
        if (slots.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: Sparkle.s4),
            child: Text('No times left today. Try tomorrow.',
                style: TextStyle(color: Sparkle.inkSoft)),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sparkle.s4),
            child: Wrap(
              spacing: Sparkle.s2,
              runSpacing: Sparkle.s2,
              children: [
                for (final slot in slots)
                  _SlotChip(
                    label: DateFormat('h:mm a').format(slot),
                    evening: slot.hour >= 17,
                    selected: selected == slot,
                    onTap: () => c.setSchedule(slot),
                  ),
              ],
            ),
          ),
        const SizedBox(height: Sparkle.s5),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sparkle.s4),
          child: Text('How do we get in?', style: Theme.of(context).textTheme.titleMedium),
        ),
        const SizedBox(height: Sparkle.s2),
        RadioGroup<String>(
          groupValue: c.draft.entryMethod,
          onChanged: (v) => c.setEntryMethod(v!),
          child: Column(
            children: [
              for (final entry in const {
                'home': 'I\'ll be home',
                'doorman': 'Doorman or front desk',
                'lockbox': 'Lockbox or keypad',
                'hidden_key': 'Key is hidden on site',
              }.entries)
                RadioListTile<String>(
                  value: entry.key,
                  activeColor: Sparkle.seafoam,
                  title: Text(entry.value, style: const TextStyle(fontSize: 15)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: Sparkle.s4),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.selected,
    required this.weekend,
    required this.onTap,
  });

  final DateTime day;
  final bool selected;
  final bool weekend;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: Sparkle.s3),
        decoration: BoxDecoration(
          color: selected ? Sparkle.marine : Sparkle.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? Sparkle.marine : Sparkle.hairline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              DateFormat('EEE').format(day).toUpperCase(),
              style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.8,
                color: selected ? Sparkle.mutedOnMarine : Sparkle.inkSoft,
              ),
            ),
            const SizedBox(height: Sparkle.s1),
            Text(
              DateFormat('d').format(day),
              style: TextStyle(
                fontFamily: 'Manrope', fontSize: 20, fontWeight: FontWeight.w600,
                color: selected ? Colors.white : Sparkle.inkStrong,
              ),
            ),
            const SizedBox(height: Sparkle.s1),
            // A small mark, not a red banner: informative, not alarming.
            Container(
              height: 4,
              width: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: weekend
                    ? (selected ? Colors.white : Sparkle.seafoam)
                    : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlotChip extends StatelessWidget {
  const _SlotChip({
    required this.label,
    required this.selected,
    required this.evening,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool evening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: Sparkle.s4, vertical: Sparkle.s3),
        decoration: BoxDecoration(
          color: selected ? Sparkle.seafoam : Sparkle.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? Sparkle.seafoam : Sparkle.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: selected ? Colors.white : Sparkle.ink,
              ),
            ),
            if (evening) ...[
              const SizedBox(width: Sparkle.s1),
              Icon(Icons.nightlight_outlined,
                  size: 13, color: selected ? Colors.white70 : Sparkle.inkSoft),
            ],
          ],
        ),
      ),
    );
  }
}
