import 'enums.dart';

class ContentItem {
  const ContentItem({
    required this.id,
    required this.ownerId,
    required this.title,
    required this.fileType,
    required this.status,
    required this.createdAt,
    this.subject,
    this.fileUrl,
    this.extractedText = '',
    this.pageCount = 0,
    this.error,
  });

  final String id;
  final String ownerId;
  final String title;
  final String? subject;
  final ContentType fileType;
  final ContentStatus status;
  final String? fileUrl;

  /// Text pulled out of the source during the extraction step, fed to the LLM.
  final String extractedText;
  final int pageCount;
  final String? error;
  final DateTime createdAt;

  ContentItem copyWith({
    String? title,
    String? subject,
    ContentStatus? status,
    String? fileUrl,
    String? extractedText,
    int? pageCount,
    String? error,
  }) => ContentItem(
    id: id,
    ownerId: ownerId,
    title: title ?? this.title,
    subject: subject ?? this.subject,
    fileType: fileType,
    status: status ?? this.status,
    fileUrl: fileUrl ?? this.fileUrl,
    extractedText: extractedText ?? this.extractedText,
    pageCount: pageCount ?? this.pageCount,
    error: error,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'owner_id': ownerId,
    'title': title,
    'subject': subject,
    'file_type': fileType.name,
    'status': status.name,
    'file_url': fileUrl,
    'extracted_text': extractedText,
    'page_count': pageCount,
    'error': error,
    'created_at': createdAt.toIso8601String(),
  };

  factory ContentItem.fromJson(Map<String, dynamic> j) => ContentItem(
    id: j['id'] as String,
    ownerId: j['owner_id'] as String,
    title: (j['title'] ?? 'Untitled') as String,
    subject: j['subject'] as String?,
    fileType: enumFromName(
      ContentType.values,
      j['file_type'] as String?,
      ContentType.text,
    ),
    status: enumFromName(
      ContentStatus.values,
      j['status'] as String?,
      ContentStatus.ready,
    ),
    fileUrl: j['file_url'] as String?,
    extractedText: (j['extracted_text'] ?? '') as String,
    pageCount: (j['page_count'] ?? 0) as int,
    error: j['error'] as String?,
    createdAt:
        DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
  );
}
