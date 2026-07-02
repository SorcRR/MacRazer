// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The facts about one HID interface that device selection needs — extracted from
/// `IOHIDDevice` properties into plain values so the ranking logic is unit-testable.
struct HIDInterfaceInfo: Equatable {
    let pid: Int
    /// USB location — distinguishes two units of the same model (same PID, different port).
    let locationID: Int
    let usagePage: Int
    let usage: Int
    let maxFeatureReportSize: Int
}

/// Picks which physical device — and which of its interfaces — to bind as the Razer control
/// channel. Matching is vendor-wide (any VID 0x1532 product enumerates), so with a Razer
/// keyboard or a second mouse attached, "highest feature-report score anywhere" could bind
/// the wrong product entirely; ranking by device first prevents that.
enum HIDDeviceSelection {
    /// Interfaces that can carry the 90-byte Razer control report.
    static let controlReportSize = 90

    /// Index into `interfaces` of the control interface to open, or nil if no interface can
    /// carry the control report.
    ///
    /// Devices (interfaces grouped by pid+location) are ranked:
    /// 1. a PID in the `RazerDevices` registry — a known mouse — always wins;
    /// 2. else a device exposing a Mouse usage interface (0x01/0x02) beats one that doesn't
    ///    (an unknown Razer mouse vs. a keyboard — though a keyboard that also exposes a
    ///    pointer interface can still tie here; the registry rank is the reliable signal);
    /// 3. ties break on lowest locationID, then lowest PID (reachable when devices don't
    ///    report a LocationID and default to 0) — so which of two identical mice wins is
    ///    stable across reconnects instead of following Set/Dictionary iteration order.
    /// Within the winning device, the interface with the best `controlScore` is chosen.
    static func controlInterfaceIndex(interfaces: [HIDInterfaceInfo]) -> Int? {
        struct DeviceKey: Hashable { let pid: Int; let locationID: Int }
        let groups = Dictionary(grouping: interfaces.indices) {
            DeviceKey(pid: interfaces[$0].pid, locationID: interfaces[$0].locationID)
        }

        func deviceRank(_ members: [Int]) -> Int {
            if RazerDevices.info(pid: interfaces[members[0]].pid) != nil { return 2 }
            if members.contains(where: { interfaces[$0].usagePage == 0x01 && interfaces[$0].usage == 0x02 }) { return 1 }
            return 0
        }

        var best: (rank: Int, locationID: Int, score: Int, index: Int)?
        for (key, members) in groups {
            let candidates = members.filter { interfaces[$0].maxFeatureReportSize >= controlReportSize }
            guard let top = candidates.max(by: { controlScore(interfaces[$0]) < controlScore(interfaces[$1]) })
            else { continue } // this device has no interface that can carry the control report
            let entry = (rank: deviceRank(members), locationID: key.locationID,
                         score: controlScore(interfaces[top]), index: top)
            guard let current = best else { best = entry; continue }
            if entry.rank != current.rank {
                if entry.rank > current.rank { best = entry }
            } else if entry.locationID != current.locationID {
                if entry.locationID < current.locationID { best = entry }
            } else if entry.score != current.score {
                if entry.score > current.score { best = entry }
            } else if interfaces[entry.index].pid < interfaces[current.index].pid {
                // Total order even when everything else ties (two LocationID-less devices):
                // Dictionary iteration order varies per process and must not pick the winner.
                best = entry
            }
        }
        return best?.index
    }

    /// Higher score = more likely to be this device's Razer control interface. (Which
    /// *device* to use is decided by the ranking above; this only picks among one device's
    /// own interfaces.)
    static func controlScore(_ i: HIDInterfaceInfo) -> Int {
        var score = i.maxFeatureReportSize        // prefer interfaces carrying big feature reports
        if i.usagePage >= 0xFF00 { score += 1000 } // vendor-defined usage page (some models)
        if i.usagePage == 0x01 && i.usage == 0x02 { score += 500 } // the Mouse interface over a keyboard's
        return score
    }
}
