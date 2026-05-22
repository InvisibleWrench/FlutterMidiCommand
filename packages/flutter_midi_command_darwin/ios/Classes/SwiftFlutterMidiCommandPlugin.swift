
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

import CoreMIDI
import os.log
import Foundation

private let midiDebugLoggingEnabled = false

func midiDebugLog(_ message: @autoclosure () -> String) {
    if midiDebugLoggingEnabled {
        print(message())
    }
}

///
/// Credit to
/// http://mattg411.com/coremidi-swift-programming/
/// https://github.com/genedelisa/Swift3MIDI
/// http://www.gneuron.com/?p=96
/// https://learn.sparkfun.com/tutorials/midi-ble-tutorial/all

func isVirtualEndpoint(endpoint: MIDIEndpointRef) -> Bool {
    var entity : MIDIEntityRef = 0
    MIDIEndpointGetEntity(endpoint, &entity)
    let result = entity == 0;
    return result;
}

func displayName(endpoint: MIDIEndpointRef) -> String {
    return SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyDisplayName, fromObject: endpoint);
}

func appName() -> String {
    return Bundle.main.infoDictionary?[kCFBundleNameKey as String] as! String;
}

func stringToId(str: String) -> UInt32 {
    return UInt32(str.hash & 0xFFFF)
}

func midiDeviceTypeFromLegacy(_ value: String?) -> MidiDeviceType {
    switch value?.lowercased() {
    case "native", "serial":
        return .serial
    case "virtual":
        return .virtualDevice
    case "own-virtual", "ownvirtual":
        return .ownVirtual
    case "network":
        return .network
    case "ble", "bluetooth", "bonded":
        return .ble
    default:
        return .unknown
    }
}

public class SwiftFlutterMidiCommandPlugin: NSObject, FlutterPlugin, MidiHostApi {
    
    // MIDI
    var midiClient = MIDIClientRef()
    var connectedDevices = Dictionary<String, ConnectedDevice>()
    var knownDeviceSnapshots = Dictionary<String, String>()
    
    // Internal callback buses used by platform MIDI classes.
    var rxStreamHandler = StreamHandler()
    var setupStreamHandler = StreamHandler()

    var pigeonFlutterApi: MidiFlutterApiProtocol?
    
    
#if os(iOS)
    // Network Session
    var session:MIDINetworkSession?
#endif
    
