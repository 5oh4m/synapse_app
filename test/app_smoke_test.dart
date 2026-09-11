import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizzle/app/app.dart';
import 'package:quizzle/data/in_memory/in_memory_backend.dart';
import 'package:quizzle/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    // InMemoryBackend and ThemeModeController both read/write
    // shared_preferences; the mock store keeps that fast and offline in
    // tests instead of hitting a (nonexistent) platform channel.
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('app boots to the sign-in screen', (tester) async {
    final backend = InMemoryBackend();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [backendProvider.overrideWithValue(backend)],
        child: const QuizzleApp(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('quizzle'), findsOneWidget);
    expect(find.text('Sign in'), findsWidgets);
    expect(find.text('Educator'), findsWidgets);
  });

  testWidgets('demo educator login lands on the dashboard', (tester) async {
    final backend = InMemoryBackend();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [backendProvider.overrideWithValue(backend)],
        child: const QuizzleApp(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Educator'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.textContaining('Hi,'), findsOneWidget);
    expect(find.text('New quiz'), findsWidgets);
  });

  testWidgets('dark mode switch on the profile screen flips the theme',
      (tester) async {
    final backend = InMemoryBackend();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [backendProvider.overrideWithValue(backend)],
        child: const QuizzleApp(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Educator'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.account_circle_outlined));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('Dark mode'), findsOneWidget);
    final switchFinder = find.byType(Switch);
    expect(switchFinder, findsOneWidget);

    final before = Theme.of(tester.element(find.text('Dark mode'))).brightness;
    await tester.tap(switchFinder);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final after = Theme.of(tester.element(find.text('Dark mode'))).brightness;

    expect(after, isNot(before));
  });
}
