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
- The app uses its **own original mouse icon/logo**; it does not bundle or display Razer's
 logo or marks.
- Hardware findings unique to this project (e.g. brightness living on the LOGO LED, the
 31 ms request/response timing on macOS) were verified on real hardware and are documented
 in [`docs/DOCUMENTATION.md`](docs/DOCUMENTATION.md).

## Disclaimer
Provided "as is", without warranty of any kind. It communicates with your mouse over HID;
while it only sends the same feature reports OpenRazer/Synapse use, you run it at your own
risk.
