# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Fixes a bug, where ping requests were not sent in time when there was only incoming data,
  e.g. QoS 0 messages being received, which could cause the broker to disconnect the client.

## [1.0.0] - 2025-07-20

### Added
- Initial release with basic functionality.

[Unreleased]: https://github.com/sbergen/spoke/compare/spoke_core-v1.0.0...HEAD
[1.0.0]: https://github.com/sbergen/spoke/releases/tag/spoke_core-v1.0.0
