import 'package:flutter/material.dart';

import 'package:argb_controller/theme/app_colors.dart';

/// 0..4 çubuklu Wi-Fi sinyal göstergesi.
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.bars});
  final int bars;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 1; i <= 4; i++)
            Container(
              width: 4,
              height: 4.0 + i * 3,
              margin: const EdgeInsets.only(left: 2),
              color: i <= bars ? AppColors.secondary : AppColors.surfaceLight,
            ),
        ],
      );
}