    let midiLog = OSLog(subsystem: "com.invisiblewrench.FlutterMidiCommand", category: "MIDI")
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SwiftFlutterMidiCommandPlugin()
        instance.setup(registrar)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        MIDIClientDispose(midiClient)
    }
    
    func setup(_ registrar: FlutterPluginRegistrar) {
        #if os(macOS)
        let messenger = registrar.messenger
        #else
        let messenger = registrar.messenger()
        #endif

        pigeonFlutterApi = MidiFlutterApi(binaryMessenger: messenger)
        MidiHostApiSetup.setUp(binaryMessenger: messenger, api: self)

        rxStreamHandler.onSend = { [weak self] payload in
            self?.forwardMidiPayloadToPigeon(payload: payload)
        }

        setupStreamHandler.onSend = { [weak self] payload in
            self?.forwardSetupPayloadToPigeon(payload: payload)
        }

        
        // MIDI client with notification handler
        MIDIClientCreateWithBlock("plugins.invisiblewrench.com.FlutterMidiCommand" as CFString, &midiClient) { (notification) in
            self.handleMIDINotification(notification)
        }
        knownDeviceSnapshots = currentDeviceSnapshots()
        
#if os(iOS)
        session = MIDINetworkSession.default()
        session?.connectionPolicy = MIDINetworkConnectionPolicy.anyone
#endif
    }
    
    func updateSetupState(data: MidiSetupChange) {
        DispatchQueue.main.async {
            self.setupStreamHandler.send(data:data)
        }
    }
    
    private func legacyDeviceType(from type: MidiDeviceType) -> String {
        switch type {
        case .serial:
            return "serial"
        case .ble:
            return "BLE"
        case .virtualDevice:
            return "virtual"
        case .ownVirtual:
            return "own-virtual"
        case .network:
            return "network"
        case .unknown:
            return "unknown"
        }
    }

    private func forwardSetupPayloadToPigeon(payload: Any) {
        guard let setupChange = payload as? MidiSetupChange else {
            return
        }
        pigeonFlutterApi?.onSetupChanged(setupChange: setupChange) { _ in }
    }

    private func forwardMidiPayloadToPigeon(payload: Any) {
        if let packet = payload as? MidiPacket {
            pigeonFlutterApi?.onDataReceived(packet: packet) { _ in }
        }
    }

    func listDevices() throws -> [MidiHostDevice] {
        return getDevices()
    }

    func connect(device: MidiHostDevice, ports: [MidiPort]?) throws {
        guard let id = device.id else {
            throw PigeonError(code: "MESSAGEERROR", message: "No device Id", details: nil)
        }
        let type = device.type ?? .unknown
        let mappedPorts = ports?.compactMap { port -> Port? in
            guard let id = port.id else {
                return nil
            }
            let type = (port.isInput ?? false) ? "MidiPortType.IN" : "MidiPortType.OUT"
            return Port(id: Int(id), type: type)
        }
        let legacyType = type == .unknown ? "serial" : legacyDeviceType(from: type)
        connectToDevice(deviceId: id, type: legacyType, ports: mappedPorts)
    }

    func disconnect(deviceId: String) throws {
        disconnectDevice(deviceId: deviceId)
    }

    func sendData(packet: MidiPacket) throws {
        guard let data = packet.data else {
            return
        }
        let timestamp = packet.timestamp.map { UInt64(bitPattern: $0) }
        sendData(data, deviceId: packet.device?.id, timestamp: timestamp)
    }

    func addVirtualDevice(name: String?) throws {
        let deviceName = name ?? appName()
        let ownVirtualDevice = findOrCreateOwnVirtualDevice(name: deviceName)
        if ownVirtualDevice.errors.count > 0 {
            let error = ownVirtualDevice.errors.joined(separator: "\n")
            removeOwnVirtualDevice(name: deviceName)
            throw PigeonError(code: "AUDIOERROR", message: error, details: nil)
        }
    }

    func removeVirtualDevice(name: String?) throws {
        let deviceName = name ?? appName()
        removeOwnVirtualDevice(name: deviceName)
    }

    func isNetworkSessionEnabled() throws -> Bool? {
#if os(iOS)
        return session?.isEnabled ?? false
#else
        return nil
#endif
    }

    func setNetworkSessionEnabled(enabled: Bool) throws {
#if os(iOS)
        session?.isEnabled = enabled
#endif
    }
    
    
    // Create an own virtual device appearing in other apps.
    // Other apps can use that device to send and receive MIDI to and from this app.
    var ownVirtualDevices = Set<ConnectedOwnVirtualDevice>()
    
    func findOrCreateOwnVirtualDevice(name: String) -> ConnectedOwnVirtualDevice{
        let existingDevice = ownVirtualDevices.first(where: { device in
            device.name == name
        })
        
        let result = existingDevice ?? ConnectedOwnVirtualDevice(name: name, streamHandler: rxStreamHandler, client: midiClient);
        if(existingDevice == nil){
            ownVirtualDevices.insert(result)
        }
        
        return result
    }
    
    func removeOwnVirtualDevice(name: String){
        let existingDevice = ownVirtualDevices.first(where: { device in
            device.name == name
        })
        
        if let existingDevice = existingDevice {
            existingDevice.close()
            ownVirtualDevices.remove(existingDevice)
        }
    }
    
    // Check if an endpoint is an own virtual destination or source
    func isOwnVirtualEndpoint(endpoint: MIDIEndpointRef) -> Bool{
        return ownVirtualDevices.contains { device in
            device.virtualSourceEndpoint == endpoint || device.virtualDestinationEndpoint == endpoint
        }
    }
    
    
    func teardown() {
        for device in connectedDevices {
            disconnectDevice(deviceId: device.value.id)
        }
    }
    
    
    func connectToDevice(deviceId:String, type:String, ports:[Port]?) {
        midiDebugLog("connect \(deviceId) \(type)")
        
        if type == "own-virtual" {
            let device = ownVirtualDevices.first { device in
                String(device.id) == deviceId
            }
            
            if let device = device {
                connectedDevices[device.id] = device
                (device as ConnectedOwnVirtualDevice).isConnected = true
                updateSetupState(data: .deviceConnected)
                pigeonFlutterApi?.onDeviceConnectionStateChanged(deviceId: deviceId, connected: true) { _ in }
            }
        } else // if type == "native" || if type == "virtual"
        {
            let device = (type == "native" || type == "network" || type == "serial" || type.lowercased() == "ble" || type.lowercased() == "bluetooth") ? ConnectedNativeDevice(id: deviceId, type: type, streamHandler: rxStreamHandler, client: midiClient, ports:ports)
            : ConnectedVirtualDevice(id: deviceId, type: type, streamHandler: rxStreamHandler, client: midiClient, ports:ports)
            midiDebugLog("connected to \(device) \(deviceId)")
            connectedDevices[deviceId] = device
            updateSetupState(data: .deviceConnected)
            pigeonFlutterApi?.onDeviceConnectionStateChanged(deviceId: deviceId, connected: true) { _ in }
        }
    }
    
    func disconnectDevice(deviceId:String) {
        let device = connectedDevices[deviceId]
        midiDebugLog("disconnect \(String(describing: device)) for id \(deviceId)")
        if let device = device {
            if device.deviceType == "own-virtual" {
                (device as! ConnectedOwnVirtualDevice).isConnected = false
                updateSetupState(data: .deviceDisconnected)
                pigeonFlutterApi?.onDeviceConnectionStateChanged(deviceId: deviceId, connected: false) { _ in }
            }
            else {
                device.close()
                updateSetupState(data: .deviceDisconnected)
                pigeonFlutterApi?.onDeviceConnectionStateChanged(deviceId: deviceId, connected: false) { _ in }
            }
            connectedDevices.removeValue(forKey: deviceId)
        }
    }
    
    
    func sendData(_ data:FlutterStandardTypedData, deviceId: String?, timestamp: UInt64?) {
        let bytes = [UInt8](data.data)
        
        if let deviceId = deviceId {
            if let device = connectedDevices[deviceId] {
                device.send(bytes: bytes, timestamp: timestamp)
            }
        } else {
            connectedDevices.values.forEach({ (device) in
                device.send(bytes: bytes, timestamp: timestamp)
            })
        }
    }
    
    
    static func getMIDIProperty(_ prop:CFString, fromObject obj:MIDIObjectRef) -> String {
        var param: Unmanaged<CFString>?
        var result: String = "Error"
        let err: OSStatus = MIDIObjectGetStringProperty(obj, prop, &param)
        if err == OSStatus(noErr) { result = param!.takeRetainedValue() as String }
        return result
    }
    
    static func isNetwork(device:MIDIObjectRef) -> Bool {
        var isNetwork:Bool = false
        
        var list: Unmanaged<CFPropertyList>?
        MIDIObjectGetProperties(device, &list, true)
        if let list = list {
            let dict = list.takeRetainedValue() as! NSDictionary
            if dict["apple.midirtp.session"] != nil {
                isNetwork = true
            }
        }
        return isNetwork
    }

    static func isBluetooth(device: MIDIObjectRef) -> Bool {
        var owner: Unmanaged<CFString>?
        let ownerStatus = MIDIObjectGetStringProperty(device, kMIDIPropertyDriverOwner, &owner)
        if ownerStatus == noErr,
           let ownerName = owner?.takeRetainedValue() as String?,
           containsBluetoothMarker(in: ownerName) {
            return true
        }

        var list: Unmanaged<CFPropertyList>?
        MIDIObjectGetProperties(device, &list, true)
        if let list = list,
           let dict = list.takeRetainedValue() as? NSDictionary {
            return containsBluetoothMarker(in: dict)
        }

        return false
    }

    static func isOffline(object: MIDIObjectRef) -> Bool {
        var offline: Int32 = 0
        MIDIObjectGetIntegerProperty(object, kMIDIPropertyOffline, &offline)
        return offline != 0
    }

    private static func containsBluetoothMarker(in value: Any?) -> Bool {
        guard let value else {
            return false
        }

        if let stringValue = value as? String {
            let normalized = stringValue.lowercased()
            return normalized.contains("bluetooth") || normalized.contains("btle")
        }

        if let dictionary = value as? NSDictionary {
            for entry in dictionary {
                if containsBluetoothMarker(in: entry.key) || containsBluetoothMarker(in: entry.value) {
                    return true
                }
            }
            return false
        }

        if let array = value as? [Any] {
            for item in array {
                if containsBluetoothMarker(in: item) {
                    return true
                }
            }
            return false
        }

        return false
    }
    
    
    func createPorts(count:Int, isInput: Bool) -> [MidiPort?] {
        return (0..<count).map { id in
            MidiPort(id: Int64(id), connected: false, isInput: isInput)
        }
    }
    
    
    func getDevices() -> [MidiHostDevice] {
        var devices:[MidiHostDevice] = []
        
        // ######
        // Native
        // ######
        
        let deviceCount = MIDIGetNumberOfDevices()
        for d in 0..<deviceCount {
            let device = MIDIGetDevice(d)

            if SwiftFlutterMidiCommandPlugin.isOffline(object: device) {
                continue
            }

            let entityCount = MIDIDeviceGetNumberOfEntities(device)

            for entityIndex in 0..<entityCount {
                let entity = MIDIDeviceGetEntity(device, entityIndex)
                let sourceCount = MIDIEntityGetNumberOfSources(entity)
                let destinationCount = MIDIEntityGetNumberOfDestinations(entity)
                let logicalPortCount = max(sourceCount, destinationCount)

                if logicalPortCount == 0 {
                    continue
                }

                let isNetwork = SwiftFlutterMidiCommandPlugin.isNetwork(device: entity)
                let isBluetooth = SwiftFlutterMidiCommandPlugin.isBluetooth(device: entity)
                let entityName = SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyName, fromObject: entity)
                let deviceName = SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyName, fromObject: device)
                let baseName = entityName == "Error" || entityName.isEmpty ? deviceName : entityName
                let baseId = "\(device):\(entityIndex)"

                for portIndex in 0..<logicalPortCount {
                    let deviceId = logicalPortCount == 1 ? baseId : "\(baseId):\(portIndex)"
                    let displayName = logicalPortCount == 1 ? baseName : "\(baseName) [\(portIndex + 1)]"

                    devices.append(
                        MidiHostDevice(
                            id: deviceId,
                            name: displayName,
                            type: isNetwork ? .network : (isBluetooth ? .ble : .serial),
                            connected: connectedDevices.keys.contains(deviceId),
                            inputs: portIndex < sourceCount ? [MidiPort(id: Int64(portIndex), connected: false, isInput: true) as MidiPort?] : nil,
                            outputs: portIndex < destinationCount ? [MidiPort(id: Int64(portIndex), connected: false, isInput: false) as MidiPort?] : nil
                        )
                    )
                }
            }
        }

        let destinationCount = MIDIGetNumberOfDestinations()
        let sourceCount = MIDIGetNumberOfSources()
        
        // #######
        // VIRTUAL
        // #######
        
        var virtualDevices:[MidiHostDevice] = []
        var destinationIndicesByName = Dictionary<String, [Int]>()
        
        for d in 0..<destinationCount {
            let destination = MIDIGetDestination(d)
            
            if(!isVirtualEndpoint(endpoint: destination)){
                continue
            }
            
            if(isOwnVirtualEndpoint(endpoint: destination)){
                continue
            }
            
            let displayName = SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyDisplayName, fromObject: destination)
            let deviceId = "\(destination)"
            
            let hostDevice = MidiHostDevice(
                id: deviceId,
                name: displayName,
                type: .virtualDevice,
                connected: connectedDevices.keys.contains(deviceId),
                inputs: nil,
                outputs: createPorts(count: 1, isInput: false)
            )
            let nextIndex = virtualDevices.count
            virtualDevices.append(hostDevice)
            destinationIndicesByName[displayName, default: []].append(nextIndex)
        }
        
        
        for s in 0..<sourceCount {
            let source = MIDIGetSource(s)
            
            if(!isVirtualEndpoint(endpoint: source)){
                continue
            }
            
            if(isOwnVirtualEndpoint(endpoint: source)){
                continue
            }
            
            let displayName = SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyDisplayName, fromObject: source)
            
            if var matchedDestinationIndices = destinationIndicesByName[displayName], !matchedDestinationIndices.isEmpty {
                let index = matchedDestinationIndices.removeFirst()
                destinationIndicesByName[displayName] = matchedDestinationIndices
                
                var hostDevice = virtualDevices[index]
                hostDevice.inputs = createPorts(count: 1, isInput: true)
                let destination = hostDevice.id ?? ""
                let id2 = "\(destination):\(source)"
                hostDevice.id = id2
                hostDevice.connected = connectedDevices.keys.contains(id2)
                virtualDevices[index] = hostDevice
            } else {
                let id2 = ":\(source)"
                virtualDevices.append(
                    MidiHostDevice(
                    id: id2,
                    name: displayName,
                    type: .virtualDevice,
                    connected: connectedDevices.keys.contains(id2),
                    inputs: createPorts(count: 1, isInput: true),
                    outputs: nil
                )
                )
            }
        }
        
        devices.append(contentsOf: virtualDevices)
        
        
        
        // ###########
        // OWN VIRTUAL
        // ###########
        
        for ownVirtualDevice in self.ownVirtualDevices {
            let displayName = ownVirtualDevice.deviceName
            let deviceId = String(ownVirtualDevice.id)
            devices.append(
                MidiHostDevice(
                id: deviceId,
                name: displayName,
                type: .ownVirtual,
                connected: connectedDevices.keys.contains(deviceId),
                inputs: createPorts(count: 1, isInput: true),
                outputs: createPorts(count: 1, isInput: false)
            )
            )
        }

        return devices
    }

    func currentDeviceSnapshots() -> Dictionary<String, String> {
        var snapshots = Dictionary<String, String>()
        for device in getDevices() {
            guard let id = device.id else {
                continue
            }
            let inputIds = (device.inputs ?? []).compactMap { $0?.id }.map { String($0) }.joined(separator: ",")
            let outputIds = (device.outputs ?? []).compactMap { $0?.id }.map { String($0) }.joined(separator: ",")
            snapshots[id] = "\(device.name ?? "")|\(device.type?.rawValue ?? 0)|in:\(inputIds)|out:\(outputIds)"
        }
        return snapshots
    }

    func refreshMidiSetupSnapshot() {
        let previousSnapshots = knownDeviceSnapshots
        let nextSnapshots = currentDeviceSnapshots()
        let previousIds = Set(previousSnapshots.keys)
        let nextIds = Set(nextSnapshots.keys)
        let disappearedIds = previousIds.subtracting(nextIds)
        let appearedIds = nextIds.subtracting(previousIds)
        let retainedIds = previousIds.intersection(nextIds)
        var stateChanged = false

        knownDeviceSnapshots = nextSnapshots

        for id in disappearedIds {
            if let connectedDevice = connectedDevices[id] {
                connectedDevice.close()
                connectedDevices.removeValue(forKey: id)
                pigeonFlutterApi?.onDeviceConnectionStateChanged(deviceId: id, connected: false) { _ in }
            }
            updateSetupState(data: .deviceDisappeared)
        }

        for _ in appearedIds {
            updateSetupState(data: .deviceAppeared)
        }

        for id in retainedIds {
            if previousSnapshots[id] != nextSnapshots[id] {
                stateChanged = true
                break
            }
        }

        if stateChanged && appearedIds.isEmpty && disappearedIds.isEmpty {
            updateSetupState(data: .deviceStateChanged)
        }
    }
    
    
    func handleMIDINotification(_ midiNotification: UnsafePointer<MIDINotification>) {
        let notification = midiNotification.pointee

        switch notification.messageID {
        case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
            refreshMidiSetupSnapshot()
        default:
            break
        }
        
        if !midiDebugLoggingEnabled {
            return
        }
        
        midiDebugLog("\ngot a MIDINotification!")
        midiDebugLog("MIDI Notify, messageId= \(notification.messageID) \(notification.messageSize)")
        
        switch notification.messageID {
            
            // Some aspect of the current MIDISetup has changed.  No data.  Should ignore this  message if messages 2-6 are handled.
        case .msgSetupChanged:
            midiDebugLog("MIDI setup changed")
            let ptr = UnsafeMutablePointer<MIDINotification>(mutating: midiNotification)
            //            let ptr = UnsafeMutablePointer<MIDINotification>(midiNotification)
            let m = ptr.pointee
            midiDebugLog("\(m)")
            midiDebugLog("id \(m.messageID)")
            midiDebugLog("size \(m.messageSize)")
            break
            
            
            // A device, entity or endpoint was added. Structure is MIDIObjectAddRemoveNotification.
        case .msgObjectAdded:
            
            midiDebugLog("added")
            //            let ptr = UnsafeMutablePointer<MIDIObjectAddRemoveNotification>(midiNotification)
            
            midiNotification.withMemoryRebound(to: MIDIObjectAddRemoveNotification.self, capacity: 1) {
                let m = $0.pointee
                midiDebugLog("\(m)")
                midiDebugLog("id \(m.messageID)")
                midiDebugLog("size \(m.messageSize)")
                midiDebugLog("child \(m.child)")
                midiDebugLog("child type \(m.childType)")
                showMIDIObjectType(m.childType)
                midiDebugLog("parent \(m.parent)")
                midiDebugLog("parentType \(m.parentType)")
                showMIDIObjectType(m.parentType)
                //                midiDebugLog("childName \(String(describing: getDisplayName(m.child)))")
            }
            
            
            break
            
            // A device, entity or endpoint was removed. Structure is MIDIObjectAddRemoveNotification.
        case .msgObjectRemoved:
            midiDebugLog("kMIDIMsgObjectRemoved")
            //            let ptr = UnsafeMutablePointer<MIDIObjectAddRemoveNotification>(midiNotification)
            midiNotification.withMemoryRebound(to: MIDIObjectAddRemoveNotification.self, capacity: 1) {
                
                let m = $0.pointee
                midiDebugLog("\(m)")
                midiDebugLog("id \(m.messageID)")
                midiDebugLog("size \(m.messageSize)")
                midiDebugLog("child \(m.child)")
                midiDebugLog("child type \(m.childType)")
                midiDebugLog("parent \(m.parent)")
                midiDebugLog("parentType \(m.parentType)")
                
                //                midiDebugLog("childName \(String(describing: getDisplayName(m.child)))")
            }
            break
            
            // An object's property was changed. Structure is MIDIObjectPropertyChangeNotification.
        case .msgPropertyChanged:
            midiDebugLog("kMIDIMsgPropertyChanged")
            midiNotification.withMemoryRebound(to: MIDIObjectPropertyChangeNotification.self, capacity: 1) {
                
                let m = $0.pointee
                midiDebugLog("\(m)")
                midiDebugLog("id \(m.messageID)")
                midiDebugLog("size \(m.messageSize)")
                midiDebugLog("object \(m.object)")
                midiDebugLog("objectType  \(m.objectType)")
                midiDebugLog("propertyName  \(m.propertyName)")
                midiDebugLog("propertyName  \(m.propertyName.takeUnretainedValue())")
                
                if m.propertyName.takeUnretainedValue() as String == "apple.midirtp.session" {
                    midiDebugLog("connected")
                }
            }
            
            break
            
            //     A persistent MIDI Thru connection wasor destroyed.  No data.
        case .msgThruConnectionsChanged:
            midiDebugLog("MIDI thru connections changed.")
            break
            
            //A persistent MIDI Thru connection was created or destroyed.  No data.
        case .msgSerialPortOwnerChanged:
            midiDebugLog("MIDI serial port owner changed.")
            break
            
        case .msgIOError:
            midiDebugLog("MIDI I/O error.")
            
            //let ptr = UnsafeMutablePointer<MIDIIOErrorNotification>(midiNotification)
            midiNotification.withMemoryRebound(to: MIDIIOErrorNotification.self, capacity: 1) {
                let m = $0.pointee
                midiDebugLog("\(m)")
                midiDebugLog("id \(m.messageID)")
                midiDebugLog("size \(m.messageSize)")
                midiDebugLog("driverDevice \(m.driverDevice)")
                midiDebugLog("errorCode \(m.errorCode)")
            }
            break
        @unknown default:
            break
        }
    }
    
    func showMIDIObjectType(_ ot: MIDIObjectType) {
        switch ot {
        case .other:
            os_log("midiObjectType: Other", log: midiLog, type: .debug)
            break
            
        case .device:
            os_log("midiObjectType: Device", log: midiLog, type: .debug)
            break
            
        case .entity:
            os_log("midiObjectType: Entity", log: midiLog, type: .debug)
            break
            
        case .source:
            os_log("midiObjectType: Source", log: midiLog, type: .debug)
            break
            
        case .destination:
            os_log("midiObjectType: Destination", log: midiLog, type: .debug)
            break
            
        case .externalDevice:
            os_log("midiObjectType: ExternalDevice", log: midiLog, type: .debug)
            break
            
        case .externalEntity:
            midiDebugLog("midiObjectType: ExternalEntity")
            os_log("midiObjectType: ExternalEntity", log: midiLog, type: .debug)
            break
            
        case .externalSource:
            os_log("midiObjectType: ExternalSource", log: midiLog, type: .debug)
            break
            
        case .externalDestination:
            os_log("midiObjectType: ExternalDestination", log: midiLog, type: .debug)
            break
        @unknown default:
            break
        }
        
    }
    
