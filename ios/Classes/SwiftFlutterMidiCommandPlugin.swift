import Flutter
import UIKit
import CoreMIDI
import os.log
import CoreBluetooth

///
/// Credit to
/// http://mattg411.com/coremidi-swift-programming/
/// https://github.com/genedelisa/Swift3MIDI
/// http://www.gneuron.com/?p=96
/// https://learn.sparkfun.com/tutorials/midi-ble-tutorial/all


public class SwiftFlutterMidiCommandPlugin: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, FlutterPlugin {

    // MIDI
    var midiClient = MIDIClientRef()
    var outputPort = MIDIPortRef()
    var inputPort = MIDIPortRef()
    var connectedDevices = Dictionary<String, ConnectedDevice>()
    var connectingDevice:ConnectedDevice?

    // Flutter
    var midiRXChannel:FlutterEventChannel?
    var rxStreamHandler = StreamHandler()
    var midiSetupChannel:FlutterEventChannel?
    var setupStreamHandler = StreamHandler()

    // BLE
    var manager:CBCentralManager!
//    var connectedPeripheral:CBPeripheral?
//    var connectedCharacteristic:CBCharacteristic?
    var discoveredDevices:Set<CBPeripheral> = []

    // General
//    var endPointType:String?

    let midiLog = OSLog(subsystem: "com.invisiblewrench.FlutterMidiCommand", category: "MIDI")

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "plugins.invisiblewrench.com/flutter_midi_command", binaryMessenger: registrar.messenger())
        let instance = SwiftFlutterMidiCommandPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)

        instance.setup(registrar)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        MIDIClientDispose(midiClient)
    }

    func setup(_ registrar: FlutterPluginRegistrar) {
        // Stream setup
        midiRXChannel = FlutterEventChannel(name: "plugins.invisiblewrench.com/flutter_midi_command/rx_channel", binaryMessenger: registrar.messenger())
        midiRXChannel?.setStreamHandler(rxStreamHandler)

        midiSetupChannel = FlutterEventChannel(name: "plugins.invisiblewrench.com/flutter_midi_command/setup_channel", binaryMessenger: registrar.messenger())
        midiSetupChannel?.setStreamHandler(setupStreamHandler)

        // MIDI client with notification handler
        MIDIClientCreateWithBlock("plugins.invisiblewrench.com.FlutterMidiCommand" as CFString, &midiClient) { (notification) in
            self.handleMIDINotification(notification)
        }

        // MIDI output
        MIDIOutputPortCreate(midiClient, "FlutterMidiCommand_OutPort" as CFString, &outputPort);

        // MIDI Input with handler
        MIDIInputPortCreateWithBlock(midiClient, "FlutterMidiCommand_InPort" as CFString, &inputPort) { (packetList, srcConnRefCon) in
            self.handlePacketList(packetList)
        }

        let session = MIDINetworkSession.default()
        session.isEnabled = true
        session.connectionPolicy = MIDINetworkConnectionPolicy.anyone

        NotificationCenter.default.addObserver(self, selector: #selector(midiNetworkChanged(notification:)), name: Notification.Name(rawValue: MIDINetworkNotificationSessionDidChange), object: nil)
//        NotificationCenter.default.addObserver(self, selector: #selector(midiNetworkContactsChanged(notification:)), name: Notification.Name(rawValue: MIDINetworkNotificationContactsDidChange), object: nil)

        manager = CBCentralManager.init(delegate: self, queue: DispatchQueue.main)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
//        print("call method \(call.method)")
        switch call.method {
        case "scanForDevices":
            print("\(manager.state.rawValue)")
            if manager.state == CBManagerState.poweredOn {
                print("Start discovery")
                discoveredDevices.removeAll()
                manager.scanForPeripherals(withServices: [CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")], options: nil)
                result(nil)
            } else {
                print("BT not ready")
                result(FlutterError(code: "MESSAGEERROR", message: "bluetoothNotAvailable", details: call.arguments))
            }
            break
        case "stopScanForDevices":
            manager.stopScan()
            break
        case "getDevices":
            let destinations = getDestinations()
            print("--- Destinations ---\n\(destinations)")
            result(destinations)
            break
        case "connectToDevice":
            if let deviceInfo = call.arguments as? Dictionary<String, String> {
                connectToDevice(deviceId: deviceInfo["id"]!, type: deviceInfo["type"]!)
                result(nil)
            } else {
                result(FlutterError.init(code: "MESSAGEERROR", message: "Could not parse device id", details: call.arguments))
            }
            break
        case "disconnectDevice":
            if let deviceInfo = call.arguments as? Dictionary<String, String> {
                disconnectDevice(deviceId: deviceInfo["id"]!)
                result(nil)
            } else {
                result(FlutterError.init(code: "MESSAGEERROR", message: "Could not parse device id", details: call.arguments))
            }
            result(nil)
            break
        case "sendData":
            if let data = call.arguments as? FlutterStandardTypedData {
//                let deviceId =
                sendData(data, deviceId: nil)
                result(nil)
            } else {
                result(FlutterError.init(code: "MESSAGEERROR", message: "Could not parse data", details: call.arguments))
            }
            break
        default:
            result(FlutterMethodNotImplemented)
        }
    }


    func connectToDevice(deviceId:String, type:String) {
//        endPointType = type
        print("connect \(deviceId) \(type)")
        
        let conDev = ConnectedDevice(id: deviceId, type: type)
        
        if type == "BLE" {
            if let periph = discoveredDevices.filter({ (p) -> Bool in
                p.identifier.uuidString == deviceId
            }).first {
                connectingDevice = conDev
                conDev.peripheral = periph
                manager.stopScan()
                manager.connect(periph, options: nil)
            } else {
                print("error connecting to device \(deviceId) [\(type)]")
            }
        } else if type == "native" {
            if let id = Int(deviceId) {
                let src:MIDIEndpointRef = MIDIGetSource(id)
                print("setup endpoint \(src)")
                if (src != 0) {
                    var devId = deviceId
                    let status:OSStatus =   MIDIPortConnectSource(inputPort, src, &devId)
                    if (status == noErr) {
                        conDev.endPoint = src
                        connectedDevices[deviceId] = conDev
                        setupStreamHandler.send(data: "deviceConnected")
                        print("Connected MIDI for \(conDev)")
                    } else {
                        print("error connecting to device \(deviceId) [\(type)]")
                    }
                }
            }
        }
    }

    func disconnectDevice(deviceId:String) {
        let device = connectedDevices[deviceId]
        print("disconnect \(String(describing: device)) for id \(deviceId)")
        if let device = device {
            if device.type == "BLE" {
                if let p = device.peripheral {
                    manager.cancelPeripheralConnection(p)
                } else {
                    print("no BLE device to disconnect")
                }
            } else {
                print("disconmmected MIDI")
            }
            connectedDevices.removeValue(forKey: deviceId)
        }
    }


    func sendData(_ data: FlutterStandardTypedData, deviceId: String?) {
        if let deviceId = deviceId {
            if let device = connectedDevices[deviceId] {
                _sendDataToDevice(device: device, data: data)
            }
        } else {
            connectedDevices.values.forEach({ (device) in
                _sendDataToDevice(device: device, data: data)
            })
        }
    }
    
    func _sendDataToDevice(device:ConnectedDevice, data:FlutterStandardTypedData) {
//        print("send data \(data) to device \(device.id)")
        if (device.type == "BLE") {
//            print("BLE")
            if (device.peripheral != nil && device.characteristic != nil) {
                var bytes = [UInt8](data.data)
                if bytes.first == 0xF0 && bytes.last == 0xF7 {
                    bytes.insert(0x80, at: bytes.count-1) // Insert 0x80 in front of Sysex End-byte
                }
                
                // Insert 0x8080 in front of BLE Midi message
                bytes.insert(0x80, at: 0)
                bytes.insert(0x80, at: 0)
                
                device.peripheral?.writeValue(Data(bytes), for: device.characteristic!, type: CBCharacteristicWriteType.withoutResponse)
            } else {
                print("No peripheral/characteristic in device")
            }
        } else {
//            print("MIDI")
            let dest = MIDIGetDestination(Int(device.id) ?? 0)
            if (dest != 0) {
                let bytes = [UInt8](data.data)
                let packetList = UnsafeMutablePointer<MIDIPacketList>.allocate(capacity: 1)
                var packet = MIDIPacketListInit(packetList);
                let time = mach_absolute_time()
                packet = MIDIPacketListAdd(packetList, 1024, packet, time, bytes.count, bytes);
                
                MIDISend(outputPort, dest, packetList);
                
                packetList.deallocate()
            } else {
                print("No MIDI destination for id \(device.id)")
            }
        }
    }

    func getMIDIProperty(_ prop:CFString, fromObject obj:MIDIObjectRef) -> String {
        var param: Unmanaged<CFString>?
        var result: String = "Error"
        let err: OSStatus = MIDIObjectGetStringProperty(obj, prop, &param)
        if err == OSStatus(noErr) { result = param!.takeRetainedValue() as String }
        return result
    }

    func getDestinations() -> [Dictionary<String, String>] {
        var destinations:[Dictionary<String, String>] = []

        let count: Int = MIDIGetNumberOfDestinations()
        for i in 0..<count {
            let endpoint:MIDIEndpointRef = MIDIGetDestination(i)
            let id = String(i)
            destinations.append([
                "name" : getMIDIProperty(kMIDIPropertyDisplayName, fromObject: endpoint),
                "id":id,
                "type":"native",
                "connected":(connectedDevices.keys.contains(id) ? "true" : "false")
                ])
        }

        for periph:CBPeripheral in discoveredDevices {
            let id = periph.identifier.uuidString
            destinations.append([
                "name" : periph.name ?? "Unknown",
                "id" : id,
                "type" : "BLE",
                "connected":(connectedDevices.keys.contains(id) ? "true" : "false")
                ])
        }

        return destinations;
    }

    func handlePacketList(_ packetList:UnsafePointer<MIDIPacketList>) {
        let packets = packetList.pointee
        let packet:MIDIPacket = packets.packet
        var ap = UnsafeMutablePointer<MIDIPacket>.allocate(capacity: 1)
        ap.initialize(to:packet)

        for _ in 0 ..< packets.numPackets {
            let p = ap.pointee
            var tmp = p.data
            let data = Data(bytes: &tmp, count: Int(p.length))
//            print("RX data \(data)")
            rxStreamHandler.send(data: FlutterStandardTypedData(bytes: data))
            ap = MIDIPacketNext(ap)
        }
    }

    @objc func midiNetworkChanged(notification:NSNotification) {
        print("\(#function)")
        print("\(notification)")
        if let session = notification.object as? MIDINetworkSession {
            print("session \(session)")
            for con in session.connections() {
                print("con \(con)")
            }
            print("isEnabled \(session.isEnabled)")
            print("sourceEndpoint \(session.sourceEndpoint())")
            print("destinationEndpoint \(session.destinationEndpoint())")
            print("networkName \(session.networkName)")
            print("localName \(session.localName)")

            //            if let name = getDeviceName(session.sourceEndpoint()) {
            //                print("source name \(name)")
            //            }
            //
            //            if let name = getDeviceName(session.destinationEndpoint()) {
            //                print("destination name \(name)")
            //            }
        }
        setupStreamHandler.send(data: "\(#function) \(notification)")
    }

    @objc func midiNetworkContactsChanged(notification:NSNotification) {
        print("\(#function)")
        print("\(notification)")
        if let session = notification.object as? MIDINetworkSession {
            print("session \(session)")
            for con in session.contacts() {
                print("contact \(con)")
            }
        }
        setupStreamHandler.send(data: "\(#function) \(notification)")
    }

    func handleMIDINotification(_ midiNotification: UnsafePointer<MIDINotification>) {
        print("\ngot a MIDINotification!")

        let notification = midiNotification.pointee
        print("MIDI Notify, messageId= \(notification.messageID)")
        print("MIDI Notify, messageSize= \(notification.messageSize)")

        setupStreamHandler.send(data: "\(notification.messageID)")

        switch notification.messageID {

        // Some aspect of the current MIDISetup has changed.  No data.  Should ignore this  message if messages 2-6 are handled.
        case .msgSetupChanged:
            print("MIDI setup changed")
            let ptr = UnsafeMutablePointer<MIDINotification>(mutating: midiNotification)
            //            let ptr = UnsafeMutablePointer<MIDINotification>(midiNotification)
            let m = ptr.pointee
            print(m)
            print("id \(m.messageID)")
            print("size \(m.messageSize)")
            break


        // A device, entity or endpoint was added. Structure is MIDIObjectAddRemoveNotification.
        case .msgObjectAdded:

            print("added")
            //            let ptr = UnsafeMutablePointer<MIDIObjectAddRemoveNotification>(midiNotification)

            midiNotification.withMemoryRebound(to: MIDIObjectAddRemoveNotification.self, capacity: 1) {
                let m = $0.pointee
                print(m)
                print("id \(m.messageID)")
                print("size \(m.messageSize)")
                print("child \(m.child)")
                print("child type \(m.childType)")
                showMIDIObjectType(m.childType)
                print("parent \(m.parent)")
                print("parentType \(m.parentType)")
                showMIDIObjectType(m.parentType)
                //                print("childName \(String(describing: getDisplayName(m.child)))")
            }


            break

        // A device, entity or endpoint was removed. Structure is MIDIObjectAddRemoveNotification.
        case .msgObjectRemoved:
            print("kMIDIMsgObjectRemoved")
            //            let ptr = UnsafeMutablePointer<MIDIObjectAddRemoveNotification>(midiNotification)
            midiNotification.withMemoryRebound(to: MIDIObjectAddRemoveNotification.self, capacity: 1) {

                let m = $0.pointee
                print(m)
                print("id \(m.messageID)")
                print("size \(m.messageSize)")
                print("child \(m.child)")
                print("child type \(m.childType)")
                print("parent \(m.parent)")
                print("parentType \(m.parentType)")

                //                print("childName \(String(describing: getDisplayName(m.child)))")
            }
            break

        // An object's property was changed. Structure is MIDIObjectPropertyChangeNotification.
        case .msgPropertyChanged:
            print("kMIDIMsgPropertyChanged")
            midiNotification.withMemoryRebound(to: MIDIObjectPropertyChangeNotification.self, capacity: 1) {

                let m = $0.pointee
                print(m)
                print("id \(m.messageID)")
                print("size \(m.messageSize)")
                print("object \(m.object)")
                print("objectType  \(m.objectType)")
                print("propertyName  \(m.propertyName)")
                print("propertyName  \(m.propertyName.takeUnretainedValue())")

                if m.propertyName.takeUnretainedValue() as String == "apple.midirtp.session" {
                    print("connected")
                }
            }

            break

        //     A persistent MIDI Thru connection wasor destroyed.  No data.
        case .msgThruConnectionsChanged:
            print("MIDI thru connections changed.")
            break

        //A persistent MIDI Thru connection was created or destroyed.  No data.
        case .msgSerialPortOwnerChanged:
            print("MIDI serial port owner changed.")
            break

        case .msgIOError:
            print("MIDI I/O error.")

            //let ptr = UnsafeMutablePointer<MIDIIOErrorNotification>(midiNotification)
            midiNotification.withMemoryRebound(to: MIDIIOErrorNotification.self, capacity: 1) {
                let m = $0.pointee
                print(m)
                print("id \(m.messageID)")
                print("size \(m.messageSize)")
                print("driverDevice \(m.driverDevice)")
                print("errorCode \(m.errorCode)")
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
            print("midiObjectType: ExternalEntity")
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

    /// BLE handling

    // Central
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("central did update state \(central.state.rawValue)")
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        print("central didDiscover \(peripheral)")
        if !discoveredDevices.contains(peripheral) {
            discoveredDevices.insert(peripheral)
            setupStreamHandler.send(data: "deviceFound")
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("central did connect \(peripheral)")
//        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")])
    }


    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("central did fail to connect state \(peripheral)")
        connectingDevice = nil
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("central didDisconnectPeripheral \(peripheral)")
        
//        connectedPeripheral = nil
//        connectedCharacteristic = nil
        setupStreamHandler.send(data: "deviceDisconnected")
    }

    // Peripheral
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        print("perif didDiscoverServices  \(String(describing: peripheral.services))")
        for service:CBService in peripheral.services! {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        print("perif didDiscoverCharacteristicsFor  \(String(describing: service.characteristics))")
        for characteristic:CBCharacteristic in service.characteristics! {
            if characteristic.uuid.uuidString == "7772E5DB-3868-4112-A1A9-F2669D106BF3" {
                peripheral.setNotifyValue(true, for: characteristic)
                print("set up characteristic for device")
//                connectedCharacteristic = characteristic
                if let connecting = connectingDevice {
                    connecting.characteristic = characteristic
                    connectedDevices[connecting.id] = connecting
                    connectingDevice = nil
                    print(discoveredDevices)
                    setupStreamHandler.send(data: "deviceConnected")
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
//        print("perif didUpdateValueFor  \(String(describing: characteristic))")
        if let value = characteristic.value {
            print("ble value \(value)")
			if value.count >= 4 { // We might have a valid message
				let header = value[0]
				let timestamp = value[1]
				//see specs here http://www.hangar42.nl/wp-content/uploads/2017/10/BLE-MIDI-spec.pdf
				if (header & 128)==128 && (header & 64)==0 && (timestamp & 128)==128 {
					let messageBytes = value.advanced(by: 2) // Skip the initial two timestamp bytes
					let messages = messageBytes.split { (val) -> Bool in // Split at subseqent timestamps, if any
						val == timestamp
					}
					for message:Data in messages {
						rxStreamHandler.send(data: FlutterStandardTypedData(bytes: message))
					}
				}
            }
        }
    }
}


class StreamHandler : NSObject, FlutterStreamHandler {

    var sink:FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    func send(data: Any) {
        if let sink = sink {
            sink(data)
        } else {
            print("no sink")
        }
    }
}

class ConnectedDevice {
    var id:String
    var type:String
    var endPoint:MIDIEndpointRef = 0
    var peripheral:CBPeripheral?
    var characteristic:CBCharacteristic?
    
    init(id:String, type:String) {
        self.id = id
        self.type = type
    }
}
