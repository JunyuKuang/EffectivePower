//
//  EffectivePowerDocument.swift
//  EffectivePower
//
//  Created by Saagar Jha on 5/8/22.
//

import SwiftUI
import UniformTypeIdentifiers
import SQLite

extension UTType {
    static var plsql = Self(importedAs: "com.saagarjha.plsql")
}

struct Node: Hashable, Identifiable {
    let name: String
    
    var id: String {
        name
    }
}

class Event: Identifiable {
    let node: Node?
    let rootNode: Node?
    weak var parent: Event?
    let timestamp: ClosedRange<Date>
    var energy: Int
    
    var children = [Event]()
    
    init(node: Node?, rootNode: Node?, parent: Event?, timestamp: ClosedRange<Date>, energy: Int) {
        self.node = node
        self.rootNode = rootNode
        self.parent = parent
        self.timestamp = timestamp
        self.energy = energy
    }
}

class BatteryStatus: Hashable, Identifiable {
    let timestamp: Date
    let level: Double
    let charging: Bool
    
    init(timestamp: Date, level: Double, charging: Bool) {
        self.timestamp = timestamp
        self.level = level
        self.charging = charging
    }
    
    static func == (lhs: BatteryStatus, rhs: BatteryStatus) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

class EffectivePowerDocument: FileDocument, Equatable {
    static var readableContentTypes: [UTType] { [.plsql] }
    
    let nodes: [Int: Node]
    let events: [Event]
    let batteryStatuses: [BatteryStatus]
    
    let bounds: ClosedRange<Date>
    
    let deviceName: String?
    let deviceModel: String?
    let deviceBuild: String?
    
    init() {
        nodes = [:]
        events = []
        batteryStatuses = []
        deviceName = ""
        deviceModel = ""
        deviceBuild = ""
        bounds = Date()...(Date())
    }
    
    required init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents!
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("Database", isDirectory: false)
        try data.write(to: fileURL, options: .atomic)
        
        let database = try SQLite.Connection(fileURL.path)
        var nodes = [Int: Node]()
        
        for node in try database.prepare(Table("PLAccountingOperator_EventNone_Nodes")) {
            let id = Expression<Int?>("ID")
            let name = Expression<String?>("Name")
            nodes[node[id]!] = Node(name: node[name]!)
        }
        self.nodes = nodes
        
        var offsets = [(Double, Double)]()
        
        for node in try database.prepare(Table("PLStorageOperator_EventForward_TimeOffset")) {
            let timestamp = Expression<Double>("timestamp")
            let offset = Expression<Double>("system")
            offsets.append((node[timestamp], node[offset]))
        }
        offsets.sort {
            $0.0 < $1.0
        }
        
        func offset(for timestamp: Double) -> Double {
            offsets[offsets.index(offsets.firstIndex {
                $0.0 > timestamp
            } ?? offsets.endIndex, offsetBy: -1, limitedBy: offsets.startIndex) ?? offsets.startIndex].1
        }
        
        var events = [Int: Event]()
        
        for node in try database.prepare(Table("PLAccountingOperator_EventInterval_EnergyEstimateEvents")) {
            let row: [Any] = [
                node[Expression<Int>("ID")],
                node[Expression<Int>("NodeID")],
                node[Expression<Int>("RootNodeID")],
                node[Expression<Int>("ParentEntryID")],
                node[Expression<Double>("timestamp")],
                node[Expression<Int>("StartOffset")],
                node[Expression<Int>("EndOffset")],
                node[Expression<Int>("Energy")],
                node[Expression<Int>("CorrectionEnergy")],
            ]
            let timestamp = row[4] as! Double
            let offset = offset(for: timestamp)
            let startOffset = Double(row[5] as! Int)
            let endOffset = Double(row[6] as! Int)
            let _start = Date(timeIntervalSince1970: timestamp + startOffset / 1_000)
            let _end = Date(timeIntervalSince1970: timestamp + endOffset / 1_000)
            // Ignore these, as per Apple's response to FB11722856:
            // These are the “dummy’ power events…created with a startDate of NSDate distantPast
            guard abs(_start.timeIntervalSince(.distantPast)) >= 1,
                  abs(_end.timeIntervalSince(.distantPast)) >= 1 else {
                print("Ignoring dummy events: ", _start, _end)
                continue
            }
            let start = _start.addingTimeInterval(offset)
            let end = _end.addingTimeInterval(offset)
            if start == end {
                continue
            }
            let parent = events[row[3] as! Int]
            let event = Event(node: nodes[row[1] as! Int], rootNode: nodes[row[2] as! Int], parent: parent, timestamp: start...end, energy: (row[7] as! Int) + (row[8] as! Int))
            parent?.children.append(event)
            events[row[0] as! Int] = event
        }
        self.events = Array(events.values)
        
        var roots = self.events.filter {
            $0.parent == nil
        }
        
        while let event = roots.popLast() {
            event.energy -= event.children.map(\.energy).reduce(0, +)
            roots.append(contentsOf: event.children)
        }
        
        var batteryStatus = [BatteryStatus]()
        
        for node in try database.prepare(Table("PLBatteryAgent_EventBackward_Battery")) {
            let row: [Any] = [
                node[Expression<Double>("timestamp")],
                node[Expression<Double>("Level")],
                node[Expression<Int>("ExternalConnected")],
            ]
            let timestamp = row[0] as! Double
            let offset = offset(for: timestamp)
            batteryStatus.append(BatteryStatus(timestamp: Date(timeIntervalSince1970: timestamp + offset), level: row[1] as! Double, charging: (row[2] as! Int) != 0))
        }
        self.batteryStatuses = batteryStatus.sorted {
            $0.timestamp < $1.timestamp
        }
        
        deviceName = "deviceName"
        deviceModel = "deviceModel"
        deviceBuild = "deviceBuild"
        
        bounds = min(batteryStatuses.first!.timestamp, self.events.map(\.timestamp.lowerBound).min()!)...max(batteryStatuses.last!.timestamp, self.events.map(\.timestamp.upperBound).max()!)
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        configuration.existingFile!
    }
    
    static func == (lhs: EffectivePowerDocument, rhs: EffectivePowerDocument) -> Bool {
        return lhs === rhs
    }
}
