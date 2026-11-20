import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../models/content_item.dart';
import '../../models/enums.dart';
import '../../shared_widgets/app_scaffold.dart';
import '../../shared_widgets/async_view.dart';
import '../../shared_widgets/bauhaus_button.dart';
import '../../shared_widgets/bauhaus_card.dart';
import '../../shared_widgets/labels.dart';
import '../../state/providers.dart';

/// Source material. The calm register: a structured stack of flat planes, one
/// square status block per row, no colour doing work that text is not.
class ContentLibraryScreen extends ConsumerWidget {
  const ContentLibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final library = user == null
        ? const AsyncValue<List<ContentItem>>.loading()
        : ref.watch(libraryProvider(user.id));

    return AppScaffold(
      title: 'Content library',
      eyebrow: 'Source material',
      currentRoute: '/library',
      padBody: true,
      maxContentWidth: 900,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/create'),
        icon: const Icon(Icons.upload_file),
        label: const Text('Upload'),
        tooltip: 'Upload new lecture material',
      ),
      body: library.when(
        loading: () => const LoadingView(label: 'Loading your library'),
        error: (e, _) => ErrorView(
          message: '$e',
          onRetry: user == null
              ? null
              : () => ref.invalidate(libraryProvider(user.id)),
        ),
        data: (items) {
          if (items.isEmpty) {
            return EmptyView(
              icon: Icons.folder_open_outlined,
              title: 'Library is empty',
              subtitle: 'Upload a PDF, a slide deck or an image — or paste '
                  'lecture text — and quizzle drafts the questions.',
              action: BauhausButton.primary(
                label: 'Upload material',
                icon: Icons.upload_file,
                onPressed: () => context.go('/create'),
              ),
            );
          }
          return ListView.separated(
            padding: EdgeInsets.zero,
            itemCount: items.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              if (i == 0) {
                return SectionHeader(
                  eyebrow: 'Uploads',
                  title: '${items.length} '
                      '${items.length == 1 ? "item" : "items"}',
                );
              }
              return StaggeredEntry(
                index: i - 1,
                child: _ContentCard(item: items[i - 1]),
              );
            },
          );
        },
      ),
    );
  }
}

class _ContentCard extends ConsumerWidget {
  const _ContentCard({required this.item});

  final ContentItem item;

  IconData get _icon => switch (item.fileType) {
    ContentType.pdf => Icons.picture_as_pdf_outlined,
    ContentType.pptx => Icons.slideshow_outlined,
    ContentType.image => Icons.image_outlined,
    ContentType.text => Icons.notes_outlined,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);

    final (Color statusColor, String statusLabel) = switch (item.status) {
      ContentStatus.ready => (t.correct, 'Ready for review'),
      ContentStatus.failed => (t.wrong, 'Extraction failed'),
      ContentStatus.uploading => (t.inkMuted, 'Uploading'),
      ContentStatus.extracting => (t.warn, 'Extracting text'),
      ContentStatus.generating => (t.warn, 'Generating questions'),
    };
    final meta = [
      if (item.subject?.isNotEmpty ?? false) item.subject!,
      '${item.pageCount} ${item.pageCount == 1 ? "page" : "pages"}',
      DateFormat.yMMMd().format(item.createdAt),
    ].join(' · ');

    return BauhausCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The file type as a bordered square plane, not a coloured glyph.
              ExcludeSemantics(
                child: Container(
                  decoration: t.plane(fill: t.surfaceMuted),
                  padding: const EdgeInsets.all(10),
                  child: Icon(_icon, size: 24, color: t.ink),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(item.title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: t.inkSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Semantics(
                      label: 'Status: $statusLabel',
                      excludeSemantics: true,
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            color: statusColor,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            statusLabel,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: t.ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (item.error != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        item.error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: t.wrongInk,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              BauhausIconButton(
                icon: Icons.delete_outline,
                tooltip: 'Delete',
                semanticLabel: 'Delete ${item.title} from the library',
                onPressed: () => _confirmDelete(context, ref),
              ),
            ],
          ),
          if (item.status == ContentStatus.ready) ...[
            const SizedBox(height: 14),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: BauhausButton.primary(
                label: 'Generate quiz',
                icon: Icons.auto_awesome,
                semanticLabel: 'Generate a quiz from ${item.title}',
                onPressed: () => context.go('/create?content=${item.id}'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this item?'),
        content: Text(
          '“${item.title}” goes from your library. Quizzes already generated '
          'from it stay where they are.',
        ),
        actions: [
          BauhausButton.ghost(
            label: 'Keep it',
            onPressed: () => Navigator.of(context).pop(false),
          ),
          BauhausButton.danger(
            label: 'Delete',
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(contentRepositoryProvider).delete(item.id);
    if (context.mounted) showSnack(context, 'Deleted “${item.title}”');
  }
}
