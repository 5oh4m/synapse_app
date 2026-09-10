import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/responsive.dart';

/// The four answer tiles, shared by the host projector view and the student
/// device. Shows correctness + answer distribution once [correctIndex] is set.
class OptionGrid extends StatelessWidget {
  const OptionGrid({
    super.key,
    required this.options,
    required this.onTap,
    this.selectedIndex,
    this.correctIndex,
    this.counts,
    this.enabled = true,
  });

  final List<String> options;
  final ValueChanged<int> onTap;
  final int? selectedIndex;
  final int? correctIndex;
  final List<int>? counts;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cols = isCompact(context) ? 1 : 2;
    final revealed = correctIndex != null;
    return GridView.count(
      crossAxisCount: cols,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: isCompact(context) ? 5.0 : 3.4,
      children: [
        for (var i = 0; i < options.length; i++)
          _Tile(
            index: i,
            label: options[i],
            base: OptionPalette.fill[i % 4],
            icon: OptionPalette.shapes[i % 4],
            selected: selectedIndex == i,
            isCorrect: revealed && correctIndex == i,
            isWrongPick: revealed && selectedIndex == i && correctIndex != i,
            dim: revealed && correctIndex != i,
            count: counts == null ? null : counts![i],
            enabled: enabled && !revealed,
            onTap: () => onTap(i),
          ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.index,
    required this.label,
    required this.base,
    required this.icon,
    required this.selected,
    required this.isCorrect,
    required this.isWrongPick,
    required this.dim,
    required this.count,
    required this.enabled,
    required this.onTap,
  });

  final int index;
  final String label;
  final Color base;
  final IconData icon;
  final bool selected;
  final bool isCorrect;
  final bool isWrongPick;
  final bool dim;
  final int? count;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isCorrect
        ? const Color(0xFF1F9E5B)
        : isWrongPick
        ? const Color(0xFFE8412E)
        : base;
    return Opacity(
      opacity: dim && !isWrongPick ? 0.45 : 1,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: selected
                  ? Border.all(color: Colors.white, width: 3)
                  : null,
            ),
            child: Row(
              children: [
                Icon(icon, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                if (isCorrect)
                  const Icon(Icons.check_circle, color: Colors.white),
                if (isWrongPick) const Icon(Icons.cancel, color: Colors.white),
                if (count != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
