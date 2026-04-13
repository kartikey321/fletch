// route_entry.dart
part of 'list_route.dart';

class _RoutePattern {
  final RegExp regex;
  final List<String> paramNames;

  _RoutePattern(this.regex, this.paramNames);

  static _RoutePattern parse(String path) {
    final paramNames = <String>[];
    var pattern = path;

    pattern = pattern.replaceAllMapped(
        RegExp(r':([a-zA-Z][a-zA-Z0-9_]*)\(([^)]+)\)'), (match) {
      paramNames.add(match.group(1)!);
      return '(${match.group(2)})';
    });

    pattern =
        pattern.replaceAllMapped(RegExp(r':([a-zA-Z][a-zA-Z0-9_]*)'), (match) {
      paramNames.add(match.group(1)!);
      return '([^/]+)';
    });

    pattern = pattern.replaceAll('/', '\\/');
    final regex = RegExp('^$pattern/?\$');
    return _RoutePattern(regex, paramNames);
  }

}

class _RouteEntry {
  final String method;
  final _RoutePattern pattern;
  final RequestHandler handler;
  final RouterInterface? isolatedRouter;
  final String? prefix;

  _RouteEntry.route(this.method, String path, this.handler)
      : pattern = _RoutePattern.parse(path),
        isolatedRouter = null,
        prefix = null;

  _RouteEntry.isolated(this.prefix, this.isolatedRouter)
      : method = '',
        pattern = _RoutePattern.parse(prefix!),
        handler = ((req, res) => Future.value());

  /// Matches method+path in a single regex pass and returns a [RouteMatch]
  /// directly, avoiding the redundant second [extractParams] call.
  RouteMatch? tryMatch(String method, String path) {
    if (this.method != method) return null;
    final regexMatch = pattern.regex.firstMatch(path);
    if (regexMatch == null) return null;
    // No params on this route — reuse the shared empty map, zero allocation.
    if (pattern.paramNames.isEmpty) {
      return RouteMatch(handler);
    }
    final params = <String, String>{};
    for (var i = 0; i < pattern.paramNames.length; i++) {
      params[pattern.paramNames[i]] = regexMatch.group(i + 1)!;
    }
    return RouteMatch(handler, pathParams: params);
  }
}
