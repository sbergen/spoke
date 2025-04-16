# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2] - 2025-04-16

### Fixed
- Don't panic when a ping is scheduled around the same time as we are sending
  another packet.

## [1.0.1] - 2025-02-15

### Fixed
- Close the connection if the session actor dies.
- Clarify documentation about `updates` properly functioning only in the process that created the client.

## [1.0.0] - 2025-01-18

### Added
- Initial release with basic functionality.

[Unreleased]: https://github.com/sbergen/spoke/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/sbergen/spoke/releases/tag/v1.0.2
[1.0.1]: https://github.com/sbergen/spoke/releases/tag/v1.0.1
[1.0.0]: https://github.com/sbergen/spoke/releases/tag/v1.0.0