# Changelog

## [1.4.1](https://github.com/Shir0o/tempo/compare/v1.4.0...v1.4.1) (2026-11-04)


### Bug Fixes

* **import:** retain intervals past lapStart and advance open Lap ([#41](https://github.com/Shir0o/tempo/issues/41)) ([d63a229](https://github.com/Shir0o/tempo/commit/d63a229a6f24e30192839973f812c96abcf3c076))

## [1.4.0](https://github.com/Shir0o/tempo/compare/v1.3.0...v1.4.0) (2026-11-03)


### Features

* **import:** import STT catalog and history with categories ([#39](https://github.com/Shir0o/tempo/issues/39)) ([1173ae7](https://github.com/Shir0o/tempo/commit/1173ae735b77f1c387ddc7bb6e9754ccac21128a))

## [1.3.0](https://github.com/Shir0o/tempo/compare/v1.2.0...v1.3.0) (2026-11-03)


### Features

* **sync:** wire Google Drive sign-in for Android and macOS ([#37](https://github.com/Shir0o/tempo/issues/37)) ([cf5e9cc](https://github.com/Shir0o/tempo/commit/cf5e9cc14ff4855f14b0b016122d9a8a82f84417))

## [1.2.0](https://github.com/Shir0o/tempo/compare/v1.1.0...v1.2.0) (2026-11-03)


### Features

* **dashboard:** build Color Blocks dashboard (design D) ([#28](https://github.com/Shir0o/tempo/issues/28)) ([463cb1b](https://github.com/Shir0o/tempo/commit/463cb1b8f75c3d4a8b42feee4f3ade13870fd931)), closes [#19](https://github.com/Shir0o/tempo/issues/19)
* **desktop:** label the Lap from the menu bar and deep links ([#32](https://github.com/Shir0o/tempo/issues/32)) ([89f7dc5](https://github.com/Shir0o/tempo/commit/89f7dc5f41fe61ae14f54aa7335bd3bb43deb1c2))
* **mcp:** describe days and gate write tools ([#22](https://github.com/Shir0o/tempo/issues/22)) ([#33](https://github.com/Shir0o/tempo/issues/33)) ([9cfddec](https://github.com/Shir0o/tempo/commit/9cfddec6db98c5c245b7231759a7ee8cba4897c6))
* **records:** add Split, Untracked Records and undo ([#16](https://github.com/Shir0o/tempo/issues/16)) ([#27](https://github.com/Shir0o/tempo/issues/27)) ([ee3ae5e](https://github.com/Shir0o/tempo/commit/ee3ae5e3b201ddaa0b614d67454a849b6e42dac5))
* **records:** correct past Records by editing their boundaries ([#30](https://github.com/Shir0o/tempo/issues/30)) ([508041a](https://github.com/Shir0o/tempo/commit/508041af4800e9e83dabbbfeba8ff739c93b6a64))
* **records:** split Laps and Records at local midnight ([#17](https://github.com/Shir0o/tempo/issues/17)) ([#29](https://github.com/Shir0o/tempo/issues/29)) ([82fc49e](https://github.com/Shir0o/tempo/commit/82fc49e936997579ebee4abb95618508abb84d72))
* **records:** store real time zones on Records ([#25](https://github.com/Shir0o/tempo/issues/25)) ([eff1778](https://github.com/Shir0o/tempo/commit/eff177822bd74b0ae1f33225fec26c2dd051fa23))
* **state:** replace the active timer with an always-running Lap ([#26](https://github.com/Shir0o/tempo/issues/26)) ([266174d](https://github.com/Shir0o/tempo/commit/266174d15629f76d7f4e6d719e71d8e077827237))
* **ui:** restyle remaining screens to design D ([#36](https://github.com/Shir0o/tempo/issues/36)) ([d2ae65e](https://github.com/Shir0o/tempo/commit/d2ae65e815f91e7722a18fb8a0944a2cf12a8582))
* **wear:** label and exit from the watch ([#31](https://github.com/Shir0o/tempo/issues/31)) ([96dd874](https://github.com/Shir0o/tempo/commit/96dd87460be22426ea787a85e7e873f6576f2a68)), closes [#20](https://github.com/Shir0o/tempo/issues/20)


### Bug Fixes

* close spec 08 correctness gaps from review ([#35](https://github.com/Shir0o/tempo/issues/35)) ([b3a7aba](https://github.com/Shir0o/tempo/commit/b3a7aba4061cf9c6a9b8824c36d0fa06b78123fe))
* **export:** write CSV times in each record's own time zone ([#11](https://github.com/Shir0o/tempo/issues/11)) ([5eb5729](https://github.com/Shir0o/tempo/commit/5eb5729834e210c33e4485de04c5c0ad5e44abb1))


### Refactoring

* **state:** remove the old timer model ([#34](https://github.com/Shir0o/tempo/issues/34)) ([6be7287](https://github.com/Shir0o/tempo/commit/6be7287df1697ccfe913d5278b891ca53eaa0dd3))

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
