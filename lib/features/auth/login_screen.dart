import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../core/failure.dart';
import '../../models/enums.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/bauhaus_button.dart';
import '../../shared_widgets/bauhaus_card.dart';
import '../../shared_widgets/labels.dart';
import '../../state/controllers.dart';
import '../../state/providers.dart';

/// Sign in / register.
///
/// Bauhaus composition: a single geometric mark, a heavy display title, and a
/// flat form plane. Everything staggers in 40ms apart on first build; nothing
/// rests at opacity 0.
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
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = ref.watch(authControllerProvider);
    final generator = ref.watch(generatorLabelProvider);
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final gutter = t.gutterFor(MediaQuery.sizeOf(context).width);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: staggered([
                  // The one geometric accent on this screen.
                  Row(
                    children: [
                      const _BrandMark(size: 44),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const EyebrowLabel('AI live quizzes'),
                            const SizedBox(height: 4),
                            Semantics(
                              header: true,
                              child: Text(
                                'quizzle',
                                style: theme.textTheme.displayMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: t.proseMaxWidth),
                    child: Text(
                      'Turn any lecture material into a live quiz your class '
                      'can play in the room.',
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                  const SizedBox(height: 24),
                  BauhausCard(
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
                            showSelectedIcon: false,
                            onSelectionChanged: (s) =>
                                setState(() => _register = s.first),
                          ),
                          const SizedBox(height: 18),
                          if (_register) ...[
                            TextFormField(
                              controller: _name,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: 'Name',
                                prefixIcon: Icon(Icons.person_outline),
                              ),
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? 'Tell us your name'
                                  : null,
                            ),
                            const SizedBox(height: 14),
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
                          const SizedBox(height: 14),
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
                            const SizedBox(height: 18),
                            const EyebrowLabel('I am a'),
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
                              showSelectedIcon: false,
                              onSelectionChanged: (s) =>
                                  setState(() => _role = s.first),
                            ),
                          ],
                          const SizedBox(height: 22),
                          BauhausButton.primary(
                            label: _register ? 'Create account' : 'Sign in',
                            trailingIcon: Icons.arrow_forward,
                            expand: true,
                            busy: busy,
                            onPressed: busy ? null : _submit,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const EyebrowLabel('Or jump straight in'),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: BauhausButton.secondary(
                          label: 'Educator',
                          icon: Icons.school_outlined,
                          semanticLabel: 'Continue as a demo educator',
                          expand: true,
                          onPressed: busy
                              ? null
                              : () => _demo(UserRole.educator),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: BauhausButton.secondary(
                          label: 'Student',
                          icon: Icons.backpack_outlined,
                          semanticLabel: 'Continue as a demo student',
                          expand: true,
                          onPressed: busy ? null : () => _demo(UserRole.student),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: t.plane(fill: t.surface),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ExcludeSemantics(
                          child: Container(width: 12, height: 12, color: t.warn),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const EyebrowLabel('Question generation'),
                              const SizedBox(height: 4),
                              Text(
                                generator,
                                // inkSecondary is safe at any size on a
                                // surface; never on the ice ground.
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: t.inkSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The brand mark: a filled square with a quarter circle cut into it. One
/// accent, once, per DESIGN.md.
class _BrandMark extends StatelessWidget {
  const _BrandMark({this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _BrandPainter(t.ink, t.warn)),
      ),
    );
  }
}

class _BrandPainter extends CustomPainter {
  const _BrandPainter(this.ink, this.accent);

  final Color ink;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = ink,
    );
    canvas.drawPath(
      Path()
        ..moveTo(size.width, 0)
        ..arcToPoint(
          Offset(size.width, size.height),
          radius: Radius.circular(size.height),
          clockwise: true,
        )
        ..lineTo(size.width, 0)
        ..close(),
      Paint()..color = accent,
    );
  }

  @override
  bool shouldRepaint(_BrandPainter old) =>
      old.ink != ink || old.accent != accent;
}
