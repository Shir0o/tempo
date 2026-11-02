# 08: Mac and automation

**What to build:** The macOS menu bar shows the Lap's elapsed time. In the QuickPopover, number keys 1–9 label the Lap and a key or button splits it. Through the DeepLinkBus, `tempo://start?activity=…` and the Android start intent now label the Lap, and a new `tempo://split` splits it.

**Blocked by:** 03

**Status:** ready-for-agent

- [ ] Menu bar text = Lap elapsed time, no pause/stop items
- [ ] Popover: 1–9 label, Split available, undo bar shown for 3s
- [ ] `tempo://start` keeps its name but labels the Lap; `tempo://split` added; Android intent mirrors both
- [ ] Unknown Activity in a link is refused without changing the Lap
- [ ] Targeted tests for the deep-link parser
