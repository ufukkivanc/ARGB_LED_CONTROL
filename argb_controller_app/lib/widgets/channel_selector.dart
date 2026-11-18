import 'package:flutter/material.dart';

import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/state/channel_selection.dart';
import 'package:argb_controller/theme/app_colors.dart';

/// CH1–CH4 çoklu seçim (checkbox). Kurallar: [ChannelSelection]; iPhone panelinde aynısı vardır.
/// GPIO numaraları bilerek GÖSTERİLMEZ (sabit donanım eşlemesi, kullanıcıya yalnızca kanal adı).
class ChannelSelector extends StatelessWidget {
  const ChannelSelector({
    super.key,
    required this.channels,
    required this.selection,
    required this.onToggle,
    required this.onSelectAll,
    required this.onClear,
  });

  final Map<int, ChannelState> channels;
  final ChannelSelection selection;
  final ValueChanged<int> onToggle;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final enabledCount = channels.values.where((c) => c.enabled && c.ledCount > 0).length;
    final none = selection.isEmpty;
    final names = selection.sortedChannels.map((c) => 'CH$c').join(', ');
    return Container(
      key: const Key('channel_selector'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('KANALLAR',
                    style: TextStyle(fontSize: 12, letterSpacing: 1.1, color: AppColors.textSecondary)),
              ),
              TextButton(
                key: const Key('ch_select_all'),
                onPressed: enabledCount == 0 ? null : onSelectAll,
                child: const Text('Tümü'),
              ),
              TextButton(
                key: const Key('ch_select_none'),
                onPressed: none ? null : onClear,
                child: const Text('Hiçbiri'),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var ch = 1; ch <= kMaxChannels; ch++) _tile(ch),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            none
                ? 'Kanal seçilmedi: renk ve efekt değişiklikleri gönderilmez.'
                : 'Değişiklikler yalnızca seçili kanallara uygulanır: $names',
            key: const Key('ch_select_hint'),
            style: TextStyle(fontSize: 12, color: none ? AppColors.warning : AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _tile(int ch) {
    final c = channels[ch];
    final enabled = c != null && c.enabled && c.ledCount > 0;
    final selected = enabled && selection.isSelected(ch);
    return Semantics(
      label: 'CH$ch',
      checked: selected,
      enabled: enabled,
      child: InkWell(
        key: Key('ch_select_$ch'),
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? () => onToggle(ch) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.fromLTRB(4, 2, 12, 2),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary.withValues(alpha: 0.22) : AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.primary : Colors.white.withValues(alpha: 0.10),
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                key: Key('ch_checkbox_$ch'),
                value: selected,
                onChanged: enabled ? (_) => onToggle(ch) : null,
                activeColor: AppColors.primary,
                visualDensity: VisualDensity.compact,
              ),
              Text(
                'CH$ch',
                style: TextStyle(
                  fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                  color: enabled ? AppColors.textPrimary : AppColors.textHint,
                ),
              ),
              if (c != null && !enabled)
                const Text(' (kapalı)', style: TextStyle(fontSize: 11, color: AppColors.textHint)),
              if (c != null && enabled && !c.power)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.power_settings_new, size: 14, color: AppColors.textHint),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
