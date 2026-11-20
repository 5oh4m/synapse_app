import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

/// Generate a quiz from lecture material. The calm register: three numbered
/// steps, each a flat plane on a 12-column rhythm, nothing shouting.
class CreateQuizScreen extends ConsumerStatefulWidget {
  const CreateQuizScreen({super.key, this.contentItemId});

  final String? contentItemId;

  @override
  ConsumerState<CreateQuizScreen> createState() => _CreateQuizScreenState();
}

class _CreateQuizScreenState extends ConsumerState<CreateQuizScreen> {
  final _title = TextEditingController();
  final _subject = TextEditingController();
  final _text = TextEditingController();

  ContentType _sourceType = ContentType.text;
  String? _fileName;
  int _pageCount = 1;
  int _count = 10;
  bool _loadingExisting = false;
  bool _extracting = false;
  String? _sourceError;

  final Map<Difficulty, int> _mix = {
    Difficulty.easy: 3,
    Difficulty.medium: 5,
    Difficulty.hard: 2,
  };

  @override
  void initState() {
    super.initState();
    _text.addListener(_clearSourceError);
    if (widget.contentItemId != null) _loadExisting(widget.contentItemId!);
  }

  void _clearSourceError() {
    if (_sourceError != null && _text.text.trim().length >= 40) {
      setState(() => _sourceError = null);
    }
  }

