# Notices & Attribution

## Trademark / unofficial status
This is an **independent, community project. It is not affiliated with, authorized by, or
endorsed by Razer Inc.** "Razer", the Razer logo, "Cobra", "HyperSpeed", "Synapse", and
"Chroma" are trademarks of Razer Inc., used here only to describe compatibility. No
affiliation or endorsement is implied.

## License
This project is licensed under the **GNU General Public License v2.0** (see [`LICENSE`](LICENSE)).
It is GPL because it is derived from OpenRazer (see below).

## Attribution
- **[OpenRazer](https://github.com/openrazer/openrazer)** (GPL-2.0-or-later), the device
 HID protocol implemented here (command bytes, the `razer_report` structure, CRC, the
 Cobra Pro command set) was **ported from OpenRazer's Linux driver source**. The hard
 reverse-engineering is theirs.
- **Razer Cobra HyperSpeed support** is based on OpenRazer PR
 [#2583](https://github.com/openrazer/openrazer/pull/2583) by **dyharlan**, reviewed by
 **z3ntu**, which confirmed the device reuses the Cobra Pro protocol.
- **Bluetooth control** uses Razer's vendor GATT service as reverse-engineered by
 **[@ungrav](https://github.com/ungrav)** on the Basilisk V3 X HyperSpeed in
 [#32](https://github.com/SorcRR/MacRazer/pull/32): the service and characteristic ids, the
 frame layout and the command keys. This project confirmed the same service on the Cobra
 HyperSpeed.
- The app uses its **own original mouse icon/logo**; it does not bundle or display Razer's
 logo or marks.
- **Scroll-source research:** [Scroll Reverser](https://github.com/pilotmoon/Scroll-Reverser)
 by **[@pilotmoon](https://github.com/pilotmoon)** documents identifying a scroll event's
 HID sender and preserving its line, pixel and fixed-point deltas. MacRazer's scroll
 reversal is implemented here using the system interfaces; no Scroll Reverser code is bundled.
- **Dock-swipe research:** [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix) by
 **[Noah Nübling](https://github.com/noah-nuebling)** documents the events macOS uses for the
 trackpad's Spaces and Mission Control swipes (their types, fields, phases and scale), and
 [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) by
 **[@jurplel](https://github.com/jurplel)** confirmed their direction. The gesture swipes that
 follow the pointer are implemented here from that format; no code from either is bundled.
- **Device-mode and private-key research:** that a Razer mouse in driver mode reports its DPI
 button as "private keys" in HID report 4 comes from
 [OpenRazer](https://github.com/openrazer/openrazer); the Bluetooth key that reads and sets the
 device mode, and the key codes, were learned from the protocol notes of
 [OpenSnek](https://github.com/gh123man/OpenSnek) by **[@gh123man](https://github.com/gh123man)**,
 [OpenSynapse](https://github.com/A1mAssist/OpenSynapse) and
 [ergo-control](https://github.com/serafinski/ergo-control) by
 **[@serafinski](https://github.com/serafinski)**, then confirmed on a Cobra HyperSpeed. The
 Cobra's DPI button hold and swipe is implemented here from those facts; no code from them is
 bundled.
- Hardware findings unique to this project (e.g. brightness living on the LOGO LED, the
 31 ms request/response timing on macOS) were verified on real hardware and are documented
 in [`docs/DOCUMENTATION.md`](docs/DOCUMENTATION.md).

## Disclaimer
Provided "as is", without warranty of any kind. It communicates with your mouse over HID;
while it only sends the same feature reports OpenRazer/Synapse use, you run it at your own
risk.