#if os(iOS)
    /// MIDI Network Session
    @objc func midiNetworkChanged(notification:NSNotification) {
        midiDebugLog("\(#function)")
        midiDebugLog("\(notification)")
        if let session = notification.object as? MIDINetworkSession {
            midiDebugLog("session \(session)")
            for con in session.connections() {
                midiDebugLog("con \(con)")
            }
            midiDebugLog("isEnabled \(session.isEnabled)")
            midiDebugLog("sourceEndpoint \(session.sourceEndpoint())")
            midiDebugLog("destinationEndpoint \(session.destinationEndpoint())")
            midiDebugLog("networkName \(session.networkName)")
            midiDebugLog("localName \(session.localName)")
            
            //            if let name = getDeviceName(session.sourceEndpoint()) {
            //                midiDebugLog("source name \(name)")
            //            }
            //
            //            if let name = getDeviceName(session.destinationEndpoint()) {
            //                midiDebugLog("destination name \(name)")
            //            }
        }
        updateSetupState(data: .deviceStateChanged)
    }
    
    @objc func midiNetworkContactsChanged(notification:NSNotification) {
        midiDebugLog("\(#function)")
        midiDebugLog("\(notification)")
        if let session = notification.object as? MIDINetworkSession {
            midiDebugLog("session \(session)")
            for con in session.contacts() {
                midiDebugLog("contact \(con)")
            }
        }
        updateSetupState(data: .deviceStateChanged)
    }
