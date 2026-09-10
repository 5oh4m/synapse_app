import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/failure.dart';
import '../../core/responsive.dart';
import '../../models/enums.dart';
import '../../state/controllers.dart';
import '../../state/providers.dart';
import '../../shared_widgets/async_view.dart';

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
  final Map<Difficulty, int> _mix = {
    Difficulty.easy: 3,
    Difficulty.medium: 5,
    Difficulty.hard: 2,
  };
  bool _loadingExisting = false;

  @override
  void initState() {
    super.initState();
    if (widget.contentItemId != null) _loadExisting(widget.contentItemId!);
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
    });
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      if (mounted) {
        showSnack(
          context,
          'Could not read the file on this platform. Paste the text instead.',
          error: true,
        );
      }
      return;
    }
    final extracted = extractor.fromBytes(bytes: bytes, fileName: file.name);
    setState(() {
      _pageCount = extracted.pageCount;
      if (extracted.text.isNotEmpty) {
        _text.text = extracted.text;
      }
    });
    if (extracted.text.trim().length < 40 && mounted) {
      showSnack(
        context,
        _sourceType == ContentType.image
            ? 'On-device OCR is not bundled. Paste the text from the image below.'
            : 'Only partial text could be extracted here. Review / paste below. '
                  'The Node backend does full extraction.',
      );
    }
  }

  Future<void> _generate() async {
    final text = _text.text.trim();
    if (text.length < 40) {
      showSnack(
        context,
        'Add at least a paragraph of source text.',
        error: true,
      );
      return;
    }
    final total = _mix.values.fold<int>(0, (a, b) => a + b);
    if (total == 0) {
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
    final gen = ref.watch(quizCreationControllerProvider);
    final busy = gen.isLoading || _loadingExisting;
    final label = ref.watch(generatorLabelProvider);
    final t = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('New quiz'),
        leading: BackButton(onPressed: () => context.go('/')),
      ),
      body: AbsorbPointer(
        absorbing: busy,
        child: ContentContainer(
          maxWidth: 760,
          child: ListView(
            children: [
              _stepHeader(context, 1, 'Add lecture material'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy ? null : _pickFile,
                    icon: const Icon(Icons.attach_file),
                    label: const Text('Choose PDF / PPTX / image'),
                  ),
                  if (_fileName != null)
                    Chip(
                      avatar: const Icon(Icons.description_outlined, size: 18),
                      label: Text(_fileName!),
                      onDeleted: () => setState(() {
                        _fileName = null;
                        _sourceType = ContentType.text;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                minLines: 5,
                maxLines: 14,
                decoration: const InputDecoration(
                  labelText: 'Extracted / pasted text',
                  alignLabelWithHint: true,
                  hintText:
                      'Paste lecture notes here, or pick a file above to extract text.',
                ),
              ),
              const SizedBox(height: 20),
              _stepHeader(context, 2, 'Describe the quiz'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _title,
                      decoration: const InputDecoration(labelText: 'Title'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _subject,
                      decoration: const InputDecoration(
                        labelText: 'Subject / class',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _stepHeader(context, 3, 'Choose questions'),
              const SizedBox(height: 8),
              Text('How many questions', style: t.textTheme.labelLarge),
              Wrap(
                spacing: 8,
                children: [
                  for (final n in const [5, 10, 15, 20])
                    ChoiceChip(
                      label: Text('$n'),
                      selected: _count == n,
                      onSelected: (_) => setState(() => _count = n),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text('Difficulty mix', style: t.textTheme.labelLarge),
              const SizedBox(height: 4),
              for (final d in Difficulty.values)
                Row(
                  children: [
                    SizedBox(
                      width: 84,
                      child: Text(switch (d) {
                        Difficulty.easy => 'Easy',
                        Difficulty.medium => 'Medium',
                        Difficulty.hard => 'Hard',
                      }),
                    ),
                    Expanded(
                      child: Slider(
                        value: _mix[d]!.toDouble(),
                        min: 0,
                        max: 10,
                        divisions: 10,
                        label: '${_mix[d]}',
                        onChanged: (v) => setState(() => _mix[d] = v.round()),
                      ),
                    ),
                    SizedBox(width: 24, child: Text('${_mix[d]}')),
                  ],
                ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: busy ? null : _generate,
                icon: gen.isLoading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(gen.isLoading ? 'Generating…' : 'Generate quiz'),
              ),
              const SizedBox(height: 8),
              Text(
                'Generator: $label · questions land as an editable draft.',
                style: t.textTheme.bodySmall?.copyWith(
                  color: t.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepHeader(BuildContext context, int n, String label) {
    return Row(
      children: [
        CircleAvatar(
          radius: 13,
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: Text(
            '$n',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(label, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}
