# Firebase backend (production path)

The spec's primary recommendation is Firebase (Auth, Firestore, Storage, Cloud
Functions). It is **not** wired into this build so the app runs with zero setup
and so review does not require a Firebase project. This document is the
drop-in plan.

## 1. Add packages

```yaml
# pubspec.yaml
dependencies:
  firebase_core: ^3.6.0
  firebase_auth: ^5.3.1
  cloud_firestore: ^5.4.4
  firebase_storage: ^12.3.4
```

```bash
dart pub global activate flutterfire_cli
flutterfire configure          # writes lib/firebase_options.dart
```

## 2. Implement `FirebaseBackend implements Backend`

Create `lib/data/firebase/firebase_backend.dart`. The `Backend` contract in
`lib/data/repositories.dart` is already the exact surface Firestore needs:

| Contract method | Firestore |
|---|---|
| `authState()` | `FirebaseAuth.instance.authStateChanges()` mapped to `users/{uid}` |
| `watchLibrary(ownerId)` | `content_items` where `owner_id == ownerId` `.snapshots()` |
| `watchQuizzes` / `watchQuiz` / `watchQuestions` | `quizzes`, `quizzes/{id}`, `questions` where `quiz_id == id` `.snapshots()` |
| `createSession` | `quiz_sessions.add(...)`, copy questions into `quiz_sessions/{id}/questions` |
| `watchSession` / `watchParticipants` / `watchResponses` | `.snapshots()` on the doc + subcollections |
| `startSession` / `revealAnswer` / `nextQuestion` / `endSession` | `quiz_sessions/{id}.update(...)` (or a callable Function for authority) |
| `submitAnswer` | a **Cloud Function** (see below) |
| `publicQuestionAt` | read `quiz_sessions/{id}/public_questions/{index}` that a Function keeps answer-key-free |

The collection names and field names already match the JSON in the models
(`toJson()` uses snake_case), so serialization is a straight
`doc.data()` → `Model.fromJson`.

## 3. Cloud Functions (authority + secrets)

- **`onContentUploaded`** (Storage trigger): PyMuPDF / python-pptx / Vision OCR →
  write `extracted_text` back to `content_items/{id}`, set `status`.
- **`generateQuiz`** (callable): holds `ANTHROPIC_API_KEY`, runs the same prompt
  + schema validation as `backend/src/server.mjs`, writes draft `questions`.
- **`submitAnswer`** (callable): server computes correctness + points (clients
  never receive the key mid-question), updates `session_participants` and
  `responses` in a transaction; enforces one scored answer per question.
- **`advanceQuestion` / `revealAnswer` / `endSession`** (callable, host-only):
  update the session doc; `endSession` folds scores into `leaderboard_entries`.

## 4. Firestore security rules (spec Section 13)

- `questions`: readable by the owner always; by a participant only for
  `quiz_sessions/{sid}/public_questions` (no `correct_index`).
- draft `quizzes`/`questions`: owner-only.
- `session_participants` / `responses`: create via Function only; a student may
  read their own; the host may read all for their session.
- `leaderboard_entries`: read-all, write via Function only.

## 5. Switch the app

```dart
// lib/state/providers.dart
final backendProvider = Provider<Backend>((ref) {
  return switch (Env.backend) {
    'firebase' => FirebaseBackend(),
    'remote' => RemoteBackend(),
    _ => InMemoryBackend(),
  };
});
```

Everything above the `Backend` interface (all of `lib/features`, `lib/state`)
stays unchanged.