#endif
}

class StreamHandler : NSObject {
    var onSend: ((Any) -> Void)?
    
    func send(data: Any) {
        onSend?(data)
    }
}

class Port {
    var id:Int
    var type:String
    
    init(id:Int, type:String) {
        self.id = id;
        self.type = type
    }
}

class ConnectedDevice : NSObject {
    var id:String
    var deviceType:String
    var streamHandler : StreamHandler
    
    init(id:String, type:String, streamHandler:StreamHandler) {
        self.id = id
        self.deviceType = type
        self.streamHandler = streamHandler
    }
    
    func openPorts() {}
    
    func send(bytes:[UInt8], timestamp: UInt64?) {}
    
    func close() {}
}

class ConnectedVirtualOrNativeDevice : ConnectedDevice {
    var ports:[Port]?
    var outputPort = MIDIPortRef()
    var inputPort = MIDIPortRef()
    var client : MIDIClientRef
    var name : String?
    var outEndpoint : MIDIEndpointRef?
    var inSource : MIDIEndpointRef?
    var deviceInfo: MidiHostDevice
    
    init(id:String, type:String, streamHandler:StreamHandler, client: MIDIClientRef, ports:[Port]?) {
        self.client = client
        self.ports = ports
        
        
        deviceInfo = MidiHostDevice(
            id: id,
            name: name,
            type: midiDeviceTypeFromLegacy(type),
            connected: true,
            inputs: nil,
            outputs: nil
        )
        
        super.init(id: id, type: type, streamHandler: streamHandler)
    }
    
