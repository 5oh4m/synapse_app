import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/env.dart';
import '../../core/responsive.dart';
import '../../models/enums.dart';
import '../../state/controllers.dart';
import '../../state/providers.dart';
import '../../state/theme_controller.dart';
import '../../shared_widgets/async_view.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        leading: BackButton(onPressed: () => context.go('/')),
      ),
      body: user == null
          ? const LoadingView()
          : ContentContainer(
              maxWidth: 520,
              child: ListView(
                children: [
                  const SizedBox(height: 8),
                  CircleAvatar(
                    radius: 36,
                    child: Text(
                      user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                      style: const TextStyle(fontSize: 28),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(child: Text(user.name, style: t.textTheme.titleLarge)),
                  Center(
                    child: Text(
                      user.email,
                      style: t.textTheme.bodyMedium?.copyWith(
                        color: t.colorScheme.outline,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Chip(
                      label: Text(
                        user.role == UserRole.educator ? 'Educator' : 'Student',
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Card(
                    child: SwitchListTile(
                      secondary: Icon(
                        t.brightness == Brightness.dark
                            ? Icons.dark_mode_outlined
                            : Icons.light_mode_outlined,
                      ),
                      title: const Text('Dark mode'),
                      subtitle: const Text('Switch between light and dark theme'),
                      value: t.brightness == Brightness.dark,
                      onChanged: (dark) =>
                          ref.read(themeModeControllerProvider.notifier).setDark(dark),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.dns_outlined),
                          title: const Text('Backend'),
                          subtitle: Text(Env.backend),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.auto_awesome_outlined),
                          title: const Text('Question generator'),
                          subtitle: Text(ref.watch(generatorLabelProvider)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await ref.read(authControllerProvider.notifier).signOut();
                      if (context.mounted) context.go('/login');
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            ),
    );
  }
}