  Future<void> _loadExisting(String id) async {
    setState(() => _loadingExisting = true);
    try {
      final item = await ref.read(contentRepositoryProvider).get(id);
      _title.text = item.title;
      _subject.text = item.subject ?? '';
      _text.text = item.extractedText;
      _sourceType = item.fileType;
      _fileName = item.fileUrl;
      _pageCount = item.pageCount;
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _loadingExisting = false);
    }
  }

  @override
  void dispose() {
    _text.removeListener(_clearSourceError);
    _title.dispose();
    _subject.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const [
        'pdf',
        'ppt',
        'pptx',
        'png',
        'jpg',
        'jpeg',
        'txt',
        'md',
      ],
    );
    if (file == null) return;
    final extractor = ref.read(contentExtractorProvider);
    setState(() {
      _fileName = file.name;
      _sourceType = extractor.typeForExtension(file.name);
      if (_title.text.isEmpty) {
        _title.text = file.name.replaceAll(RegExp(r'\.[^.]+$'), '');
      }
      _extracting = true;
    });
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      if (mounted) {
        setState(() => _extracting = false);
        showSnack(
          context,
          'Could not read the file on this platform. Paste the text instead.',
          error: true,
        );
      }
      return;
    }
    try {
      final extracted = await extractor.extract(bytes: bytes, fileName: file.name);
      if (!mounted) return;
      setState(() {
        _pageCount = extracted.pageCount;
        if (extracted.text.isNotEmpty) _text.text = extracted.text;
      });
      if (extracted.text.trim().length < 40 && mounted) {
        showSnack(
          context,
          _sourceType == ContentType.image
              ? 'On-device OCR is not bundled. Paste the text from the image below.'
              : (extracted.message ??
                    'Only partial text could be extracted here. Review or paste it '
                    'below — the Node backend does full extraction.'),
        );
      }
    } catch (e) {
      if (mounted) {
        showSnack(
          context,
          'Failed to extract text from file: $e',
          error: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _extracting = false);
      }
    }
  }

  Future<void> _generate() async {
    final text = _text.text.trim();
    if (text.length < 40) {
      setState(
        () => _sourceError = 'Add at least a paragraph of source text '
            '(${text.length} of 40 characters).',
      );
      return;
    }
    if (_mix.values.fold<int>(0, (a, b) => a + b) == 0) {
      showSnack(context, 'Pick a difficulty mix.', error: true);
      return;
    }
    final params = GenerateParams(
      title: _title.text.trim().isEmpty ? 'Untitled quiz' : _title.text.trim(),
      subject: _subject.text.trim(),
      sourceType: _sourceType,
      rawText: text,
      pageCount: _pageCount,
      count: _count,
      difficultyMix: Map.of(_mix),
      fileName: _fileName,
    );
    try {
      final quizId = await ref
          .read(quizCreationControllerProvider.notifier)
          .generate(params);
      if (mounted) context.go('/quiz/$quizId/review');
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final generation = ref.watch(quizCreationControllerProvider);
    final busy = generation.isLoading || _loadingExisting || _extracting;
    final generator = ref.watch(generatorLabelProvider);
    final gutter = t.gutterFor(MediaQuery.sizeOf(context).width);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const EyebrowLabel('Author'),
            Text('New quiz', style: theme.appBarTheme.titleTextStyle),
          ],
        ),
        leading: BauhausIconButton(
          icon: Icons.arrow_back,
          tooltip: 'Back',
          semanticLabel: 'Go back without generating',
          bordered: false,
          onPressed: () => context.go('/'),
        ),
      ),
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: busy,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: EdgeInsets.symmetric(
                  horizontal: gutter,
                  vertical: gutter,
                ),
                children: staggered([
                  _Step(
                    number: 1,
                    title: 'Add lecture material',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            BauhausButton.secondary(
                              label: _extracting
                                  ? 'Extracting text…'
                                  : 'Choose PDF, slides or image',
                              icon: _extracting
                                  ? Icons.hourglass_top
                                  : Icons.attach_file,
                              onPressed: busy ? null : _pickFile,
                            ),
                            if (_extracting)
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            if (_fileName != null)
                              BauhausChip(
                                label: _fileName!,
                                icon: Icons.description_outlined,
                                semanticLabel:
                                    'Selected file ${_fileName!}. Tap to clear.',
                                onTap: () => setState(() {
                                  _fileName = null;
                                  _sourceType = ContentType.text;
                                }),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _text,
                          minLines: 6,
                          maxLines: 16,
                          decoration: InputDecoration(
                            labelText: 'Extracted or pasted text',
                            alignLabelWithHint: true,
                            errorText: _sourceError,
                            hintText: 'Paste lecture notes here, or pick a '
                                'file above to extract the text.',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _Step(
                    number: 2,
                    title: 'Describe the quiz',
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final fields = [
                          TextField(
                            controller: _title,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Title',
                            ),
                          ),
                          TextField(
                            controller: _subject,
                            decoration: const InputDecoration(
                              labelText: 'Subject or class',
                            ),
                          ),
                        ];
                        if (constraints.maxWidth < 520) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              fields[0],
                              const SizedBox(height: 14),
                              fields[1],
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: fields[0]),
                            const SizedBox(width: 14),
                            Expanded(child: fields[1]),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  _Step(
                    number: 3,
                    title: 'Choose the questions',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const EyebrowLabel('How many'),
                        const SizedBox(height: 10),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SegmentedButton<int>(
                            segments: const [
                              ButtonSegment(value: 5, label: Text('5')),
                              ButtonSegment(value: 10, label: Text('10')),
                              ButtonSegment(value: 15, label: Text('15')),
                              ButtonSegment(value: 20, label: Text('20')),
                            ],
                            selected: {_count},
                            showSelectedIcon: false,
                            onSelectionChanged: (s) =>
                                setState(() => _count = s.first),
                          ),
                        ),
                        const SizedBox(height: 22),
                        const EyebrowLabel('Difficulty mix'),
                        const SizedBox(height: 6),
                        for (final d in Difficulty.values)
                          _MixSlider(
                            difficulty: d,
                            value: _mix[d]!,
                            onChanged: (v) => setState(() => _mix[d] = v),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  BauhausButton.primary(
                    label: generation.isLoading
                        ? 'Generating…'
                        : 'Generate quiz',
                    icon: Icons.auto_awesome,
                    expand: true,
                    busy: generation.isLoading,
                    onPressed: busy ? null : _generate,
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: t.plane(fill: t.surface),
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const EyebrowLabel('Generator'),
                        const SizedBox(height: 4),
                        Text(
                          '$generator · questions land as an editable draft, '
                          'nothing is published until you say so.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: t.inkSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A numbered step: a filled square carrying the numeral, a heading, a plane.
class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    required this.child,
  });

  final int number;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ExcludeSemantics(
              child: Container(
                decoration: t.plane(fill: t.inverseGround),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  '$number',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: t.inverseInk,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  'Step $number · $title',
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        BauhausCard(padding: const EdgeInsets.all(16), child: child),
      ],
    );
  }
}

class _MixSlider extends StatelessWidget {
  const _MixSlider({
    required this.difficulty,
    required this.value,
    required this.onChanged,
  });

  final Difficulty difficulty;
  final int value;
  final ValueChanged<int> onChanged;

  String get _label => switch (difficulty) {
    Difficulty.easy => 'Easy',
    Difficulty.medium => 'Medium',
    Difficulty.hard => 'Hard',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          SizedBox(
            width: 86,
            child: Text(_label, style: theme.textTheme.labelLarge),
          ),
          Expanded(
            child: Semantics(
              label: '$_label questions, weight $value out of 10',
              child: Slider(
                value: value.toDouble(),
                min: 0,
                max: 10,
                divisions: 10,
                label: '$value',
                semanticFormatterCallback: (v) =>
                    '${v.round()} $_label questions',
                onChanged: (v) => onChanged(v.round()),
              ),
            ),
          ),
          SizedBox(
            width: 28,
            child: Text(
              '$value',
              textAlign: TextAlign.end,
              style: theme.textTheme.titleSmall?.copyWith(color: t.ink),
            ),
          ),
        ],
      ),
    );
  }
}
