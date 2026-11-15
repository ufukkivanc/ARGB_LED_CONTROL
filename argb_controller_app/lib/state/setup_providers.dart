import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/state/app_state.dart';
import 'package:argb_controller/state/setup_controller.dart';

class SetupArgs {
  final FoundDevice? device;
  final bool pairOnly;
  const SetupArgs({this.device, this.pairOnly = false});

  @override
  bool operator ==(Object other) =>
      other is SetupArgs &&
      other.device?.id == device?.id &&
      other.device?.host == device?.host &&
      other.pairOnly == pairOnly;

  @override
  int get hashCode => Object.hash(device?.id, device?.host, pairOnly);
}

/// İstemci adı: cihazdaki eşleştirme listesinde görünür (yalnızca ASCII).
String defaultClientName() {
  if (kIsWeb) return 'Flutter Web';
  return 'Flutter ${defaultTargetPlatform.name}';
}

final setupProvider =
    StateNotifierProvider.autoDispose.family<SetupController, SetupState, SetupArgs>((ref, args) {
  return SetupController(
    tokens: ref.read(tokenStoreProvider),
    discovery: ref.read(discoveryProvider),
    clientName: defaultClientName(),
    pairOnly: args.pairOnly,
    device: args.device,
    onDeviceKnown: (d) => ref
        .read(knownDevicesProvider.notifier)
        .upsert(KnownDevice(id: d.id, name: d.name, host: d.host, port: d.port)),
  );
});
