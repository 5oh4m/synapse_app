import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'app/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Path URLs (`/join/ABC123`), not fragments (`/#/join/ABC123`), so a join
  // link reaches the server, can carry link-preview metadata and matches the
  // QR code in the lobby. A no-op off the web. The host must serve index.html
  // for unknown paths — see docs/DEPLOY.md.
  usePathUrlStrategy();
  runApp(const ProviderScope(child: QuizzleApp()));
}
