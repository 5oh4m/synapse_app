enum UserRole { educator, student }

enum ContentType { pdf, pptx, image, text }

enum ContentStatus { uploading, extracting, generating, ready, failed }

enum QuizStatus { draft, published }

/// Coarse session lifecycle (matches the spec's lobby/active/ended) plus the
/// fine-grained [SessionPhase] the host drives during `active`.
enum SessionStatus { lobby, active, ended }

enum SessionPhase { asking, revealing }

enum Difficulty { easy, medium, hard }

T enumFromName<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}
