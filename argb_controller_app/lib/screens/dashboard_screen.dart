import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/effect_capabilities.dart';
import 'package:argb_controller/models/led_color.dart';
import 'package:argb_controller/models/scene.dart';
import 'package:argb_controller/providers/device_provider.dart';
import 'package:argb_controller/screens/devices_screen.dart';
import 'package:argb_controller/state/app_state.dart';
import 'package:argb_controller/state/connection_controller.dart';
import 'package:argb_controller/theme/app_colors.dart';
import 'package:argb_controller/widgets/brightness_slider.dart';
import 'package:argb_controller/widgets/color_wheel.dart';
import 'package:argb_controller/widgets/effect_selector.dart';
import 'package:argb_controller/widgets/led_strip_preview.dart';
import 'package:argb_controller/widgets/palette_editor.dart';

/// The primary control dashboard for the ESP32 Smart ARGB LED Controller.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  int _selectedTabIndex = 0; // 0: Color, 1: Effects, 2: Scenes

  void _togglePower() {
    ref.read(deviceProvider.notifier).togglePower();
  }

  void _updateColor(LedColor newColor) {
    // CRITICAL: Updates ONLY the color parameter.
    // The active animation effect is NOT stopped or changed to staticColor.
    ref.read(deviceProvider.notifier).setColor(newColor);
  }

  void _updateBrightness(int brightness) {
    ref.read(deviceProvider.notifier).setBrightness(brightness);
  }

  void _updateEffect(EffectType effectType) {
    ref.read(deviceProvider.notifier).setEffect(effectType);
  }

  void _updateSpeed(int speed) {
    ref.read(deviceProvider.notifier).setSpeed(speed);
  }

  void _updateIntensity(int intensity) {
    ref.read(deviceProvider.notifier).setIntensity(intensity);
  }

  void _updatePalette(List<LedColor> palette) {
    ref.read(deviceProvider.notifier).setPalette(palette);
  }

  void _updateSecondary(LedColor color) {
    ref.read(deviceProvider.notifier).setSecondaryColor(color);
  }

  void _openDevices() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DevicesScreen()));
  }

  Widget _statusLine(AppMode mode, DeviceConnection conn) {
    IconData icon = Icons.wifi;
    Color color = AppColors.success;
    String text = 'Simülasyon Modu';
    if (mode == AppMode.device) {
      final name = conn.device?.name ?? 'Cihaz seçilmedi';
      switch (conn.status) {
        case LinkStatus.connected:
          text = '$name (Bağlı)';
        case LinkStatus.connecting:
        case LinkStatus.authenticating:
          icon = Icons.sync;
          color = AppColors.secondary;
          text = '$name (Bağlanıyor…)';
        case LinkStatus.reconnecting:
          icon = Icons.wifi_off;
          color = AppColors.warning;
          text = '$name (Çevrimdışı)';
        case LinkStatus.needsPairing:
          icon = Icons.link_off;
          color = AppColors.warning;
          text = '$name (Eşleştirme gerekli)';
        case LinkStatus.idle:
          icon = Icons.portable_wifi_off;
          color = AppColors.textHint;
          text = 'Bağlı cihaz yok';
      }
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }

  /// Gerçek cihaz modunda: bağlantı uyarısı ve kanal seçici.
  List<Widget> _deviceBanners(DeviceConnection conn, int selectedChannel) {
    final widgets = <Widget>[];
    if (conn.status != LinkStatus.connected) {
      String msg;
      switch (conn.status) {
        case LinkStatus.needsPairing:
          msg = conn.error ?? 'Bu cihaz için eşleştirme gerekli.';
        case LinkStatus.reconnecting:
          msg = 'Cihaz çevrimdışı — yeniden bağlanılıyor (deneme ${conn.attempt}). '
              'Değişiklikler cihaza ulaşmaz.';
        case LinkStatus.idle:
          msg = 'Bir cihaz seçilmedi. Cihazlar ekranından ESP32 seçin veya simülasyona dönün.';
        default:
          msg = 'Cihaza bağlanılıyor…';
      }
      widgets.add(Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(child: Text(msg, style: const TextStyle(fontSize: 12))),
            TextButton(
              onPressed: conn.status == LinkStatus.reconnecting
                  ? () => ref.read(connectionProvider.notifier).retryNow()
                  : _openDevices,
              child: Text(conn.status == LinkStatus.reconnecting ? 'Şimdi dene' : 'Cihazlar'),
            ),
          ],
        ),
      ));
    }
    if (conn.channels.isNotEmpty) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Wrap(
          spacing: 8,
          children: [
            for (var ch = 1; ch <= 4; ch++)
              ChoiceChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                label: Text('Kanal $ch${(conn.channels[ch]?.enabled ?? false) ? '' : ' (kapalı)'}'),
                selected: selectedChannel == ch,
                onSelected: (conn.channels[ch]?.enabled ?? false)
                    ? (_) => ref.read(selectedChannelProvider.notifier).state = ch
                    : null,
              ),
          ],
        ),
      ));
    }
    return widgets;
  }

  void _applyScene(Scene scene) {
    ref.read(deviceProvider.notifier).applyScene(scene);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Sahne uygulandı: ${scene.name}'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  String _getEffectName(EffectType type) {
    if (type == EffectType.staticColor) return 'Sabit Renk';
    final match = Effect.builtInEffects.where((e) => e.type == type);
    if (match.isNotEmpty) return match.first.name;
    return type.name;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(deviceProvider);
    final currentColor = state.color.toColor();
    final mode = ref.watch(appModeProvider);
    final conn = ref.watch(connectionProvider);
    final selectedChannel = ref.watch(selectedChannelProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Column(
          children: [
            const Text(
              'ESP32 ARGB CONTROLLER',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 2),
            _statusLine(mode, conn),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.devices_other_rounded),
            tooltip: 'Cihazlar',
            onPressed: _openDevices,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Yenile',
            onPressed: () {
              if (mode == AppMode.device) {
                ref.read(connectionProvider.notifier).requestState();
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(mode == AppMode.device
                      ? 'Cihaz durumu isteniyor…'
                      : 'Cihaz durumu güncellendi (Simülasyon)'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            // Kırılma noktaları: <650 kompakt tek sütun, 650–950 geniş kartlar/çiftler, ≥950 iki sütun
            final wide = w >= 950;
            final medium = !wide && w >= 650;
            final pad = w < 650 ? 12.0 : 20.0;
            final contentW = (w - pad * 2).clamp(0.0, 1400.0);
            final colW = wide ? (contentW - 16) * 0.42 : contentW;
            final wheelSize = (wide ? (contentW - 16) * 0.58 - 40 : contentW - 32).clamp(160.0, 240.0);

            final banners = mode == AppMode.device ? _deviceBanners(conn, selectedChannel) : <Widget>[];
            final power = _buildPowerCard(state, currentColor,
                ledCount: mode == AppMode.device ? conn.channels[selectedChannel]?.ledCount : null);
            final strip = LedStripPreview(
              isOn: state.isOn,
              color: state.color,
              effectType: state.effectType,
              brightness: state.brightness,
              speed: state.speed,
              pixelCount: 20,
            );
            final colorInfo = _buildColorInfoCard(state, currentColor);
            final brightness = BrightnessSlider(
              brightness: state.brightness,
              onBrightnessChanged: _updateBrightness,
              activeColor: state.isOn ? currentColor : AppColors.textHint,
            );
            final telemetry = _buildTelemetryCard();
            const gap = SizedBox(height: 12);

            Widget pair(Widget l, Widget r) => IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [Expanded(child: l), const SizedBox(width: 12), Expanded(child: r)],
                  ),
                );

            final tabs = <Widget>[
              _buildTabSwitcher(),
              gap,
              ..._tabContent(state, mode, conn, wheelSize),
            ];

            final List<Widget> children;
            if (wide) {
              children = [
                ...banners,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: colW,
                      child: Column(children: [power, gap, strip, gap, colorInfo, gap, brightness, gap, telemetry]),
                    ),
                    const SizedBox(width: 16),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: tabs)),
                  ],
                ),
              ];
            } else if (medium) {
              children = [
                ...banners,
                pair(power, colorInfo),
                gap,
                strip,
                gap,
                brightness,
                gap,
                ...tabs,
                gap,
                telemetry,
              ];
            } else {
              children = [
                ...banners,
                power,
                gap,
                strip,
                gap,
                colorInfo,
                gap,
                brightness,
                gap,
                ...tabs,
                gap,
                telemetry,
              ];
            }

            return SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.symmetric(horizontal: pad, vertical: 8),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1400),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Sekme içeriği (Renk çarkı / Efektler / Sahneler) — tüm düzenlerde aynı bileşenler.
  List<Widget> _tabContent(dynamic state, AppMode mode, DeviceConnection conn, double wheelSize) {
    return [
    // ── 6. Tab Content ─────────────────────────────────────
    if (_selectedTabIndex == 0) ...[
      // Active effect reminder banner when in color tab
      if (state.effectType != EffectType.staticColor)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Row(
                  children: [
                    const Icon(Icons.auto_awesome, size: 16, color: AppColors.secondary),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Aktif Efekt: ${_getEffectName(state.effectType)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => _updateEffect(EffectType.staticColor),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'Sabit Renk Yap',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.secondary,
                  ),
                ),
              ),
            ],
          ),
        ),

      // Color Wheel View
      Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.06),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        child: ColorWheel(
          color: state.color,
          onColorChanged: _updateColor,
          size: wheelSize,
        ),
      ),
      const SizedBox(height: 12),
      PaletteEditor(
        palette: state.palette,
        baseColor: state.color,
        wheelSize: (wheelSize * 0.85).clamp(150.0, 200.0),
        enabled: mode != AppMode.device || conn.info == null || conn.info!.supportsPalette,
        onChanged: _updatePalette,
      ),
    ] else if (_selectedTabIndex == 1) ...[
      if (state.palette.isNotEmpty) ...[
        _paletteNote(state),
        const SizedBox(height: 12),
      ],
      // Effects View
      EffectSelector(
        selectedType: state.effectType,
        onEffectSelected: _updateEffect,
        speed: state.speed,
        onSpeedChanged: _updateSpeed,
        intensity: state.intensity,
        onIntensityChanged: _updateIntensity,
        supportedEffects: mode == AppMode.device ? conn.info?.supportedEffects : null,
      ),
      if (effectCaps(state.effectType).color2 && state.palette.isEmpty) ...[
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          child: Column(
            children: [
              const Text(
                'İKİNCİ RENK',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              ColorWheel(
                color: state.secondaryColor,
                onColorChanged: _updateSecondary,
                size: (wheelSize * 0.85).clamp(150.0, 200.0),
              ),
            ],
          ),
        ),
      ],
    ] else ...[
      // Scenes View
      _buildScenesGrid(),
    ],
    ];
  }

  /// Efektler sekmesinde: palet etkinken efektin yalnızca palet renklerini kullandığını belirtir.
  Widget _paletteNote(dynamic state) {
    final palette = state.palette as List<LedColor>;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        children: [
          for (final c in palette)
            Container(
              width: 14,
              height: 14,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(color: c.toColor(), shape: BoxShape.circle),
            ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Palet etkin (${palette.length} renk): efekt yalnızca palet renklerini kullanır.',
              style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _selectedTabIndex = 0),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Düzenle', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.secondary)),
          ),
        ],
      ),
    );
  }

  Widget _buildPowerCard(dynamic state, Color currentColor, {int? ledCount}) {
    final isOn = state.isOn as bool;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isOn
              ? currentColor.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.06),
          width: 1.5,
        ),
        boxShadow: [
          if (isOn)
            BoxShadow(
              color: currentColor.withValues(alpha: 0.15),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Power Button with Glow Ring
          InkWell(
            onTap: _togglePower,
            borderRadius: BorderRadius.circular(30),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOn ? currentColor : AppColors.surfaceLight,
                boxShadow: isOn
                    ? [
                        BoxShadow(
                          color: currentColor.withValues(alpha: 0.7),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
                border: Border.all(
                  color: isOn ? Colors.white : AppColors.textHint,
                  width: 2,
                ),
              ),
              child: Icon(
                Icons.power_settings_new_rounded,
                size: 28,
                color: isOn ? Colors.white : AppColors.textHint,
              ),
            ),
          ),
          const SizedBox(width: 16),

          // Device status description
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      isOn ? 'GÜÇ AÇIK' : 'GÜÇ KAPALI',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: isOn ? Colors.white : AppColors.textHint,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isOn ? AppColors.success : AppColors.error,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  isOn
                      ? '${ledCount ?? 60} LED Aktif • Parlaklık: ${((state.brightness / 255.0) * 100).round()}%'
                      : 'Şerit bekleme modunda',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),

          // Active Mode Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _getEffectName(state.effectType as EffectType),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isOn ? AppColors.primaryLight : AppColors.textHint,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColorInfoCard(dynamic state, Color currentColor) {
    final hexCode = (state.color as LedColor).toHex();
    final hsv = (state.color as LedColor).toHSV();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Color circle swatch
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: currentColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: currentColor.withValues(alpha: 0.5),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),

          // Color Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hexCode,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'RGB(${state.color.r}, ${state.color.g}, ${state.color.b})  •  H:${hsv.hue.round()}° S:${(hsv.saturation * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),

          // Quick set to Warm White button
          Tooltip(
            message: 'Sıcak Beyaz Renk',
            child: IconButton(
              onPressed: () => _updateColor(LedColor.warmWhite),
              icon: const Icon(
                Icons.wb_incandescent_outlined,
                color: AppColors.warning,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabSwitcher() {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          _buildTabItem(0, 'Renk Çarkı', Icons.color_lens_rounded),
          _buildTabItem(1, 'Efektler', Icons.auto_awesome_rounded),
          _buildTabItem(2, 'Sahneler', Icons.bookmark_rounded),
        ],
      ),
    );
  }

  Widget _buildTabItem(int index, String label, IconData icon) {
    final isSelected = _selectedTabIndex == index;

    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _selectedTabIndex = index),
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected ? AppColors.primaryLight : AppColors.textHint,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected ? Colors.white : AppColors.textSecondary,
                ),
              ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScenesGrid() {
    final scenes = Scene.builtInScenes;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: scenes.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 300,
        mainAxisExtent: 60,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemBuilder: (context, index) {
        final scene = scenes[index];
        final sceneColor = scene.primaryColor.toColor();

        return InkWell(
          onTap: () => _applyScene(scene),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.06),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: sceneColor.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: sceneColor.withValues(alpha: 0.5),
                      width: 1,
                    ),
                  ),
                  child: Icon(scene.icon, size: 20, color: sceneColor),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        scene.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Parlaklık: ${((scene.brightness / 255.0) * 100).round()}%',
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.textHint,
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

  Widget _buildTelemetryCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.04),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _TelemetryItem(label: 'Çip', value: 'ESP32-S3'),
          _TelemetryItem(label: 'LED Türü', value: 'WS2812B'),
          _TelemetryItem(label: 'Pin', value: 'GPIO 2'),
          _TelemetryItem(label: 'Gecikme', value: '12 ms'),
        ],
      ),
    );
  }
}

class _TelemetryItem extends StatelessWidget {
  final String label;
  final String value;

  const _TelemetryItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: AppColors.textHint,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