    override func send(bytes: [UInt8], timestamp: UInt64?) {
        midiDebugLog("send \(bytes.count) bytes to \(String(describing: name))")
        
        if let ep = outEndpoint {
            splitDataIntoMIDIPackets(bytes: bytes, timestamp: timestamp) { packetListPointer in
                MIDISend(outputPort, ep, packetListPointer)
            }
        } else {
            midiDebugLog("No MIDI destination for id \(name ?? "<unknown>")")
        }
    }
    
    func splitDataIntoMIDIPackets(bytes:[UInt8], timestamp: UInt64?, packetCallback:(UnsafePointer<MIDIPacketList>) -> Void) {
        let maxPacketSize = 256 // Maximum size for a single packet's data field
        var offset = 0
        let ts = timestamp ?? mach_absolute_time()
        
        while offset < bytes.count {
            var packetList = MIDIPacketList()
            
            // Calculate the size of the current chunk
            let chunkSize = min(maxPacketSize, bytes.count - offset)
            let chunk = Array(bytes[offset..<offset + chunkSize])
            
            // Create the packet
            chunk.withUnsafeBufferPointer { buffer in
                packetList = buffer.withMemoryRebound(to: UInt8.self) { dataBuffer in
                    var tempPacketList = MIDIPacketList(numPackets: 1, packet: MIDIPacket())
                    
                    var packet = MIDIPacket()
                    packet.timeStamp = ts
                    packet.length = UInt16(dataBuffer.count)
                    withUnsafeMutablePointer(to: &packet.data) {
                        $0.withMemoryRebound(to: UInt8.self, capacity: dataBuffer.count) { dataPtr in
                            for i in 0..<dataBuffer.count {
                                dataPtr[i] = dataBuffer[i]
                            }
                        }
                    }
                    
                    tempPacketList.packet = packet
                    return tempPacketList
                }
            }
            
            // Send the packet
            withUnsafePointer(to: &packetList) { packetListPointer in
                packetCallback(packetListPointer)
            }
            
            // Move to the next chunk
            offset += chunkSize
        }
    }
    
