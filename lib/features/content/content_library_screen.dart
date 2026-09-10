import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/content_item.dart';
import '../../models/enums.dart';
import '../../state/providers.dart';
import '../../shared_widgets/app_scaffold.dart';
import '../../shared_widgets/async_view.dart';

class ContentLibraryScreen extends ConsumerWidget {
  const ContentLibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final lib = user == null
        ? const AsyncValue<List<ContentItem>>.loading()
        : ref.watch(libraryProvider(user.id));

    return AppScaffold(
      title: 'Content library',
      currentRoute: '/library',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/create'),
        icon: const Icon(Icons.upload_file),
        label: const Text('Upload'),
      ),
      body: lib.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: '$e'),
        data: (items) {
          if (items.isEmpty) {
            return EmptyView(
              icon: Icons.folder_open_outlined,
              title: 'Library is empty',
              subtitle: 'Upload a PDF, PPTX or image, or paste lecture text.',
              action: FilledButton(
                onPressed: () => context.go('/create'),
                child: const Text('Upload material'),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) => _ContentCard(item: items[i]),
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
    final t = Theme.of(context);
    final (statusColor, statusLabel) = switch (item.status) {
      ContentStatus.ready => (const Color(0xFF1F9E5B), 'Ready for review'),
      ContentStatus.failed => (t.colorScheme.error, 'Extraction failed'),
      ContentStatus.uploading => (t.colorScheme.outline, 'Uploading'),
      ContentStatus.extracting => (t.colorScheme.outline, 'Extracting text'),
      ContentStatus.generating => (t.colorScheme.primary, 'Generating'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(_icon, size: 30, color: t.colorScheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (item.subject?.isNotEmpty ?? false) item.subject!,
                      '${item.pageCount} pages',
                      DateFormat.yMMMd().format(item.createdAt),
                    ].join(' · '),
                    style: t.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        statusLabel,
                        style: t.textTheme.bodySmall?.copyWith(
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                  if (item.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        item.error!,
                        style: t.textTheme.bodySmall?.copyWith(
                          color: t.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (item.status == ContentStatus.ready)
              FilledButton.tonal(
                onPressed: () => context.go('/create?content=${item.id}'),
                child: const Text('Generate'),
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () =>
                  ref.read(contentRepositoryProvider).delete(item.id),
            ),
          ],
        ),
      ),
    );
  }
}
