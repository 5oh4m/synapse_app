import 'dart:convert';
import 'dart:typed_data';

import '../models/enums.dart';

class ExtractedContent {
  const ExtractedContent({
    required this.text,
    required this.pageCount,
    required this.sourceType,
  });
  final String text;
  final int pageCount;
  final ContentType sourceType;
}

/// Pulls text out of an uploaded file before it goes to the LLM. This keeps
/// token cost down and accuracy up (spec section 6 / 7).
///
/// The spec's full pipeline runs server-side (PyMuPDF / python-pptx / OCR).
/// This client-side extractor covers the cases that work without native libs:
///  - plain text / markdown files and pasted text
///  - PDFs: best-effort extraction of parenthesised text tokens from the
///    uncompressed portions of the byte stream
///  - PPTX: unzip not available here, so we fall back to any embedded XML text
///  - images: no on-device OCR; the educator is asked to paste a caption
///
/// When the Node backend is enabled it exposes POST /extract which does the
/// real thing; [ContentExtractor.viaBackend] is used then.
class ContentExtractor {
  const ContentExtractor();

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
        return ContentType.image;
      default:
        return ContentType.text;
    }
  }

  ExtractedContent fromText(String text) => ExtractedContent(
    text: text.trim(),
    pageCount: 1,
    sourceType: ContentType.text,
  );

  ExtractedContent fromBytes({
    required Uint8List bytes,
    required String fileName,
  }) {
    final type = typeForExtension(fileName);
    switch (type) {
      case ContentType.text:
        return ExtractedContent(
          text: _safeUtf8(bytes),
          pageCount: 1,
          sourceType: type,
        );
      case ContentType.pdf:
        final text = _naivePdfText(bytes);
        final pages = '\nendobj'.allMatches(_safeLatin1(bytes)).length;
        return ExtractedContent(
          text: text,
          pageCount: pages > 0 ? pages : 1,
          sourceType: type,
        );
      case ContentType.pptx:
        return ExtractedContent(
          text: _xmlishText(_safeLatin1(bytes)),
          pageCount: 1,
          sourceType: type,
        );
      case ContentType.image:
        return const ExtractedContent(
          text: '',
          pageCount: 1,
          sourceType: ContentType.image,
        );
    }
  }

  String _safeUtf8(Uint8List b) {
    try {
      return utf8.decode(b, allowMalformed: true).trim();
    } catch (_) {
      return '';
    }
  }

  String _safeLatin1(Uint8List b) => latin1.decode(b, allowInvalid: true);

  /// Extracts text drawn with Tj / TJ operators from the uncompressed parts of
  /// a PDF. Misses content in compressed (FlateDecode) streams; good enough for
  /// simple exported slide decks and text PDFs. Real extraction is server-side.
  String _naivePdfText(Uint8List bytes) {
    final raw = _safeLatin1(bytes);
    final buf = StringBuffer();
    final re = RegExp(r'\(((?:[^()\\]|\\.)*)\)\s*T[jJ]');
    for (final m in re.allMatches(raw)) {
      final s = m
          .group(1)!
          .replaceAll(r'\(', '(')
          .replaceAll(r'\)', ')')
          .replaceAll(r'\\', r'\');
      if (s.trim().isNotEmpty) buf.write('$s ');
    }
    final arrRe = RegExp(r'\[((?:[^\]])*)\]\s*TJ');
    for (final m in arrRe.allMatches(raw)) {
      final inner = m.group(1)!;
      for (final sm in RegExp(r'\(((?:[^()\\]|\\.)*)\)').allMatches(inner)) {
        buf.write(sm.group(1));
      }
      buf.write(' ');
    }
    return _collapse(buf.toString());
  }

  String _xmlishText(String raw) {
    final buf = StringBuffer();
    for (final m in RegExp(r'<a:t>([^<]*)</a:t>').allMatches(raw)) {
      buf.write('${m.group(1)} ');
    }
    if (buf.isEmpty) {
      for (final m in RegExp(r'>([A-Za-z0-9 ,.\-]{4,})<').allMatches(raw)) {
        buf.write('${m.group(1)} ');
      }
    }
    return _collapse(buf.toString());
  }

  String _collapse(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
}