    override func close() {
        // We did not create the endpoint so we should not dispose it.
        // if let oEP = outEndpoint {
        //   MIDIEndpointDispose(oEP)
        // }
        
        if let iS = inSource {
            MIDIPortDisconnectSource(inputPort, iS)
        }
        
        MIDIPortDispose(inputPort)
        MIDIPortDispose(outputPort)
    }
    
    var buffer = UnsafeMutablePointer<MIDIPacket>.allocate(capacity: 2) // Don't know why I need to a capacity of 2 here. If I setup 1 I'm getting a crash.
    private lazy var midiPacketParser = MidiPacketParser { [weak self] bytes, timestamp in
        guard let self else {
            return
        }
        DispatchQueue.main.async {
            self.streamHandler.send(
                data: MidiPacket(
                    device: self.deviceInfo,
                    data: FlutterStandardTypedData(bytes: Data(bytes)),
                    timestamp: Int64(bitPattern: timestamp)
                )
            )
        }
    }
    
    func handlePacketList(_ packetList:UnsafePointer<MIDIPacketList>, srcConnRefCon:UnsafeMutableRawPointer?) {
        let packets = packetList.pointee
        let packet:MIDIPacket = packets.packet
        var ap = buffer;
        buffer.initialize(to:packet)
        
        for _ in 0 ..< packets.numPackets {
            let p = ap.pointee
            var tmp = p.data
            let data = Data(bytes: &tmp, count: Int(p.length))
            let timestamp = p.timeStamp
            parseData(data: data, timestamp: timestamp)
            ap = MIDIPacketNext(ap)
        }
    }

    func parseData(data: Data, timestamp: UInt64) {
        midiPacketParser.parse(data: data, timestamp: timestamp)
    }
    
}


class ConnectedNativeDevice : ConnectedVirtualOrNativeDevice {
    
    var entity : MIDIEntityRef?
    var selectedPortIndex: Int = 0
    
