import 'package:flutter/material.dart';

class Wes2DayHeader extends StatelessWidget {
  final DateTime date;
  final VoidCallback? onSelectDate;

  const Wes2DayHeader({
    super.key,
    required this.date,
    this.onSelectDate,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _formatDate(date),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
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
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${weekdays[d.weekday - 1]} ${d.day} ${months[d.month - 1]} ${d.year}';
  }
}
