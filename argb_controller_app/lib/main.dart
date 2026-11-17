import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:argb_controller/screens/dashboard_screen.dart';
import 'package:argb_controller/state/app_state.dart';
import 'package:argb_controller/state/connection_controller.dart';
import 'package:argb_controller/theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: ArgbControllerApp()));
}

class ArgbControllerApp extends ConsumerStatefulWidget {
  /// [bootstrap] false ise açılışta kayıtlı cihaza otomatik bağlanma yapılmaz (testler).
  const ArgbControllerApp({super.key, this.bootstrap = true});
  final bool bootstrap;

  @override
  ConsumerState<ArgbControllerApp> createState() => _ArgbControllerAppState();
}

class _ArgbControllerAppState extends ConsumerState<ArgbControllerApp> {
  @override
  void initState() {
    super.initState();
    if (widget.bootstrap) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    }
  }

  /// Önceki oturum gerçek cihaz modundaysa son kullanılan cihaza bağlanır.
  Future<void> _bootstrap() async {
    final storage = ref.read(settingsStorageProvider);
    final mode = await storage.loadMode();
    if (mode != AppMode.device) return;
    final devices = await storage.loadDevices();
    if (devices.isEmpty || !mounted) return;
    await ref.read(appModeProvider.notifier).set(AppMode.device);
    await ref.read(connectionProvider.notifier).connect(devices.last.toFound());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ARGB Controller',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const DashboardScreen(),
    );
  }
}
