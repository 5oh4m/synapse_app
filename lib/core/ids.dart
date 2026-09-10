import 'dart:math';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

String newId() => _uuid.v4();

/// Ambiguous characters (0/O, 1/I) removed so codes are easy to read aloud
/// and type on a projector.
const _joinAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

String newJoinCode([int length = 6]) {
  final r = Random.secure();
  return String.fromCharCodes(
    Iterable.generate(
      length,
      (_) => _joinAlphabet.codeUnitAt(r.nextInt(_joinAlphabet.length)),
    ),
  );
}

String normalizeJoinCode(String raw) =>
    raw.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
