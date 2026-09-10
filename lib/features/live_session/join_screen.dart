import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../core/responsive.dart';
import '../../state/providers.dart';
import '../../shared_widgets/app_scaffold.dart';
import '../../shared_widgets/async_view.dart';

class JoinScreen extends ConsumerStatefulWidget {
  const JoinScreen({super.key, this.prefillCode});
  final String? prefillCode;

  @override
  ConsumerState<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends ConsumerState<JoinScreen> {
  late final TextEditingController _code = TextEditingController(
    text: widget.prefillCode ?? '',
  );
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      context.go('/login');
      return;
    }
    final code = normalizeJoinCode(_code.text);
    if (code.length < 4) {
      showSnack(context, 'Enter the code shown on screen.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final repo = ref.read(sessionRepositoryProvider);
      final session = await repo.findByJoinCode(code);
      if (session == null) {
        throw Exception('No live session with code $code.');
      }
      await repo.joinSession(joinCode: code, student: user);
      if (mounted) context.go('/play/${session.id}');
    } catch (e) {
      if (mounted) {
        showSnack(
          context,
          e.toString().replaceFirst('Exception: ', ''),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Join a quiz',
      currentRoute: '/join',
      body: Center(
        child: ContentContainer(
          maxWidth: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.tag,
                size: 44,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'Enter join code',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _code,
                textAlign: TextAlign.center,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 6,
                ),
                decoration: const InputDecoration(hintText: 'ABC123'),
                onSubmitted: (_) => _join(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _join,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Join'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
