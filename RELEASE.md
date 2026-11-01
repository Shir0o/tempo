# Changelog

## [1.1.0](https://github.com/Shir0o/tempo/compare/v1.0.0...v1.1.0) (2026-11-01)


### Features

* **core:** implement timer state machine and crash recovery ([252703e](https://github.com/Shir0o/tempo/commit/252703e9b453a3e76ec8c472e0e4716d5687ab61))
* **db:** implement SQLite storage, models, and migrations ([1f2057b](https://github.com/Shir0o/tempo/commit/1f2057b840d387940e4d6eb067d417d8e9550ece))
* **desktop:** implement macOS menu bar, popover, and deep links ([24a131f](https://github.com/Shir0o/tempo/commit/24a131f3b3458ab3d3f10210738eb549455e2601))
* **export:** implement atomic live CSV export engine ([3d6a319](https://github.com/Shir0o/tempo/commit/3d6a319b5a0074270fb50f6e8977a1f51d61861e))
* **mcp:** implement local stdio MCP server with PII sanitization ([d0050ea](https://github.com/Shir0o/tempo/commit/d0050eadb65035addef77f1f278c72b59ec8b363))
* **mobile:** add dashboard, stats, automations, and drive sync ([2bf2bda](https://github.com/Shir0o/tempo/commit/2bf2bdad329a06703b2967c3a6478863718a642b))
* setup automated release pipeline for Android and macOS ([#5](https://github.com/Shir0o/tempo/issues/5)) ([a3dbfd7](https://github.com/Shir0o/tempo/commit/a3dbfd71b3ab9aa29683a2ce6c15ae8748a14862))
* **wear:** implement Wear OS companion, tiles, complications, and sync ([d92e13a](https://github.com/Shir0o/tempo/commit/d92e13a5d401dd35b47757a7e48bb71ed1320a63))


### Bug Fixes

* **desktop:** resolve race condition in menu bar activity name caching ([#4](https://github.com/Shir0o/tempo/issues/4)) ([7b64ae1](https://github.com/Shir0o/tempo/commit/7b64ae17ac89edd5d9aec736e41da1f32453f4c5))
* **wearable:** resolve race condition in wearable sync test ([#10](https://github.com/Shir0o/tempo/issues/10)) ([189ef92](https://github.com/Shir0o/tempo/commit/189ef924d80a583e40841342b57f145ad3160c92))

## Release Notes

All notable changes to Tempo will be documented in this file.