    override init(id:String, type:String, streamHandler:StreamHandler, client: MIDIClientRef, ports:[Port]?) {
        super.init(id:id, type: type, streamHandler: streamHandler, client: client, ports: ports)
        
        self.ports = ports
        let idParts = id.split(separator: ":")
        
        // Store entity and get device/entity name
        if idParts.count >= 2, let deviceId = MIDIDeviceRef(idParts[0]) {
            if let entityId = Int(idParts[1]) {
                if idParts.count > 2, let portIndex = Int(idParts[2]) {
                    selectedPortIndex = portIndex
                }
                entity = MIDIDeviceGetEntity(deviceId, entityId)
                if let e = entity {
                    let entityName = SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyName, fromObject: e)
                    
                    var device:MIDIDeviceRef = 0
                    MIDIEntityGetDevice(e, &device)
                    let deviceName = SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyName, fromObject: device)
                    
                    name = "\(deviceName) \(entityName)"
                } else {
                    midiDebugLog("no entity")
                }
            } else {
                midiDebugLog("no entityId")
            }
        } else {
            midiDebugLog("no deviceId")
        }
        
        
        deviceInfo = MidiHostDevice(
            id: String(id),
            name: name,
            type: midiDeviceTypeFromLegacy(type),
            connected: true,
            inputs: nil,
            outputs: nil
        )
        
        
        // MIDI Input with handler
        MIDIInputPortCreateWithBlock(client, "FlutterMidiCommand_InPort" as CFString, &inputPort) { (packetList, srcConnRefCon) in
            self.handlePacketList(packetList, srcConnRefCon: srcConnRefCon)
        }
        
        // MIDI output
        MIDIOutputPortCreate(client, "FlutterMidiCommand_OutPort" as CFString, &outputPort);
        
        openPorts()
    }
    
    override func openPorts() {
        midiDebugLog("open native ports")
        
        if let e = entity {
            
            let ref = Unmanaged.passUnretained(self).toOpaque()
            
            if let ps = ports {
                for port in ps {
                    switch port.type {
                    case "MidiPortType.IN":
                        inSource = MIDIEntityGetSource(e, port.id)
                        let status = MIDIPortConnectSource(inputPort, inSource!, ref)
                        midiDebugLog("port open status \(status)")
                    case "MidiPortType.OUT":
                        outEndpoint = MIDIEntityGetDestination(e, port.id)
                        //                    midiDebugLog("port endpoint \(endpoint)")
                        break
                    default:
                        midiDebugLog("unknown port type \(port.type)")
                    }
                }
            } else {
                midiDebugLog("open default ports")
                if selectedPortIndex < MIDIEntityGetNumberOfSources(e) {
                    inSource = MIDIEntityGetSource(e, selectedPortIndex)
                    let status = MIDIPortConnectSource(inputPort, inSource!, ref)
                    if(status != noErr){
                        midiDebugLog("Error \(status) while calling MIDIPortConnectSource");
                    }
                }
                if selectedPortIndex < MIDIEntityGetNumberOfDestinations(e) {
                    outEndpoint = MIDIEntityGetDestination(e, selectedPortIndex)
                }
            }
        }
    }
    
    override func close() {
        /*
         if let oEP = outEndpoint {
         MIDIEndpointDispose(oEP)
         }
         */
        if let iS = inSource {
            MIDIPortDisconnectSource(inputPort, iS)
        }
        
        MIDIPortDispose(inputPort)
        MIDIPortDispose(outputPort)
    }
    
    override func handlePacketList(_ packetList:UnsafePointer<MIDIPacketList>, srcConnRefCon:UnsafeMutableRawPointer?) {
        //        let deviceInfo = ["name" : name,
        //                          "id": String(id),
        //                          "type":"native"]
        
        var timestampFactor : Double = 1.0
        var tb = mach_timebase_info_data_t()
        let kError = mach_timebase_info(&tb)
        if (kError == 0) {
            timestampFactor = Double(tb.numer) / Double(tb.denom)
        }
        
        // New implementation: Handles packages with a size larger then 256 bytes
        if #available(macOS 10.15, iOS 13.0, *) {
            let packetListSize = MIDIPacketList.sizeInBytes(pktList: packetList)
            
            // Copy raw data from packetList
            let packetListAsRawData = Data(bytes: packetList, count: packetListSize)
            var packetNumber = 0
            
            for packet in packetList.unsafeSequence() {
                let offsetStart = getOffsetForPackageData(packetList: packetList, packageNumber: (Int)(packetNumber))
                let offsetEnd = (offsetStart + (Int)(packet.pointee.length) - 1)
                let packetData = packetListAsRawData.subdata(in: Range(offsetStart...offsetEnd))

                let timestamp = UInt64(round(Double(packet.pointee.timeStamp) * timestampFactor))
                
                parseData(data: packetData, timestamp: timestamp)
                
                packetNumber += 1
            }
        } else {
            // Original implementation: This implementation will not work with packages larger than 256 bytes
            // The issue is due to the line (see below): let packet:MIDIPacket = packets.packet
            // which will only copy the first 256 bytes from the received data
            let packets = packetList.pointee
            let packet:MIDIPacket = packets.packet // This will only copy the first 256 bytes!
            var ap = buffer
            ap.initialize(to:packet)
            
            //        midiDebugLog("tb \(tb) timestamp \(timestampFactor)")
            for _ in 0 ..< packets.numPackets {
                let p = ap.pointee
                var tmp = p.data
                let data = Data(bytes: &tmp, count: Int(p.length))
                let timestamp = UInt64(round(Double(p.timeStamp) * timestampFactor))
                parseData(data: data, timestamp: timestamp)
                ap = MIDIPacketNext(ap)
            }
            //        ap.deallocate()
        }
    }
    
    func getOffsetForPackageData(packetList: UnsafePointer<MIDIPacketList>, packageNumber: Int) -> Int {
            if #available(macOS 10.15, iOS 13.0, *) {
                var packageCount = 0
                for packet in packetList.unsafeSequence() {
                    if (packageCount == packageNumber) {
                        return (Int)(UInt(bitPattern:Int(Int(bitPattern: packet))) - UInt(bitPattern:Int(Int(bitPattern: packetList)))) + MemoryLayout.offset(of: \MIDIPacket.data)!
                    }
                        
                    packageCount += 1
                }
            }
            return -1
        }
}

class ConnectedVirtualDevice : ConnectedVirtualOrNativeDevice {
    
    override init(id:String, type:String, streamHandler:StreamHandler, client: MIDIClientRef, ports:[Port]?) {
        
        super.init(id:id, type: type, streamHandler: streamHandler, client: client, ports: ports)
        
        let idParts = id.split(separator: ":")
        assert(idParts.count > 0);
        outEndpoint = idParts.count > 0 && idParts[0].count > 0 ? MIDIEndpointRef(idParts[0]) : nil;
        inSource = idParts.count > 1 && idParts[1].count > 0 ? MIDIEndpointRef(idParts[1]) : nil;
        
        name = displayName(endpoint: outEndpoint ?? inSource ?? 0);
        
        // MIDI Input with handler
        MIDIInputPortCreateWithBlock(client, "FlutterMidiCommand_InPort" as CFString, &inputPort) { (packetList, srcConnRefCon) in
            self.handlePacketList(packetList, srcConnRefCon: srcConnRefCon)
        }
        
        // MIDI output
        MIDIOutputPortCreate(client, "FlutterMidiCommand_OutPort" as CFString, &outputPort);
        
        openPorts()
    }
    
