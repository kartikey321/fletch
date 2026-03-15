// radix_node.dart
part of 'radix_route.dart';

/// Represents a node in the radix tree routing structure
class RadixNode {
  /// The path segment this node represents
  final String segment;

  /// Child nodes keyed by their segment
  final Map<String, RadixNode> children = {};

  /// Named parameter for dynamic segments (null for static / glob nodes)
  final String? paramName;

  /// Regex constraint for parameter validation (null for wildcards/static/glob)
  final RegExp? regex;

  /// True when this node is a glob wildcard (`*`) that consumes ALL remaining
  /// path segments.  Glob nodes are always leaves — they have no children.
  final bool isGlob;

  /// Registered handlers for different HTTP methods
  final Map<String, RequestHandler> handlers = {};
  RouterInterface? isolatedRouter;

  RadixNode._({
    required this.segment,
    this.paramName,
    this.regex,
    this.isGlob = false,
  });

  /// Create root node
  factory RadixNode.root() => RadixNode._(segment: '');

  /// Create static route node
  factory RadixNode.static(String segment) => RadixNode._(segment: segment);

  /// Create dynamic route node (`:param` or `:param(regex)`)
  factory RadixNode.dynamic(String segment, String paramName, RegExp? regex) =>
      RadixNode._(segment: segment, paramName: paramName, regex: regex);

  /// Create a glob-wildcard node (`*`) that matches all remaining segments.
  factory RadixNode.glob() => RadixNode._(segment: '*', isGlob: true);

  /// Whether this node represents a static path segment
  bool get isStatic => paramName == null && !isGlob;

  /// Whether this node represents a regex-constrained parameter
  bool get isRegex => isDynamic && regex != null;

  /// Whether this node represents a single-segment wildcard parameter
  bool get isWildcard => isDynamic && regex == null;

  /// Whether this node represents a dynamic (named) parameter
  bool get isDynamic => paramName != null;
}
