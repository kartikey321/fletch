/// Roux-backed router for Fletch.
///
/// Drop-in replacement for the default [RadixRouter] that adds support for
/// optional params, repeated params, and grouped optional segments:
///
/// ```dart
/// import 'package:fletch/fletch.dart';
/// import 'package:fletch_roux_router/fletch_roux_router.dart';
///
/// final app = Fletch(router: RouxRouter());
///
/// app.get('/users/:id?',     handler);  // optional param
/// app.get('/files/:path+',   handler);  // one-or-more segments
/// app.get('/book{s}?',       handler);  // optional suffix
/// app.get('/docs{/:v}?/api', handler);  // optional segment group
/// ```
library fletch_roux_router;

export 'src/roux_router.dart';