    override func openPorts() {
        
        if(inSource != nil){
            let ref = Unmanaged.passUnretained(self).toOpaque()
            MIDIPortConnectSource(inputPort, inSource!, ref);
        }
    }
}

class ConnectedOwnVirtualDevice : ConnectedVirtualOrNativeDevice {
    init(name: String, streamHandler:StreamHandler, client: MIDIClientRef) {
        self.deviceName = name
        self.midiClient = client
        super.init(id: String(stringToId(str: name)), type: "own-virtual", streamHandler: streamHandler, client: client, ports: [])
        initVirtualSource()
        initVirtualDestination()
        self.name = name
    }
    
    override func openPorts() {}
    
    var virtualSourceEndpoint: MIDIClientRef = 0
    var virtualDestinationEndpoint: MIDIClientRef = 0
    let midiClient: MIDIClientRef
    let deviceName: String
    var isConnected = false
    var errors: Array<String> = []
    
    
    override func send(bytes: [UInt8], timestamp: UInt64?) {
        
        if(!isConnected){
            return;
        }
        
        
        splitDataIntoMIDIPackets(bytes: bytes, timestamp: timestamp) { packetListPointer in
            let status = MIDIReceived(virtualSourceEndpoint, packetListPointer)
            if(status != noErr){
                let error = "Error \(status) while publishing MIDI on own virtual source endpoint."
                errors.append(error)
                midiDebugLog(error)
            }
        }
        
//        let packetList = UnsafeMutablePointer<MIDIPacketList>.allocate(capacity: 1)
//        var packet = MIDIPacketListInit(packetList)
//        let time = MIDITimeStamp(timestamp ?? mach_absolute_time())
//        packet = MIDIPacketListAdd(packetList, 1024, packet, time, bytes.count, bytes)
        
//        let status = MIDIReceived(virtualSourceEndpoint, packetList)
//        if(status != noErr){
//            let error = "Error \(status) while publishing MIDI on own virtual source endpoint."
//            errors.append(error)
//            midiDebugLog(error)
//        }
        
//        packetList.deallocate()
    }
    
    override func close() {
        closeVirtualSource()
        closeVirtualDestination()
    }
    
    
    func initVirtualSource(){
        let s = MIDISourceCreate(midiClient, deviceName as CFString, &virtualSourceEndpoint);
        if(s != noErr){
            let error = "Error \(s) while create MIDI virtual source"
            errors.append(error)
            midiDebugLog(error)
            return
        }
        
        // Attempt to use saved unique ID
        let defaults = UserDefaults.standard
        var uniqueID = Int32(defaults.integer(forKey: "FlutterMIDICommand Saved Virtual Source ID \(deviceName)"))
        
        //Set unique ID if available
        if ( uniqueID != 0 )
        {
            let s = MIDIObjectSetIntegerProperty(virtualSourceEndpoint, kMIDIPropertyUniqueID, uniqueID);
            
            if ( s == kMIDIIDNotUnique )
            {
                uniqueID = 0;
            }
        }
        
        // Create and save a new unique id
        if ( uniqueID == 0 ) {
            let s = MIDIObjectGetIntegerProperty(virtualSourceEndpoint, kMIDIPropertyUniqueID, &uniqueID);
            if(s != noErr){
                let error = "Error \(s) while getting MIDI virtual source ID"
                errors.append(error)
                midiDebugLog(error)
            }
            
            if ( s == noErr ) {
                defaults.set(uniqueID, forKey: "FlutterMIDICommand Saved Virtual Source ID \(deviceName)")
            }
        }
    }
    
    func closeVirtualSource(){
        let s = MIDIEndpointDispose(virtualSourceEndpoint);
        if(s != noErr){
            let error = "Error \(s) while disposing MIDI virtual source."
            errors.append(error)
            midiDebugLog(error)
        }
    }
    
    func initVirtualDestination(){
        
        
        let s = MIDIDestinationCreateWithBlock(midiClient, deviceName as CFString, &virtualDestinationEndpoint) { (packetList, srcConnRefCon) in
            if(self.isConnected){
                self.handlePacketList(packetList, srcConnRefCon: srcConnRefCon)
            }
        }
        
        
        if ( s != noErr ) {
            if(s == -10844){
                let error = "Error while creating virtual MIDI destination. You need to add the key 'UIBackgroundModes' with value 'audio' to your Info.plist file"
                errors.append(error)
                midiDebugLog(error)
            }
            return;
        }
        
        // Attempt to use saved unique ID
        let defaults = UserDefaults.standard
        var uniqueID = Int32(defaults.integer(forKey: "FlutterMIDICommand Saved Virtual Destination ID  \(deviceName)"))
        
        if ( uniqueID != 0 )
        {
            let s = MIDIObjectSetIntegerProperty(virtualDestinationEndpoint, kMIDIPropertyUniqueID, uniqueID)
            if ( s == kMIDIIDNotUnique )
            {
                uniqueID = 0;
            }
        }
        // Save the ID
        if ( uniqueID == 0 ) {
            let s = MIDIObjectGetIntegerProperty(virtualDestinationEndpoint, kMIDIPropertyUniqueID, &uniqueID)
            
            if ( s == noErr ) {
                defaults.set(uniqueID, forKey: "FlutterMIDICommand Saved Virtual Destination ID \(deviceName)")
            }
            else {
                let error = "Error: \(s) while setting unique ID for virtuel endpoint"
                errors.append(error)
                midiDebugLog(error)
            }
        }
    }
    
    func closeVirtualDestination(){
        let s = MIDIEndpointDispose(virtualDestinationEndpoint);
        if(s != 0){
            let error = "Error: \(s) while disposing MIDI endpoint"
            errors.append(error)
            midiDebugLog(error)
        }
    }
}
