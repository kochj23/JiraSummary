# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Performance improvements
- Additional features based on community feedback

## [1.3.0] - 2026-11-11

### Changed
- AI: migrated to NovaAIKit 1.0.0 (AI on/off, built-in fallback summary, Auto failover across Ollama, MLX, TinyLLM,
  TinyChat, OpenWebUI, Nova Gateway, OpenRouter and OpenAI with timeouts/retries, model picker and editable URLs,
  Keychain-only https-only keys under `com.jkoch.jirasummary.*`, status indicator, output validation).
- Activity summaries are now generated on every refresh (AI or built-in) and show their source.
- Version/build come from project.yml; the About panel and local API report the real version.

### Removed
- Google Cloud, Azure, AWS and IBM Watson AI backends; per-app temperature/max-token sliders, usage statistics and
  the in-app LLM load balancer (replaced by NovaAIKit Auto failover).

### Security
- One-time migration moves the OpenAI key to `com.jkoch.jirasummary.openai` and deletes stored Google/Azure/AWS/IBM
  secrets from the Keychain and UserDefaults.

## [1.0.0] - 2025-01-01

### Added
- Initial release
- Core functionality
- macOS native interface
- MIT License

---

*For detailed release notes, see [GitHub Releases](https://github.com/kochj23/JiraSummary/releases).*
