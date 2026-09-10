import 'enums.dart';
import 'scoring.dart';

class Quiz {
  const Quiz({
    required this.id,
    required this.ownerId,
    required this.title,
    required this.status,
    required this.createdAt,
    this.subject = '',
    this.description = '',
    this.tags = const [],
    this.contentItemId,
    this.questionCount = 0,
    this.scoring = const ScoringConfig(),
  });

  final String id;
  final String ownerId;
  final String title;
  final String subject;
  final String description;
  final List<String> tags;
  final String? contentItemId;
  final QuizStatus status;
  final int questionCount;
  final ScoringConfig scoring;
  final DateTime createdAt;

  bool get isPublished => status == QuizStatus.published;

  Quiz copyWith({
    String? title,
    String? subject,
    String? description,
    List<String>? tags,
    QuizStatus? status,
    int? questionCount,
    ScoringConfig? scoring,
  }) => Quiz(
    id: id,
    ownerId: ownerId,
    title: title ?? this.title,
    subject: subject ?? this.subject,
    description: description ?? this.description,
    tags: tags ?? this.tags,
    contentItemId: contentItemId,
    status: status ?? this.status,
    questionCount: questionCount ?? this.questionCount,
    scoring: scoring ?? this.scoring,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'owner_id': ownerId,
    'title': title,
    'subject': subject,
    'description': description,
    'tags': tags,
    'content_item_id': contentItemId,
    'status': status.name,
    'question_count': questionCount,
    'scoring': scoring.toJson(),
    'created_at': createdAt.toIso8601String(),
  };

  factory Quiz.fromJson(Map<String, dynamic> j) => Quiz(
    id: j['id'] as String,
    ownerId: j['owner_id'] as String,
    title: (j['title'] ?? 'Untitled quiz') as String,
    subject: (j['subject'] ?? '') as String,
    description: (j['description'] ?? '') as String,
    tags: (j['tags'] as List? ?? const [])
        .map((e) => e.toString())
        .toList(growable: false),
    contentItemId: j['content_item_id'] as String?,
    status: enumFromName(
      QuizStatus.values,
      j['status'] as String?,
      QuizStatus.draft,
    ),
    questionCount: (j['question_count'] ?? 0) as int,
    scoring: ScoringConfig.fromJson(j['scoring'] as Map<String, dynamic>?),
    createdAt:
        DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
  );
}
