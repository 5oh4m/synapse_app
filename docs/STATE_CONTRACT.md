# Riverpod contract — frozen for the v2 rewrite

Two agents work in parallel: one rewrites the data layer, one rewrites the screens.
They cannot talk to each other, so this file is the interface between them.

**The data-layer agent owns the implementations. The screens agent owns the consumers.**
Neither may change a name or type below. Additions are fine; the data-layer agent must
append new providers rather than repurpose these.

## Providers the screens may read (name -> exact value type)

```dart
// wiring
backendProvider              Provider<Backend>
backendReadyProvider         FutureProvider<Backend>          // app gates on this
quizGeneratorProvider        Provider<QuizGenerator>
generatorLabelProvider       Provider<String>                 // human label for the banner

// repositories
authRepositoryProvider       Provider<AuthRepository>
contentRepositoryProvider    Provider<ContentRepository>
quizRepositoryProvider       Provider<QuizRepository>
sessionRepositoryProvider    Provider<SessionRepository>
leaderboardRepositoryProvider Provider<LeaderboardRepository>
analyticsRepositoryProvider  Provider<AnalyticsRepository>

// auth
authStateProvider            StreamProvider<AppUser?>
currentUserProvider          Provider<AppUser?>

// content + quizzes
libraryProvider              StreamProvider.family<List<ContentItem>, String /*ownerId*/>
quizzesProvider              StreamProvider.family<List<Quiz>, String /*ownerId*/>
quizProvider                 StreamProvider.family<Quiz?, String /*quizId*/>
questionsProvider            StreamProvider.family<List<Question>, String /*quizId*/>
publishedQuizzesProvider     FutureProvider<List<Quiz>>

// live session
sessionProvider              StreamProvider.family<QuizSession?, String /*sessionId*/>
participantsProvider         StreamProvider.family<List<SessionParticipant>, String>
sessionResponsesProvider     StreamProvider.family<List<QuizResponse>, String>
sessionQuestionsProvider     FutureProvider.family<List<Question>, String>   // HOST ONLY
publicQuestionProvider       FutureProvider.family<Question?, PublicQuestionArg>
                             // PublicQuestionArg = ({String sessionId, int index})
                             // redacted (correct_index == -1) until revealed

// leaderboard + analytics
globalLeaderboardProvider    StreamProvider.family<List<LeaderboardEntry>, LeaderboardQuery>
                             // LeaderboardQuery({String period, String? subject})
                             // period is 'week' | 'all-time' — BOTH must now really filter
quizAnalyticsProvider        FutureProvider.family<QuizAnalytics, String /*quizId*/>
studentHistoryProvider       FutureProvider.family<List<StudentQuizResult>, String /*studentId*/>
```

## Controllers the screens may call (lib/state/controllers.dart)

```dart
authControllerProvider          NotifierProvider<AuthController, bool>  // bool = busy
  .signIn(email, password) / .register(...) / .signOut() / .demoAs(UserRole)
quizCreationControllerProvider  NotifierProvider<..., AsyncValue<void>>
  .generate(GenerateParams) -> Future<String /*quizId*/>
sessionHostControllerProvider   Provider.family<SessionHostController, String>
  .start() / .reveal() / .next() / .end()
goLiveProvider                  Provider<Future<String> Function(Quiz)>
contentExtractorProvider        Provider<ContentExtractor>
themeModeControllerProvider     NotifierProvider<ThemeModeController, ThemeMode>
  .setDark(bool)
```

## Realtime providers (landed after the second audit)

These were specified here from the start but never added; the screens carried stand-ins that
could not work (a banner that never saw a dropped socket, a counter stuck at 0).

```dart
// Connection state for the reconnect banner, straight from the realtime client.
connectionStateProvider      StreamProvider<ConnectionState>
  // enum ConnectionState { connected, reconnecting, offline }

// Live answered-count during 'asking', pushed as a coalesced delta by the server
// (docs/API.md `answer.count`). Host screen shows "n / m answered".
answerCountProvider          StreamProvider.family<({int answered, int total}), String /*sessionId*/>

// The current question's key + distribution once revealed, null while asking
// (`question.revealed`). The only source of the key on a student device.
revealProvider               StreamProvider.family<RevealInfo?, String /*sessionId*/>

// This player's own results by question index, revealed questions only
// (`answer.result`). The answer response carries no correctness before reveal.
myResultsProvider            StreamProvider.family<Map<int, AnswerResult>, String /*sessionId*/>

// Server time estimated on this device. Every countdown passes `clock.now`.
serverClockProvider          Provider<ServerClock>
```

Repository additions behind them: `SessionRepository.watchReveal` / `watchMyResults`,
`QuizRepository.gradePractice`, `Backend.clock` / `Backend.resumeRealtime()`.

## Rules

- `publicQuestionProvider` must keep returning a **redacted** question until reveal.
  Screens must never receive `correct_index` early. Do not "optimise" this away. A screen
  shows the key by applying `revealProvider`'s value for the *same* question index — never by
  refetching and never by indexing options with a `correct_index` of `-1`.
- `questionsProvider` carries the key for the quiz's owner only; practice asks
  `gradePractice` for each answer.
- Countdowns read `serverClockProvider`, never `DateTime.now()` directly. With the networked
  backend a host screen must not reveal on its own countdown; the server does.
- Screens must not call `sessionQuestionsProvider` on a student route — it is host-only
  and the server will 403/404.
- No polling from the client. Realtime comes from the WebSocket deltas.
- Screens must not read tokens, call Dio, or touch `http` directly. Everything goes
  through a repository.
