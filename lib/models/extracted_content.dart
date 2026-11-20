import 'enums.dart';

/// Outcome of a text-extraction attempt.
///
/// Mirrors the backend's `status` vocabulary (docs/API.md): `ready`,
/// `needs_text`, `failed`. There is no "pretend it worked" state — an image
/// with no OCR available comes back [needsText], and the UI says so.
enum ExtractionStatus { ready, needsText, failed }

class ExtractedContent {
  const ExtractedContent({
    required this.text,
    required this.pageCount,
    required this.sourceType,
    this.status = ExtractionStatus.ready,
    this.message,
    this.fileName,
  });

  /// Nothing was read, and we say which file and why.
  factory ExtractedContent.needsText({
    required ContentType sourceType,
    required String message,
    String? fileName,
    int pageCount = 0,
  }) => ExtractedContent(
    text: '',
    pageCount: pageCount,
    sourceType: sourceType,
    status: ExtractionStatus.needsText,
    message: message,
    fileName: fileName,
  );

  factory ExtractedContent.failed({
    required ContentType sourceType,
    required String message,
    String? fileName,
  }) => ExtractedContent(
    text: '',
    pageCount: 0,
    sourceType: sourceType,
    status: ExtractionStatus.failed,
    message: message,
    fileName: fileName,
  );

  final String text;

  /// Real page/slide count from the server's parser, or 0 when unknown. Never
  /// guessed from byte patterns.
  final int pageCount;
  final ContentType sourceType;
  final ExtractionStatus status;

  /// Honest, user-facing note: "no OCR is bundled, paste the text", etc.
  final String? message;
  final String? fileName;

  bool get isReady => status == ExtractionStatus.ready && text.trim().isNotEmpty;
  bool get needsText => status == ExtractionStatus.needsText;
  bool get failed => status == ExtractionStatus.failed;

  static ExtractionStatus statusFromWire(String? raw) => switch (raw) {
    'ready' => ExtractionStatus.ready,
    'needs_text' => ExtractionStatus.needsText,
    'failed' => ExtractionStatus.failed,
    // `processing` never reaches the client synchronously; treat anything else
    // as "we do not have text yet".
    _ => ExtractionStatus.needsText,
  };

  factory ExtractedContent.fromJson(Map<String, dynamic> j) => ExtractedContent(
    text: (j['extracted_text'] ?? '') as String,
    pageCount: ((j['page_count'] ?? 0) as num).toInt(),
    sourceType: enumFromName(
      ContentType.values,
      (j['source_type'] ?? j['file_type']) as String?,
      ContentType.text,
    ),
    status: statusFromWire(j['status'] as String?),
    message: (j['message'] ?? j['error']) as String?,
    fileName: j['file_name'] as String?,
  );
}
