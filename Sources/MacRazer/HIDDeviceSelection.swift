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
    /// The USB product string, to tell a keyboard from a mouse the registry doesn't know.
    var productName = ""
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
    /// A device the registry doesn't know is skipped when its product string names a line that
    /// is never a mouse (`couldBeMouse`): a Razer keyboard alone must not be taken for the mouse.
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
    ///
    /// `preferred` is a device the person picked in the device test: when it's still plugged
    /// in and could be the mouse, it wins over the ranking.
    static func controlInterfaceIndex(interfaces: [HIDInterfaceInfo], preferred: DeviceKey? = nil) -> Int? {
        let ranked = candidates(interfaces: interfaces)
        if let preferred, let chosen = ranked.first(where: { $0.key == preferred }) { return chosen.index }
        return ranked.first?.index
    }

    /// One physical device: interfaces grouped by product and USB location.
    struct DeviceKey: Hashable, Sendable {
        let pid: Int
        let locationID: Int
    }

    /// A device that could be the mouse, with the interface selection would open on it.
    struct Candidate: Equatable {
        let key: DeviceKey
        let name: String
        /// Index into the `interfaces` passed in.
        let index: Int
    }

    /// Every device that could be the mouse, best first, in the order described above.
    static func candidates(interfaces: [HIDInterfaceInfo]) -> [Candidate] {
        let groups = Dictionary(grouping: interfaces.indices) {
            DeviceKey(pid: interfaces[$0].pid, locationID: interfaces[$0].locationID)
        }

        func deviceRank(_ members: [Int]) -> Int {
            if RazerDevices.info(pid: interfaces[members[0]].pid) != nil { return 2 }
            if members.contains(where: { interfaces[$0].usagePage == 0x01 && interfaces[$0].usage == 0x02 }) { return 1 }
            return 0
        }

        var entries: [(rank: Int, score: Int, candidate: Candidate)] = []
        for (key, members) in groups {
            let first = interfaces[members[0]]
            if RazerDevices.info(pid: first.pid) == nil, !couldBeMouse(productName: first.productName) { continue }
            // An accessory MacRazer lights is never the mouse, whatever its product string says.
            if RazerAccessories.info(pid: first.pid) != nil { continue }
            let candidates = members.filter { interfaces[$0].maxFeatureReportSize >= controlReportSize }
            guard let top = candidates.max(by: { controlScore(interfaces[$0]) < controlScore(interfaces[$1]) })
            else { continue } // this device has no interface that can carry the control report
            entries.append((deviceRank(members), controlScore(interfaces[top]),
                            Candidate(key: key, name: first.productName, index: top)))
        }
        // Total order even when everything else ties (two LocationID-less devices):
        // Dictionary iteration order varies per process and must not pick the winner.
        return entries.sorted { a, b in
            if a.rank != b.rank { return a.rank > b.rank }
            if a.candidate.key.locationID != b.candidate.key.locationID {
                return a.candidate.key.locationID < b.candidate.key.locationID
            }
            if a.score != b.score { return a.score > b.score }
            return a.candidate.key.pid < b.candidate.key.pid
        }.map(\.candidate)
    }

    /// Razer product lines that are not mice but may expose a pointer interface: keyboards,
    /// keypads, laptops, and accessories. Lower case, matched as substrings of the product
    /// string. Only families whose names no mouse shares: "Chroma", for one, is in mouse names
    /// too (the DeathAdder Chroma). Not "mouse dock" either: a mouse charging on the Mouse Dock
    /// Pro, which doubles as its dongle, might show up under the dock's name.
    static let nonMouseProductLines = [
        "keyboard", "keypad", "blackwidow", "huntsman", "ornata", "cynosa", "deathstalker",
        "anansi", "lycosa", "tartarus", "orbweaver", "nostromo", "pro type", "blade",
        "kraken", "seiren", "firefly", "goliathus", "base station",
    ]

    /// Which of `registryIDs` a report names as the control interface: the one open, found by
    /// its registry ID, else `selected`, selection's pick, when nothing is open or it's gone.
    static func reportedControlIndex(registryIDs: [UInt64], opened: UInt64?, selected: () -> Int?) -> Int? {
        if let opened, let index = registryIDs.firstIndex(of: opened) { return index }
        return selected()
    }

    /// False for a product string naming one of `nonMouseProductLines`.
    static func couldBeMouse(productName: String) -> Bool {
        let name = productName.lowercased()
        return !nonMouseProductLines.contains { name.contains($0) }
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
