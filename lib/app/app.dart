import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared_widgets/async_view.dart';
import '../state/providers.dart';
import '../state/theme_controller.dart';
import 'router.dart';
import 'theme.dart';

/// The app shell. Both themes are always supplied — the Bauhaus palette is
/// defined in light and dark and the user's choice is persisted — and the
/// boot/failure states are themed too, so the very first frame is already in
/// the design language instead of a bare Material spinner.
class QuizzleApp extends ConsumerStatefulWidget {
  const QuizzleApp({super.key});

  @override
  ConsumerState<QuizzleApp> createState() => _QuizzleAppState();
}

class _QuizzleAppState extends ConsumerState<QuizzleApp> {
  /// A phone that locks mid-question, or a tab left in the background, comes
  /// back to a socket that may be dead or waiting out a long backoff. On
  /// resume (on web: the tab becoming visible again) check the link at once.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onResume: () {
      final ready = ref.read(backendReadyProvider).valueOrNull;
      ready?.resumeRealtime();
    },
  );

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(backendReadyProvider);
    final themeMode = ref.watch(themeModeControllerProvider);

    Widget boot(Widget child) => MaterialApp(
      title: 'quizzle',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      home: Scaffold(body: SafeArea(child: child)),
    );

    return ready.when(
      loading: () => boot(const LoadingView(label: 'Starting quizzle')),
      error: (e, _) => boot(
        ErrorView(
          title: 'quizzle could not start',
          message: '$e',
          onRetry: () => ref.invalidate(backendReadyProvider),
        ),
      ),
      data: (_) {
        final router = ref.watch(routerProvider);
        return MaterialApp.router(
          title: 'quizzle',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeMode,
          routerConfig: router,
        );
      },
    );
  }
}
