import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/failure.dart';
import '../../core/responsive.dart';
import '../../models/enums.dart';
import '../../state/controllers.dart';
import '../../state/providers.dart';
import '../../shared_widgets/async_view.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  UserRole _role = UserRole.educator;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final c = ref.read(authControllerProvider.notifier);
    try {
      if (_register) {
        await c.register(
          name: _name.text,
          email: _email.text,
          password: _password.text,
          role: _role,
        );
      } else {
        await c.signIn(_email.text, _password.text);
      }
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  Future<void> _demo(UserRole role) async {
    try {
      await ref.read(authControllerProvider.notifier).demoAs(role);
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = ref.watch(authControllerProvider);
    final generator = ref.watch(generatorLabelProvider);
    final t = Theme.of(context);

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: ContentContainer(
            maxWidth: 440,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.bolt, color: t.colorScheme.primary, size: 34),
                    const SizedBox(width: 8),
                    Text(
                      'quizzle',
                      style: t.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Turn any lecture material into a live quiz.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyMedium?.copyWith(
                    color: t.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 28),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(
                                value: false,
                                label: Text('Sign in'),
                              ),
                              ButtonSegment(
                                value: true,
                                label: Text('Register'),
                              ),
                            ],
                            selected: {_register},
                            onSelectionChanged: (s) =>
                                setState(() => _register = s.first),
                          ),
                          const SizedBox(height: 16),
                          if (_register) ...[
                            TextFormField(
                              controller: _name,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: 'Name',
                                prefixIcon: Icon(Icons.person_outline),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextFormField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            autofillHints: const [AutofillHints.email],
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              prefixIcon: Icon(Icons.mail_outline),
                            ),
                            validator: (v) => (v == null || !v.contains('@'))
                                ? 'Enter a valid email'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _password,
                            obscureText: true,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _submit(),
                            decoration: const InputDecoration(
                              labelText: 'Password',
                              prefixIcon: Icon(Icons.lock_outline),
                            ),
                            validator: (v) => (v == null || v.length < 6)
                                ? 'At least 6 characters'
                                : null,
                          ),
                          if (_register) ...[
                            const SizedBox(height: 16),
                            Text('I am a…', style: t.textTheme.labelLarge),
                            const SizedBox(height: 8),
                            SegmentedButton<UserRole>(
                              segments: const [
                                ButtonSegment(
                                  value: UserRole.educator,
                                  label: Text('Educator'),
                                  icon: Icon(Icons.school_outlined),
                                ),
                                ButtonSegment(
                                  value: UserRole.student,
                                  label: Text('Student'),
                                  icon: Icon(Icons.backpack_outlined),
                                ),
                              ],
                              selected: {_role},
                              onSelectionChanged: (s) =>
                                  setState(() => _role = s.first),
                            ),
                          ],
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: busy ? null : _submit,
                            child: busy
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    _register ? 'Create account' : 'Sign in',
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Or jump in with a demo account',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: busy ? null : () => _demo(UserRole.educator),
                        icon: const Icon(Icons.school_outlined),
                        label: const Text('Educator'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: busy ? null : () => _demo(UserRole.student),
                        icon: const Icon(Icons.backpack_outlined),
                        label: const Text('Student'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  'Question generation: $generator',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.outline,
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
