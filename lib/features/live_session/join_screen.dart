import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../core/ids.dart';
import '../../shared_widgets/answer_tile.dart';
import '../../shared_widgets/app_scaffold.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/bauhaus_button.dart';
import '../../state/providers.dart';

/// Enter the code the teacher has on screen. The loud register: display type,
/// one pill (the code field is one of the two things allowed to be round) and
/// the four Bauhaus primitives as the only decoration.
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
  String? _error;

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
      setState(() => _error = 'Enter the whole code shown on screen.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(sessionRepositoryProvider);
      final session = await repo.findByJoinCode(code);
      if (session == null) {
        throw Exception('No live session with code $code.');
      }
      await repo.joinSession(joinCode: code, student: user);
      if (mounted) context.go('/play/${session.id}');
    } catch (e) {
      final message = e.toString().replaceFirst('Exception: ', '');
      if (mounted) {
        setState(() => _error = message);
        showSnack(context, message, error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);

    return AppScaffold(
      title: 'Join a quiz',
      eyebrow: 'Live session',
      currentRoute: '/join',
      padBody: true,
      maxContentWidth: 520,
      body: ListView(
        padding: EdgeInsets.zero,
        children: staggered([
          const SizedBox(height: 8),
          const _ShapeRow(),
          const SizedBox(height: 20),
          Semantics(
            header: true,
            child: Text(
              'Enter join code',
              style: theme.textTheme.displaySmall,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Six characters, on your teacher’s screen.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          Semantics(
            textField: true,
            label: 'Join code',
            hint: 'Six letters and numbers',
            excludeSemantics: false,
            child: TextField(
              controller: _code,
              autofocus: true,
              textAlign: TextAlign.center,
              textInputAction: TextInputAction.go,
              textCapitalization: TextCapitalization.characters,
              // From the theme: the code grows with the system text scale.
              style: theme.textTheme.displayMedium?.copyWith(
                letterSpacing: 10,
              ),
              inputFormatters: [
                LengthLimitingTextInputFormatter(8),
                FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                _UpperCaseFormatter(),
              ],
              decoration: InputDecoration(
                hintText: 'ABC123',
                hintStyle: theme.textTheme.displayMedium?.copyWith(
                  color: t.inkSecondary,
                  letterSpacing: 10,
                ),
                errorText: _error,
                // The join-code field is the one permitted pill besides chips.
                border: OutlineInputBorder(
                  borderRadius: QuizzleTokens.pillRadius,
                  borderSide: BorderSide(color: t.line, width: t.borderWidth),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: QuizzleTokens.pillRadius,
                  borderSide: BorderSide(color: t.line, width: t.borderWidth),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: QuizzleTokens.pillRadius,
                  borderSide: BorderSide(color: t.focusRing, width: 3),
                ),
                errorBorder: OutlineInputBorder(
                  borderRadius: QuizzleTokens.pillRadius,
                  borderSide: BorderSide(color: t.wrongInk, width: t.borderWidth),
                ),
                focusedErrorBorder: OutlineInputBorder(
                  borderRadius: QuizzleTokens.pillRadius,
                  borderSide: BorderSide(color: t.wrongInk, width: 3),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _join(),
            ),
          ),
          const SizedBox(height: 20),
          BauhausButton.primary(
            label: 'Join the quiz',
            trailingIcon: Icons.arrow_forward,
            expand: true,
            busy: _busy,
            onPressed: _busy ? null : _join,
          ),
          const SizedBox(height: 18),
          Container(
            decoration: t.plane(fill: t.surface),
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 18, color: t.ink),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'No code? A live session has to be running. You can still '
                    'practise a published quiz from the home screen.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: t.inkSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: BauhausButton.ghost(
              label: 'Back to home',
              icon: Icons.home_outlined,
              onPressed: () => context.go('/'),
            ),
          ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}

/// The four answer primitives in their four fills — the app's signature, used
/// once on this screen and nowhere else on it.
class _ShapeRow extends StatelessWidget {
  const _ShapeRow();

  @override
  Widget build(BuildContext context) {
    final fills = QuizzleTokens.of(context).answerFills;
    return ExcludeSemantics(
      child: Row(
        children: [
          for (var i = 0; i < AnswerShape.values.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CustomPaint(
                  painter: AnswerShapePainter(
                    AnswerShape.values[i],
                    fills[i % fills.length],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
      composing: TextRange.empty,
    );
  }
}
