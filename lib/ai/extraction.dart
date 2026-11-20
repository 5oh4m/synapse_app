import 'dart:convert';
import 'dart:typed_data';

import '../data/repositories.dart';
import '../models/enums.dart';
import '../models/extracted_content.dart';

export '../models/extracted_content.dart';

/// Gets text out of a source file so the generator has something to work from.
///
/// **What this class used to do, and no longer does.** It claimed a `POST
/// /extract` endpoint and a `ContentExtractor.viaBackend` method that never
/// existed; it counted PDF pages by counting `endobj` markers (a one-page file
/// reported 40+ pages, because `endobj` marks every object, not every page);
/// and it ran a `<a:t>` regex over the raw bytes of a `.pptx`, which is a ZIP
/// archive — the tags it was looking for are deflate-compressed and can never
/// match. All of that is deleted.
///
/// Real parsing happens on the server (`POST /content/extract` and `POST
/// /content/upload`), which has `pdf-parse` for PDF text plus a true page count
/// from the page tree, and unzip + XML parsing for PPTX slides and notes.
/// No OCR is bundled anywhere, so an image comes back `needs_text` and the UI
/// asks the educator to paste the text. See docs/API.md.
class ContentExtractor {
  const ContentExtractor([this._content]);

  final ContentRepository? _content;

  /// Whether a server-side extractor is wired up. `false` for the offline
  /// backend, which can only read plain text.
  bool get hasServerExtraction => _content != null;

  ContentType typeForExtension(String? name) {
    final ext = (name ?? '').toLowerCase().split('.').last;
    switch (ext) {
      case 'pdf':
        return ContentType.pdf;
      case 'ppt':
      case 'pptx':
        return ContentType.pptx;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
      case 'bmp':
      case 'heic':
        return ContentType.image;
      default:
        return ContentType.text;
    }
  }

  ExtractedContent fromText(String text) => ExtractedContent(
    text: text.trim(),
    pageCount: text.trim().isEmpty ? 0 : 1,
    sourceType: ContentType.text,
    status: text.trim().isEmpty
        ? ExtractionStatus.needsText
        : ExtractionStatus.ready,
  );

  /// Sends the file to the backend and returns what the server actually read.
  ///
  /// Plain text and Markdown are decoded locally because that is a decode, not
  /// a parse — there is nothing to get wrong and no reason for a round trip.
  /// Everything else goes to the server; with no server available it reports
  /// [ExtractionStatus.needsText] instead of guessing.
  Future<ExtractedContent> extract({
    required Uint8List bytes,
    required String fileName,
  }) async {
    final type = typeForExtension(fileName);
    if (type == ContentType.text) {
      final decoded = _decodeText(bytes);
      return ExtractedContent(
        text: decoded,
        pageCount: decoded.isEmpty ? 0 : 1,
        sourceType: ContentType.text,
        status: decoded.isEmpty
            ? ExtractionStatus.needsText
            : ExtractionStatus.ready,
        message: decoded.isEmpty ? 'That file had no readable text.' : null,
        fileName: fileName,
      );
    }

    final repo = _content;
    if (repo == null) {
      return ExtractedContent.needsText(
        sourceType: type,
        fileName: fileName,
        message: _offlineMessage(type),
      );
    }
    return repo.extractFile(fileName: fileName, bytes: bytes);
  }

  /// Synchronous, local-only inspection of a picked file.
  ///
  /// It decodes plain text and otherwise tells the truth: no page count is
  /// invented and no content is parsed on device. Use [extract] to get the real
  /// text for PDF/PPTX.
  ExtractedContent fromBytes({
    required Uint8List bytes,
    required String fileName,
  }) {
    final type = typeForExtension(fileName);
    if (type == ContentType.text) {
      final decoded = _decodeText(bytes);
      return ExtractedContent(
        text: decoded,
        pageCount: decoded.isEmpty ? 0 : 1,
        sourceType: type,
        status: decoded.isEmpty
            ? ExtractionStatus.needsText
            : ExtractionStatus.ready,
        fileName: fileName,
      );
    }
    return ExtractedContent.needsText(
      sourceType: type,
      fileName: fileName,
      message: hasServerExtraction
          ? '${_label(type)} files are extracted on the server. Upload it to read the text.'
          : _offlineMessage(type),
    );
  }

  String _offlineMessage(ContentType type) => switch (type) {
    ContentType.image =>
      'No OCR is bundled, on device or on the server. Paste the text from the '
          'image below.',
    _ =>
      '${_label(type)} extraction runs on the backend. Start it with '
          '`cd backend && npm start` and run the app with '
          '--dart-define=BACKEND=remote, or paste the text below.',
  };

  String _label(ContentType type) => switch (type) {
    ContentType.pdf => 'PDF',
    ContentType.pptx => 'PowerPoint',
    ContentType.image => 'Image',
    ContentType.text => 'Text',
  };

  String _decodeText(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true).trim();
    } catch (_) {
      return '';
    }
  }
}
