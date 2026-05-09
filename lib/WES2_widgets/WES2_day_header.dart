import 'package:flutter/material.dart';

class Wes2DayHeader extends StatelessWidget {
  final DateTime date;
  final VoidCallback? onSelectDate;
  final VoidCallback? onPrevDay;
  final VoidCallback? onNextDay;

  const Wes2DayHeader({
    super.key,
    required this.date,
    this.onSelectDate,
    this.onPrevDay,
    this.onNextDay,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: onPrevDay,
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Text(
              _formatDate(date),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: onNextDay,
            visualDensity: VisualDensity.compact,
          ),
          TextButton(
            onPressed: onSelectDate,
            child: const Text(
              'Select Date',
              style: TextStyle(fontFamily: 'Verdana'),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime d) {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${weekdays[d.weekday - 1]} ${d.day} ${months[d.month - 1]} ${d.year}';
  }
}
