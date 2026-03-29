/// The entrypoint for the **server** environment.
///
/// The [main] method will only be executed on the server during pre-rendering.
/// To run code on the client, check the `main.client.dart` file.
library;

import 'dart:io';

// Server-specific Jaspr import.
import 'package:jaspr/dom.dart';
import 'package:jaspr/server.dart';

import 'package:jaspr_content/components/callout.dart';
import 'package:jaspr_content/components/header.dart';
import 'package:jaspr_content/components/image.dart';
import 'package:jaspr_content/components/sidebar.dart';
import 'package:jaspr_content/components/theme_toggle.dart';
import 'package:jaspr_content/jaspr_content.dart';
import 'package:jaspr_content/theme.dart';

import 'components/toc_highlighter.dart';
import 'components/safe_code_block.dart';
import 'components/github_button.dart';
import 'layouts/docs_layout_with_toc_highlighter.dart';

// This file is generated automatically by Jaspr, do not remove or edit.
import 'main.server.options.dart';

void main() {
  // Initializes the server environment with the generated default options.
  Jaspr.initializeApp(
    options: defaultServerOptions,
  );

  // Starts the app.
  //
  // [ContentApp] spins up the content rendering pipeline from jaspr_content to render
  // your markdown files in the content/ directory to a beautiful documentation site.
  runApp(
    ContentApp(
      // Enables mustache templating inside the markdown files.
      templateEngine: MustacheTemplateEngine(),
      parsers: [
        MarkdownParser(),
      ],
      extensions: [
        // Adds heading anchors to each heading.
        HeadingAnchorsExtension(),
        // Generates a table of contents for each page.
        TableOfContentsExtension(),
      ],
      components: [
        // The <Info> block and other callouts.
        Callout(),
        // Adds syntax highlighting to code blocks with safe fallbacks.
        SafeCodeBlock(
          defaultLanguage: 'dart',
          grammars: loadSafeGrammars(),
        ),

        // Adds zooming and caption support to images.
        Image(zoom: true),
        // Highlights the current TOC entry while scrolling.
        CustomComponent(
          pattern: 'TocHighlighter',
          builder: (_, __, ___) => const TocHighlighter(),
        ),
      ],
      layouts: [
        // Out-of-the-box layout for documentation sites.
        DocsLayoutWithTocHighlighter(
          header: Header(
            title: 'Fletch',
            logo: '/images/logo.svg',
            items: [
              // Responsive style to hide Discord on mobile to prevent overlap

              // Discord Community
              a(
                href: 'hhttps://discord.gg/rykqYF6Jvn',
                target: Target.blank,
                classes: 'discord-nav-item',
                attributes: {
                  'style':
                      'display: flex !important; align-items: center; margin-right: 16px; flex-shrink: 0; min-width: 24px;',
                },
                [
                  img(
                    src: '/images/discord_logo.svg',
                    width: 24,
                    height: 24,
                    attributes: {
                      'alt': 'Discord',
                      'style':
                          'object-fit: contain !important; width: 24px; height: 24px; min-width: 24px; min-height: 24px;',
                    },
                  ),
                ],
              ),
              // Enables switching between light and dark mode.
              ThemeToggle(),

              // Shows github stats.
              MyGitHubButton(repo: 'kartikey321/fletch'),
            ],
          ),
          sidebar: Sidebar(
            groups: [
              SidebarGroup(
                title: 'Getting Started',
                links: [
                  SidebarLink(text: "Overview", href: '/'),
                  SidebarLink(text: "Installation", href: '/getting-started/installation'),
                  SidebarLink(text: "Quick Start", href: '/getting-started/quick-start'),
                ],
              ),
              SidebarGroup(
                title: 'Core Concepts',
                links: [
                  SidebarLink(text: "Routing", href: '/core-concepts/routing'),
                  SidebarLink(text: "Middleware", href: '/core-concepts/middleware'),
                  SidebarLink(text: "Sessions", href: '/core-concepts/sessions'),
                  SidebarLink(text: "Error Handling", href: '/core-concepts/error-handling'),
                ],
              ),
              SidebarGroup(
                title: 'Security',
                links: [
                  SidebarLink(text: "CORS", href: '/security/cors'),
                ],
              ),
              SidebarGroup(
                title: 'Deployment',
                links: [
                  SidebarLink(text: "Docker", href: '/deployment/docker'),
                ],
              ),
              SidebarGroup(
                title: 'Examples',
                links: [
                  SidebarLink(text: "TODO API", href: '/examples/todo-api'),
                ],
              ),
              SidebarGroup(
                title: 'Development',
                links: [
                  SidebarLink(text: "Hot Reload", href: '/development/hot-reload'),
                ],
              ),
              SidebarGroup(
                title: 'Advanced',
                links: [
                  SidebarLink(text: "Isolated Containers", href: '/advanced/isolated-containers'),
                ],
              ),
              SidebarGroup(
                title: 'Learn More',
                links: [
                  SidebarLink(text: "About", href: '/about'),
                ],
              ),
            ],
          ),
        ),
      ],
      theme: ContentTheme(
        // Customizes the default theme colors.
        primary: ThemeColor(ThemeColors.blue.$500, dark: ThemeColors.blue.$300),
        background: ThemeColor(ThemeColors.slate.$50, dark: ThemeColors.zinc.$950),
        colors: [
          ContentColors.quoteBorders.apply(ThemeColors.blue.$400),
        ],
      ),
    ),
  );
}

Map<String, String> loadSafeGrammars() {
  final assetPaths = <String, String>{
    'yaml': 'assets/grammars/yaml.json',
    'json': 'assets/grammars/json.json',
    'javascript': 'assets/grammars/javascript.json',
  };

  final map = <String, String>{};
  assetPaths.forEach((lang, path) {
    final file = File(path);
    if (file.existsSync()) {
      map[lang] = file.readAsStringSync();
    }
  });
  return map;
}
