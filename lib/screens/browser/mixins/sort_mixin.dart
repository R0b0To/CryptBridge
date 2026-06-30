import 'package:flutter/material.dart';
import '../../../utils/raw_entry.dart';

enum SortBy { name, size, extension, date }

/// Encapsulates sort-field / direction state and the comparator used to order
/// directory entries.  Mix into any [State] that renders a sortable file list.
///
/// Uses [RawEntry.parse] so it handles the full three-field wire format
/// ("name|size|unixSecs" / "[DIR] name|0|unixSecs") correctly.
mixin SortMixin<T extends StatefulWidget> on State<T> {
  SortBy sortBy = SortBy.name;
  bool sortAscending = true;

  void setSort(SortBy by) {
    setState(() {
      if (sortBy == by) {
        sortAscending = !sortAscending;
      } else {
        sortBy = by;
        // Sensible defaults: alphabetical fields start A→Z; magnitude fields
        // start largest/newest first so the most relevant items are on top.
        sortAscending = switch (by) {
          SortBy.name => true,
          SortBy.extension => true,
          SortBy.size => false, // largest first
          SortBy.date => false, // newest first
        };
      }
    });
  }

  int compareItems(String a, String b) {
    final ea = RawEntry.parse(a);
    final eb = RawEntry.parse(b);

    int result;
    switch (sortBy) {
      case SortBy.name:
        result = ea.name.toLowerCase().compareTo(eb.name.toLowerCase());

      case SortBy.size:
        result = ea.sizeBytes.compareTo(eb.sizeBytes);
        // Tie-break alphabetically so the order is stable.
        if (result == 0) {
          result = ea.name.toLowerCase().compareTo(eb.name.toLowerCase());
        }

      case SortBy.extension:
        String extOf(String name) =>
            name.contains('.') ? name.split('.').last.toLowerCase() : '';
        result = extOf(ea.name).compareTo(extOf(eb.name));
        if (result == 0) {
          result = ea.name.toLowerCase().compareTo(eb.name.toLowerCase());
        }

      case SortBy.date:
        result = ea.modifiedSecs.compareTo(eb.modifiedSecs);
        // Tie-break alphabetically.
        if (result == 0) {
          result = ea.name.toLowerCase().compareTo(eb.name.toLowerCase());
        }
    }

    return sortAscending ? result : -result;
  }

  /// Builds a [PopupMenuItem] for the sort menu, annotated with the current
  /// direction arrow when active.
  PopupMenuItem<SortBy> buildSortMenuItem(SortBy value, String label) {
    final cs = Theme.of(context).colorScheme;
    final isActive = sortBy == value;
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(
            isActive
                ? (sortAscending ? Icons.arrow_upward : Icons.arrow_downward)
                : Icons.sort,
            size: 16,
            color: isActive ? cs.primary : null,
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontWeight: isActive ? FontWeight.w700 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
