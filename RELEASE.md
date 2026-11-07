# Changelog

## [1.14.0](https://github.com/Shir0o/tempo/compare/v1.13.0...v1.14.0) (2026-11-07)


### Features

* **today:** split Repeat into Still and Again ([#106](https://github.com/Shir0o/tempo/issues/106)) ([0b5ee8f](https://github.com/Shir0o/tempo/commit/0b5ee8fc807b760bad66842099b5b21dc6cd734c))

## [1.13.0](https://github.com/Shir0o/tempo/compare/v1.12.0...v1.13.0) (2026-11-07)


### Features

* **android:** adaptive launcher icon with themed-icon layer ([#100](https://github.com/Shir0o/tempo/issues/100)) ([e5bc626](https://github.com/Shir0o/tempo/commit/e5bc62611aea38be0b0d9d6e1dffca0b0301a407))
* **history:** show a Record's tags as chips on its block ([#105](https://github.com/Shir0o/tempo/issues/105)) ([2b10945](https://github.com/Shir0o/tempo/commit/2b109453b810088fac4ba1efef228509d4cc8d95))
* **settings:** regroup Settings into a short main list with sub-pages ([#101](https://github.com/Shir0o/tempo/issues/101)) ([c0c3e0a](https://github.com/Shir0o/tempo/commit/c0c3e0a0e7ae5447b18d4cb864ce53d6f3a790ae))


### Bug Fixes

* **backup:** keep backing up when the store has a coverage defect ([#103](https://github.com/Shir0o/tempo/issues/103)) ([6c818cc](https://github.com/Shir0o/tempo/commit/6c818ccc2d0bdd9be5c7d4c269dbd0de1d5b9910)), closes [#102](https://github.com/Shir0o/tempo/issues/102)

## [1.12.0](https://github.com/Shir0o/tempo/compare/v1.11.0...v1.12.0) (2026-11-06)


### Features

* **history:** Tags row with "+ New tag" in the record edit sheet ([#98](https://github.com/Shir0o/tempo/issues/98)) ([6855e53](https://github.com/Shir0o/tempo/commit/6855e53266da8012d310a854925d7ca4c9bdd41d))
* **today:** add activity filter sheet with platform speech input ([#97](https://github.com/Shir0o/tempo/issues/97)) ([59f9434](https://github.com/Shir0o/tempo/commit/59f94348e99e3efd4f28b7e0c3707141a0f457d8))

## [1.11.0](https://github.com/Shir0o/tempo/compare/v1.10.1...v1.11.0) (2026-11-06)


### Features

* **history:** time and note first, Activity behind a searchable picker ([#90](https://github.com/Shir0o/tempo/issues/90)) ([8e9d955](https://github.com/Shir0o/tempo/commit/8e9d9559e24c3b7228ef0348f0f08302685b1c65))
* **notification:** repeat the last Activity as the first action ([#95](https://github.com/Shir0o/tempo/issues/95)) ([f5b2a70](https://github.com/Shir0o/tempo/commit/f5b2a70a0afe3a37bb62e8244fd9096ae4730d1c))
* **tags:** designate the Contact tag by flag and auto-tag People ([#93](https://github.com/Shir0o/tempo/issues/93)) ([87afca9](https://github.com/Shir0o/tempo/commit/87afca9e44bd489e48742717637c6d0d6bc647fc))
* **today:** Last logged row to add a note without opening History ([#94](https://github.com/Shir0o/tempo/issues/94)) ([6119cb8](https://github.com/Shir0o/tempo/commit/6119cb89f582ad08f46deaba11875332084b4589))
* **today:** separate note suggestions from Activity suggestions ([#87](https://github.com/Shir0o/tempo/issues/87)) ([5524390](https://github.com/Shir0o/tempo/commit/5524390f232334cfd9832360d43dd06d4431e2da))
* **ui:** auto-assign emoji icons to Activities (closes [#91](https://github.com/Shir0o/tempo/issues/91)) ([#92](https://github.com/Shir0o/tempo/issues/92)) ([7e75381](https://github.com/Shir0o/tempo/commit/7e75381aa50c81bf5d3395080e0b81a6b519d3e4))


### Bug Fixes

* **ui:** refresh Totals when the tab becomes active ([#88](https://github.com/Shir0o/tempo/issues/88)) ([17a50ca](https://github.com/Shir0o/tempo/commit/17a50ca0d5794353e5d995c8716023988a95ea76))

## [1.10.1](https://github.com/Shir0o/tempo/compare/v1.10.0...v1.10.1) (2026-11-06)


### Bug Fixes

* **release:** keep restricted entitlements out of macOS builds ([#84](https://github.com/Shir0o/tempo/issues/84)) ([e73e885](https://github.com/Shir0o/tempo/commit/e73e8856e60258df536a6abadde87b12b74a2151))
* **wear:** one label per tap and a real idle timer (closes [#83](https://github.com/Shir0o/tempo/issues/83)) ([#86](https://github.com/Shir0o/tempo/issues/86)) ([cddf715](https://github.com/Shir0o/tempo/commit/cddf71552ed16633841c1eb995d34afdaae400f9))

## [1.10.0](https://github.com/Shir0o/tempo/compare/v1.9.1...v1.10.0) (2026-11-06)


### Features

* **log:** notes, People chips, AutoAdvance and wider Today tiles ([#82](https://github.com/Shir0o/tempo/issues/82)) ([f3deb6d](https://github.com/Shir0o/tempo/commit/f3deb6d5c2f6b613e7446100d75d4d892ab773c3))
* **sync:** single-writer phone replication and verified backups ([#69](https://github.com/Shir0o/tempo/issues/69)) ([f6c61a3](https://github.com/Shir0o/tempo/commit/f6c61a31551b0544920da26745d74468e2d72a6a))
* use decayed Markov-2 activity suggestions ([#81](https://github.com/Shir0o/tempo/issues/81)) ([c0720dd](https://github.com/Shir0o/tempo/commit/c0720ddd983c7fe3a611b26e4c782ab1e3de1ecc))


### Bug Fixes

* **release:** give the Wear OS bundle its own changelog ([#74](https://github.com/Shir0o/tempo/issues/74)) ([4271159](https://github.com/Shir0o/tempo/commit/427115969fefcac0028c46d8ecdaccdac1443c1a))

## [1.9.1](https://github.com/Shir0o/tempo/compare/v1.9.0...v1.9.1) (2026-11-05)


### Bug Fixes

* **wear:** target API 36 so Play accepts the watch bundle ([#71](https://github.com/Shir0o/tempo/issues/71)) ([034b4f2](https://github.com/Shir0o/tempo/commit/034b4f2af2301416c1f8f43073917220205083f0))

## [1.9.0](https://github.com/Shir0o/tempo/compare/v1.8.2...v1.9.0) (2026-11-05)


### Features

* **store:** add Play listing assets and store description ([#70](https://github.com/Shir0o/tempo/issues/70)) ([0901e84](https://github.com/Shir0o/tempo/commit/0901e84c5b4a62d0652ffce9118dfc5401a22dac))


### Bug Fixes

* **ci:** set explicit permissions in ci workflow (alert [#1](https://github.com/Shir0o/tempo/issues/1)) ([#66](https://github.com/Shir0o/tempo/issues/66)) ([25c02a7](https://github.com/Shir0o/tempo/commit/25c02a74877dac454adf938897c1f0593a180f73))
* **release:** fail the run when the Wear OS upload is rejected ([#68](https://github.com/Shir0o/tempo/issues/68)) ([f6e1254](https://github.com/Shir0o/tempo/commit/f6e1254196ebc06b0cedf7b500211140169ebbaf))

## [1.8.2](https://github.com/Shir0o/tempo/compare/v1.8.1...v1.8.2) (2026-11-05)


### Bug Fixes

* **sync:** renew an expired Google Drive access token ([#64](https://github.com/Shir0o/tempo/issues/64)) ([3b60464](https://github.com/Shir0o/tempo/commit/3b604641b78d9d347509dfb98f0ffaba30cad87a))

## [1.8.1](https://github.com/Shir0o/tempo/compare/v1.8.0...v1.8.1) (2026-11-05)


### Bug Fixes

* **wear:** add a launcher icon so Play accepts the Wear bundle ([#62](https://github.com/Shir0o/tempo/issues/62)) ([61016e0](https://github.com/Shir0o/tempo/commit/61016e048695a7a2a016b6e0d25029a9e6e09fa0))

## [1.8.0](https://github.com/Shir0o/tempo/compare/v1.7.0...v1.8.0) (2026-11-04)


### Features

* smart activity suggestions by pattern, visual coherence, and tag import ([#59](https://github.com/Shir0o/tempo/issues/59)) ([cb15b17](https://github.com/Shir0o/tempo/commit/cb15b1730ef4e19ec3e68b3da5a698213a1355dd))


### Bug Fixes

* **release:** upload the Wear OS bundle using absolute paths ([#60](https://github.com/Shir0o/tempo/issues/60)) ([af0fc18](https://github.com/Shir0o/tempo/commit/af0fc18e9f50752127d5db26627b1bd614952a08))

## [1.7.0](https://github.com/Shir0o/tempo/compare/v1.6.0...v1.7.0) (2026-11-04)


### Features

* **notification:** one-tap Lap labeling on phone and Wear OS ([#55](https://github.com/Shir0o/tempo/issues/55)) ([d7a04ff](https://github.com/Shir0o/tempo/commit/d7a04ff4da4bddf0b3f27ee44d78b7018a3d7c13))

## [1.6.0](https://github.com/Shir0o/tempo/compare/v1.5.0...v1.6.0) (2026-11-04)


### Features

* **categories:** give every activity its category's colour ([#54](https://github.com/Shir0o/tempo/issues/54)) ([62523ea](https://github.com/Shir0o/tempo/commit/62523ead6cfd37327cbab987e0cda5565cc8c5a7))
* **today:** order activities by category, with a setting ([#52](https://github.com/Shir0o/tempo/issues/52)) ([0fcc137](https://github.com/Shir0o/tempo/commit/0fcc137771e00d25398196deb30e3a118f4d3582))

## [1.5.0](https://github.com/Shir0o/tempo/compare/v1.4.3...v1.5.0) (2026-11-04)


### Features

* **icon:** replace Flutter default with Day Ring app icon ([#49](https://github.com/Shir0o/tempo/issues/49)) ([feac932](https://github.com/Shir0o/tempo/commit/feac9323ae69734aec370344a7f8ae6aa21e4bda))
* **records:** adjust one Record's start or end edge ([#51](https://github.com/Shir0o/tempo/issues/51)) ([25f2c10](https://github.com/Shir0o/tempo/commit/25f2c1090b1da8ef8760b1154b4c5ae580ce0d84))

## [1.4.3](https://github.com/Shir0o/tempo/compare/v1.4.2...v1.4.3) (2026-11-04)


### Bug Fixes

* **import:** replace untracked gaps instead of blocking on them ([#45](https://github.com/Shir0o/tempo/issues/45)) ([0579534](https://github.com/Shir0o/tempo/commit/0579534dc7726aa9b22613ce918ca8bc15fc4cab))

## [1.4.2](https://github.com/Shir0o/tempo/compare/v1.4.1...v1.4.2) (2026-11-04)


### Bug Fixes

* **import:** parse CSV wall clock without host local bias ([#43](https://github.com/Shir0o/tempo/issues/43)) ([f03b021](https://github.com/Shir0o/tempo/commit/f03b02129807123a03fb80af3f8867b6e00e2f2c))

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
