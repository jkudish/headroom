# Third-party notices

Headroom's original code is covered by the [MIT license](LICENSE). Provider names and artwork identify the services; they remain the property of their respective owners. Headroom's license doesn't grant trademark rights or imply provider endorsement.

## Reference projects

- [CodexBar](https://github.com/steipete/CodexBar), by Peter Steinberger and contributors, informed the native menu and provider parsing. References include the [Amp parser](https://github.com/steipete/CodexBar/blob/3bfbf4a51d3af6c7307d5aa189e85b3e94390fe8/Sources/CodexBarCore/Providers/Amp/AmpUsageParser.swift) and [Claude optional credit/reset fields](https://github.com/steipete/CodexBar/tree/2e19c9276bd43286b28b662804825387ac8b0e17/Sources/CodexBarCore/Providers/Claude).
- [Rashun](https://github.com/AlexanderHeffernan/Rashun), by Alexander Heffernan and contributors, was a reference for investigating Amp Orb usage.
- [Official Grok helper source](https://github.com/xai-org/grok-build/tree/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8) informed isolated helper authentication. Helpers are installed separately, not bundled. Source licensing doesn't imply permission to register a third-party OAuth client or use a hosted service.

CodexBar and Rashun publish the following MIT notices. Each copyright line applies to its respective project:

```text
MIT License

Copyright (c) 2026 Peter Steinberger
Copyright (c) 2026 Alexander Heffernan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Provider artwork

Bundled PNGs are in `Sources/UsageMonitor/Resources/`. Artwork is resized or rasterized for local display. Some backgrounds and padding are removed; monochrome marks render as appearance-adaptive templates. No logo service is contacted at runtime.

| Resource | Source |
| --- | --- |
| `claude-logo.png` | [Claude website favicon](https://claude.com/) |
| `codex-logo.png` | [Codex product mark via theSVG](https://thesvg.org/icon/codex-openai) |
| `openai-logo.png` | [OpenAI Blossom mark via Wikimedia Commons](https://commons.wikimedia.org/wiki/File:OpenAI_logo_2025_(symbol).svg) |
| `anthropic-logo.png` | [Anthropic website artwork](https://www.anthropic.com/) |
| `grok-logo.png` | [Grok app icon](https://grok.com/images/android-chrome-512x512.png) |
| `grok-bot-logo.png` | Official Grok Bot macOS app icon, extracted from the installed app |
| `xai-logo.png` | [xAI website artwork](https://x.ai/) |
| `amp-logo.png` | [Amp app icon](https://ampcode.com/app-icon.svg) |
| `zai-logo.png` | [z.ai logo](https://z-cdn.chatglm.cn/z-ai/static/logo.svg) |
| `openrouter-logo.png` | [OpenRouter glyph](https://openrouter.ai/favicon/glyph.png) |
| `searchapi-logo.png` | [SearchAPI touch icon](https://www.searchapi.io/apple-touch-icon.png) |
| `dataforseo-logo.png` | [DataForSEO website artwork](https://dataforseo.com/) |
| `firecrawl-logo.png` | [Firecrawl icon](https://www.firecrawl.dev/favicon.png) |
| `serpapi-logo.png` | [SerpAPI favicon](https://serpapi.com/favicon.svg) |
| `tavily-logo.png` | [Tavily website artwork](https://www.tavily.com/) |
| `jina-logo.png` | [Jina AI icon](https://jina.ai/icons/favicon-128x128.png) |
| `parallel-logo.png` | [Parallel website artwork](https://parallel.ai/) |
| `valyu-logo.png` | [Valyu favicon](https://www.valyu.ai/favicon.svg) |
| `you-logo.png` | [You.com brand kit](https://ydc-brand-guidelines.webflow.io/), YDC gradient logomark |
| `exa-logo.png` | [Exa favicon](https://exa.ai/images/favicon-32x32.png), retained for legacy accounts |
| `cursor-logo.png` | [Cursor favicon](https://cursor.com/marketing-static/favicon-light.ico), retained resource |
| `brave-logo.png` | [Brave website artwork](https://brave.com/), retained for legacy accounts |
| `perplexity-logo.png` | [Perplexity favicon](https://www.perplexity.ai/favicon.svg), retained for legacy accounts |
| `gemini-logo.png` | [Gemini website artwork](https://gemini.google.com/), retained for legacy accounts |
| `kagi-logo.png` | [Kagi favicon](https://kagi.com/favicon-32x32.png), retained for legacy accounts |

The Headroom icon in `Assets/Headroom.icon` was created for this project with AI-assisted image generation. README screenshots show Headroom's production views with synthetic demo accounts; they contain no live account data.
