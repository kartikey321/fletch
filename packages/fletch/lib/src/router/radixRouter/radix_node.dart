// radix_node.dart
part of 'radix_route.dart';

/// A node in the radix tree.
///
/// Children are split into four typed slots so that [RadixRouter._findRouteMatch]
/// never iterates a [Map.values] iterable:
///
///   • [staticChildren]        — keyed by literal segment string, O(1) lookup.
///   • [regexParamChildren]    — list of `:param(regex)` nodes, tried in
///                               insertion order (regex before plain).
///   • [wildcardParamChildren] — list of plain `:param` nodes (usually one).
///   • [globChild]             — the single `*` catch-all node.
///
/// All lists are null until the first matching route is registered, keeping
/// the common case (static-only tree) allocation-free.
class RadixNode {
  /// The path segment this node represents.
  final String segment;

  /// Named parameter for dynamic segments (`null` for static / glob nodes).
  final String? paramName;

  /// Regex constraint for parameter validation (`null` for wildcards / static / glob).
  final RegExp? regex;

  /// `true` when this node is a glob wildcard (`*`) that consumes ALL remaining
  /// path segments.
  final bool isGlob;

  // ── Child slots ────────────────────────────────────────────────────────────

  /// Static segment children — keyed by literal segment string.
  /// Allocated lazily; `null` means no static children.
  Map<String, RadixNode>? staticChildren;

  /// Regex-constrained parameter children — e.g. `:id(\d+)`.
  /// Tried in insertion order before [wildcardParamChildren].
  /// `null` means no regex param children at this level.
  List<RadixNode>? regexParamChildren;

  /// Plain wildcard parameter children — e.g. `:id`, `:slug`.
  /// Usually contains at most one entry per tree level.
  /// `null` means no wildcard param children at this level.
  List<RadixNode>? wildcardParamChildren;

  /// The single `*` glob child, or `null` if none.
  RadixNode? globChild;

  // ── Route data ─────────────────────────────────────────────────────────────

  /// HTTP method → handler map for this node.
  final Map<String, RequestHandler> handlers = {};

  /// Mounted [RouterInterface] for [IsolatedContainer] sub-apps.
  RouterInterface? isolatedRouter;

  RadixNode._({
    required this.segment,
    this.paramName,
    this.regex,
    this.isGlob = false,
  });

  factory RadixNode.root() => RadixNode._(segment: '');
  factory RadixNode.static(String segment) => RadixNode._(segment: segment);
  factory RadixNode.dynamic(String segment, String paramName, RegExp? regex) =>
      RadixNode._(segment: segment, paramName: paramName, regex: regex);

  /// Creates a glob node. Pass [paramName] to capture the matched remainder
  /// into `req.params`, e.g. the `path` in `/*:path`.
  factory RadixNode.glob({String? paramName}) =>
      RadixNode._(segment: '*', isGlob: true, paramName: paramName);

  /// Whether this node carries a named parameter (`:id` or `:id(\d+)`).
  bool get isDynamic => paramName != null;
}
