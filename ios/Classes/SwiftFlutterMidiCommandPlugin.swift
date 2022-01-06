
#if os(macOS)
    import FlutterMacOS
 #else
    import Flutter
 #endif

import CoreMIDI
import os.log
import CoreBluetooth
import Foundation

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

public class SwiftFlutterMidiCommandPlugin: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, FlutterPlugin {

    // MIDI
    var midiClient = MIDIClientRef()
    var connectedDevices = Dictionary<String, ConnectedDevice>()
    
    // Flutter
    var midiRXChannel:FlutterEventChannel?
    var rxStreamHandler = StreamHandler()

    var midiSetupChannel:FlutterEventChannel?
    var setupStreamHandler = StreamHandler()

    var bluetoothStateChannel: FlutterEventChannel?
    var bluetoothStateHandler = StreamHandler()

    #if os(iOS)
    // Network Session
    var session:MIDINetworkSession?
    #endif

    // BLE
    var manager:CBCentralManager!
    var discoveredDevices:Set<CBPeripheral> = []


    var ongoingConnections = Dictionary<String, FlutterResult>()
    

    let midiLog = OSLog(subsystem: "com.invisiblewrench.FlutterMidiCommand", category: "MIDI")

    public static func register(with registrar: FlutterPluginRegistrar) {
        #if os(macOS)
            let channel = FlutterMethodChannel(name: "plugins.invisiblewrench.com/flutter_midi_command", binaryMessenger: registrar.messenger)
        #else
            let channel = FlutterMethodChannel(name: "plugins.invisiblewrench.com/flutter_midi_command", binaryMessenger: registrar.messenger())
        #endif
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
        #if os(macOS)
            midiRXChannel = FlutterEventChannel(name: "plugins.invisiblewrench.com/flutter_midi_command/rx_channel", binaryMessenger: registrar.messenger)
        #else
            midiRXChannel = FlutterEventChannel(name: "plugins.invisiblewrench.com/flutter_midi_command/rx_channel", binaryMessenger: registrar.messenger())
        #endif
        midiRXChannel?.setStreamHandler(rxStreamHandler)


        #if os(macOS)
            midiSetupChannel = FlutterEventChannel(name: "plugins.invisiblewrench.com/flutter_midi_command/setup_channel", binaryMessenger: registrar.messenger)
            bluetoothStateChannel = FlutterEventChannel(name: "plugins.invisiblewrench.com/flutter_midi_command/bluetooth_central_state", binaryMessenger: registrar.messenger)
        #else
            midiSetupChannel = FlutterEventChannel(name: "plugins.invisiblewrench.com/flutter_midi_command/setup_channel", binaryMessenger: registrar.messenger())
            bluetoothStateChannel = FlutterEventChannel(name: "plugins.invisiblewrench.com/flutter_midi_command/bluetooth_central_state", binaryMessenger: registrar.messenger())
        #endif
        midiSetupChannel?.setStreamHandler(setupStreamHandler)
        bluetoothStateChannel?.setStreamHandler(bluetoothStateHandler)


        // MIDI client with notification handler
        MIDIClientCreateWithBlock("plugins.invisiblewrench.com.FlutterMidiCommand" as CFString, &midiClient) { (notification) in
            self.handleMIDINotification(notification)
        }

#if os(iOS)
         session = MIDINetworkSession.default()
         session?.isEnabled = true
         session?.connectionPolicy = MIDINetworkConnectionPolicy.anyone
         #endif
    }


    func extractName(arguments: Any?) -> String?{
        var name: String? = nil
        if let packet = arguments as? Dictionary<String, Any> {
            name = packet["name"] as? String
        }
        return name
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

    public func startBluetoothCentralWhenNeeded(){
        if(manager == nil){
            manager = CBCentralManager.init(delegate: self, queue: DispatchQueue.global(qos: .userInteractive))
        }
    }

    public func getBluetooCentralStateAsString() -> String {
        startBluetoothCentralWhenNeeded();
        switch(manager.state){
        case CBManagerState.poweredOn:
            return "poweredOn";
        case CBManagerState.poweredOff:
            return "poweredOff";
        case CBManagerState.resetting:
            return "resetting";
        case CBManagerState.unauthorized:
            return "unauthorized";
        case CBManagerState.unknown:
            return "unknown";
        case CBManagerState.unsupported:
            return "unsupported";
        @unknown default:
            return "other";
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
//        print("call method \(call.method)")
        switch call.method {
        case "startBluetoothCentral":
            startBluetoothCentralWhenNeeded();
            result(nil);
            break;
        case "scanForDevices":
            startBluetoothCentralWhenNeeded();
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
            startBluetoothCentralWhenNeeded();
            manager.stopScan()
            break
        case "getDevices":
            let devices = getDevices()
            print("--- devices ---\n\(devices)")
            result(devices)
            break
        case "connectToDevice":
            if let args = call.arguments as? Dictionary<String, Any> {
                if let deviceInfo = args["device"] as? Dictionary<String, Any> {
                    if let deviceId = deviceInfo["id"] as? String {
                        if connectedDevices[deviceId] != nil {
                            result(FlutterError.init(code: "MESSAGEERROR", message: "Device already connected", details: call.arguments))
                        } else {
                            ongoingConnections[deviceId] = result
                            connectToDevice(deviceId: deviceId, type: deviceInfo["type"] as! String, ports: nil)
                        }
                    } else {
                        result(FlutterError.init(code: "MESSAGEERROR", message: "No device Id", details: deviceInfo))
                    }
                } else {
                    result(FlutterError.init(code: "MESSAGEERROR", message: "Could not parse deviceInfo", details: call.arguments))
                }
            } else {
                result(FlutterError.init(code: "MESSAGEERROR", message: "Could not parse args", details: call.arguments))
            }
            break
        case "disconnectDevice":
            if let deviceInfo = call.arguments as? Dictionary<String, Any> {
                if let deviceId = deviceInfo["id"] as? String {
                    disconnectDevice(deviceId: deviceId)
                } else {
                    result(FlutterError.init(code: "MESSAGEERROR", message: "No device Id", details: call.arguments))
                }
                result(nil)
            } else {
                result(FlutterError.init(code: "MESSAGEERROR", message: "Could not parse device id", details: call.arguments))
            }
            result(nil)
            break

        case "sendData":
            if let packet = call.arguments as? Dictionary<String, Any> {
                sendData(packet["data"] as! FlutterStandardTypedData, deviceId: packet["deviceId"] as? String, timestamp: packet["timestamp"] as? UInt64)
                result(nil)
            } else {
                result(FlutterError.init(code: "MESSAGEERROR", message: "Could not form midi packet", details: call.arguments))
            }
            break
        case "teardown":
            teardown()
            break

        case "addVirtualDevice":
            let name = extractName(arguments: call.arguments) ?? appName()
            let ownVirtualDevice = findOrCreateOwnVirtualDevice(name: name)
            let error = ownVirtualDevice.errors.count > 0 ? ownVirtualDevice.errors.joined(separator: "\n") : nil;
            if(error != nil){
                removeOwnVirtualDevice(name: name)
            }

            result(error == nil ? error : FlutterError.init(code: "AUDIOERROR", message: error, details: call.arguments))
            break;

        case "removeVirtualDevice":
            let name = extractName(arguments: call.arguments) ?? appName()
            removeOwnVirtualDevice(name: name)
            result(nil)
            break;            
                    
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    func teardown() {
        for device in connectedDevices {
            disconnectDevice(deviceId: device.value.id)
        }
        #if os(iOS)
        session?.isEnabled = false
        #endif
    }


    func connectToDevice(deviceId:String, type:String, ports:[Port]?) {
        print("connect \(deviceId) \(type)")
                
        if type == "BLE" {
            if let periph = discoveredDevices.filter({ (p) -> Bool in p.identifier.uuidString == deviceId }).first {
                let device = ConnectedBLEDevice(id: deviceId, type: type, streamHandler: rxStreamHandler, result:ongoingConnections[deviceId], peripheral: periph, ports:ports)
                connectedDevices[deviceId] = device
                manager.stopScan()
                manager.connect(periph, options: nil)
            } else {
                print("error connecting to device \(deviceId) [\(type)]")
            }
        } else if type == "own-virtual" {
            let device = ownVirtualDevices.first { device in
                String(device.id) == deviceId
            }

            if let device = device {
                connectedDevices[device.id] = device
                (device as ConnectedOwnVirtualDevice).isConnected = true
                setupStreamHandler.send(data: "deviceConnected")
                if let result = ongoingConnections[deviceId] {
                    result(nil)
                }
            }
        } else // if type == "native" || if type == "virtual"
        {
            let device = type == "native" ? ConnectedNativeDevice(id: deviceId, type: type, streamHandler: rxStreamHandler, client: midiClient, ports:ports)
                : ConnectedVirtualDevice(id: deviceId, type: type, streamHandler: rxStreamHandler, client: midiClient, ports:ports)
            print("connected to \(device) \(deviceId)")
            connectedDevices[deviceId] = device
            setupStreamHandler.send(data: "deviceConnected")
            if let result = ongoingConnections[deviceId] {
                result(nil)
            }
        }
    }

    func disconnectDevice(deviceId:String) {
        let device = connectedDevices[deviceId]
        print("disconnect \(String(describing: device)) for id \(deviceId)")
        if let device = device {
            if device.deviceType == "BLE" {
                let p = (device as! ConnectedBLEDevice).peripheral
                manager.cancelPeripheralConnection(p)
            } else if device.deviceType == "own-virtual" {
                print("disconnected MIDI")
                (device as! ConnectedOwnVirtualDevice).isConnected = false
                setupStreamHandler.send(data: "deviceDisconnected")
            }
            else {
                print("disconnected MIDI")
                device.close()
                setupStreamHandler.send(data: "deviceDisconnected")
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
    

    func createPortDict(count:Int) -> Array<Dictionary<String, Any>> {
        return (0..<count).map { (id) -> Dictionary<String, Any> in
            return ["id": id, "connected" : false]
        }
    }

    
    func getDevices() -> [Dictionary<String, Any>] {
        var devices:[Dictionary<String, Any>] = []

        // ######
        // Native
        // ######
      
        var nativeDevices = Dictionary<MIDIEntityRef, Dictionary<String, Any>>()
        
        let destinationCount = MIDIGetNumberOfDestinations()
        for d in 0..<destinationCount {
            let destination = MIDIGetDestination(d)
//            print("dest \(destination) \(SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyName, fromObject: destination))")

            if(isVirtualEndpoint(endpoint: destination)){
              continue;
            }
            
            var entity : MIDIEntityRef = 0
            var status = MIDIEndpointGetEntity(destination, &entity)
            if(status != noErr){
                print("Error \(status) while calling MIDIEndpointGetEntity");
            }

            let isNetwork = SwiftFlutterMidiCommandPlugin.isNetwork(device: entity)
            
            var device : MIDIDeviceRef = 0
            status = MIDIEntityGetDevice(entity, &device)
            if(status != noErr){
                print("Error \(status) while calling MIDIEntityGetDevice");
            }

            let name = displayName(endpoint: destination);

            let entityCount = MIDIDeviceGetNumberOfEntities(device)
//            print("entityCount \(entityCount)")
            
            var entityIndex = 0;
            for e in 0..<entityCount {
                let ent = MIDIDeviceGetEntity(device, e)
//                print("ent \(ent)")
                if (ent == entity) {
                    entityIndex = e
                }
            }
//            print("entityIndex \(entityIndex)")
             let deviceId = "\(device):\(entityIndex)"
            
            let entityDestinationCount = MIDIEntityGetNumberOfDestinations(entity)
//            print("entiry dest count \(entityDestinationCount)")
            
            nativeDevices[entity] = [
                "name" : name,
                "id" :  deviceId,
                "type" : isNetwork ? "network" : "native",
                "connected":(connectedDevices.keys.contains(deviceId) ? "true" : "false"),
                "outputs" : createPortDict(count: entityDestinationCount)
                ]
        }
        
        
        let sourceCount = MIDIGetNumberOfSources()
        for s in 0..<sourceCount {
            let source = MIDIGetSource(s)
//            print("src \(source) \(SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyName, fromObject: source))")

            if(isVirtualEndpoint(endpoint: source)){
              continue;
            }
            
            var entity : MIDIEntityRef = 0
            var status = MIDIEndpointGetEntity(source, &entity)
            if(status != noErr){
                print("Error \(status) while calling MIDIEndpointGetEntity");
            }
            let isNetwork = SwiftFlutterMidiCommandPlugin.isNetwork(device: entity)
            let name = displayName(endpoint: source);
            
            var device : MIDIDeviceRef = 0
            status = MIDIEntityGetDevice(entity, &device)
            if(status != noErr){
                print("Error \(status) while calling MIDIEntityGetDevice");
            }

            let entityCount = MIDIDeviceGetNumberOfEntities(device)
//            print("entityCount \(entityCount)")
            
            var entityIndex = 0;
            for e in 0..<entityCount {
                let ent = MIDIDeviceGetEntity(device, e)
//                print("ent \(ent)")
                if (ent == entity) {
                    entityIndex = e
                }
            }
//            print("entityIndex \(entityIndex)")

            let deviceId = "\(device):\(entityIndex)"
            
            let entitySourceCount = MIDIEntityGetNumberOfSources(entity)
//            print("entiry source count \(entitySourceCount)")
            
            if var deviceDict = nativeDevices[entity] {
//                print("add inputs to dict")
                deviceDict["inputs"] = createPortDict(count: entitySourceCount)
//                print(type(of: createPortDict(count: entitySourceCount)))
                nativeDevices[entity] = deviceDict
            } else {
//                print("create inputs dict")
                nativeDevices[entity] = [
                    "name" : name,
                    "id" : deviceId,
                    "type" : isNetwork ? "network" : "native",
                    "connected":(connectedDevices.keys.contains(deviceId) ? "true" : "false"),
                    "inputs" : createPortDict(count: entitySourceCount)
                    ]
            }
        }
        
        devices.append(contentsOf: nativeDevices.values)
        
        // ######
        // BLE
        // ######

        for periph:CBPeripheral in discoveredDevices {
            let id = periph.identifier.uuidString
            devices.append([
                "name" : periph.name ?? "Unknown",
                "id" : id,
                "type" : "BLE",
                "connected":(connectedDevices.keys.contains(id) ? "true" : "false"),
                "inputs" : [["id":0, "connected":false]],
                "outputs" : [["id":0, "connected":false]]
                ])
        }


        // #######
        // VIRTUAL
        // #######

        var virtualDevices = Dictionary<MIDIEntityRef, Dictionary<String, Any>>()

        for d in 0..<destinationCount {
          let destination = MIDIGetDestination(d)

          if(!isVirtualEndpoint(endpoint: destination)){
            continue;
          }

          if(isOwnVirtualEndpoint(endpoint: destination)){
            continue;
          }

          let displayName = SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyDisplayName, fromObject: destination);
          let id = stringToId(str: displayName); // Will cause conflicts when multiple virtual endpoints with the same name exist

          virtualDevices[id] = [
            "name" : displayName,
            "id" : "\(destination)",
            "type" : "virtual",
            "connected":(connectedDevices.keys.contains(String(destination)) ? "true" : "false"),
            "outputs" : createPortDict(count: 1)
          ]
        }


        for s in 0..<sourceCount {
          let source = MIDIGetSource(s)

          if(!isVirtualEndpoint(endpoint: source)){
            continue;
          }

          if(isOwnVirtualEndpoint(endpoint: source)){
            continue;
          }

          let displayName = SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyDisplayName, fromObject: source);
          let id = stringToId(str: displayName);  // Will cause conflicts when multiple virtual endpoints with the same name exist


          if var deviceDict = virtualDevices[id] {
            deviceDict["inputs"] = createPortDict(count: 1)
            let destination = deviceDict["id"] as? String ?? ""
            let id2 = "\(destination):\(source)"
            deviceDict["id"] = id2
            deviceDict["connected"] = (connectedDevices.keys.contains(id2) ? "true" : "false")
            virtualDevices[id] = deviceDict

          } else {
            //                print("create inputs dict")
            let id2 = ":\(source)"
            virtualDevices[id] = [
              "name" : displayName,
              "id" : id2,
              "type" : "virtual",
              "connected":(connectedDevices.keys.contains(id2) ? "true" : "false"),
              "inputs" : createPortDict(count: 1)
            ]
          }
        }

        devices.append(contentsOf: virtualDevices.values)



        // ###########
        // OWN VIRTUAL
        // ###########

        var ownVirtualDevices = Dictionary<MIDIEntityRef, Dictionary<String, Any>>()

        for ownVirtualDevice in self.ownVirtualDevices {
            let displayName = ownVirtualDevice.deviceName
            let id = stringToId(str: displayName)

            ownVirtualDevices[id] = [
                "name" : displayName,
                "id" : "\(id)",
                "type" : "own-virtual",
                "connected":(connectedDevices.keys.contains(String(id)) ? "true" : "false"),
                "outputs" : createPortDict(count: 1),
                "inputs" : createPortDict(count: 1),
            ]
        }

        devices.append(contentsOf: ownVirtualDevices.values)


        return devices;
    }


    func handleMIDINotification(_ midiNotification: UnsafePointer<MIDINotification>) {
        print("\ngot a MIDINotification!")

        let notification = midiNotification.pointee
        print("MIDI Notify, messageId= \(notification.messageID) \(notification.messageSize)")

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

    #if os(iOS)
    /// MIDI Network Session
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
    #endif

    /// BLE handling

    // Central
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("central did update state \(central.state.rawValue)")
        bluetoothStateHandler.send(data: getBluetooCentralStateAsString());
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        print("central didDiscover \(peripheral)")
        if !discoveredDevices.contains(peripheral) {
            discoveredDevices.insert(peripheral)
            setupStreamHandler.send(data: "deviceAppeared")
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("central did connect \(peripheral)")
        (connectedDevices[peripheral.identifier.uuidString] as! ConnectedBLEDevice).setupBLE(stream: setupStreamHandler)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("central did fail to connect state \(peripheral)")
        
        setupStreamHandler.send(data: "connectionFailed")
        connectedDevices.removeValue(forKey: peripheral.identifier.uuidString)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("central didDisconnectPeripheral \(peripheral)")

        setupStreamHandler.send(data: "deviceDisconnected")
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
//        } else {
//            print("no sink")
        }
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

  init(id:String, type:String, streamHandler:StreamHandler, client: MIDIClientRef, ports:[Port]?) {
    self.client = client
    self.ports = ports
    super.init(id: id, type: type, streamHandler: streamHandler)
  }

  override func send(bytes: [UInt8], timestamp: UInt64?) {
    if let ep = outEndpoint {
      let packetList = UnsafeMutablePointer<MIDIPacketList>.allocate(capacity: 1)
      var packet = MIDIPacketListInit(packetList)
      let time = timestamp ?? mach_absolute_time()
      packet = MIDIPacketListAdd(packetList, 1024, packet, time, bytes.count, bytes)

      let status = MIDISend(outputPort, ep, packetList)
      if(status != noErr){
          print("Error \(status) while sending MIDI to virtual or physical destination")
      }

      //print("send bytes \(bytes) on port \(outputPort) \(ep) status \(status)")
      packetList.deallocate()
    } else {
      print("No MIDI destination for id \(name!)")
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

  func handlePacketList(_ packetList:UnsafePointer<MIDIPacketList>, srcConnRefCon:UnsafeMutableRawPointer?) {
    let packets = packetList.pointee
    let packet:MIDIPacket = packets.packet
    var ap = buffer;
    buffer.initialize(to:packet)

    let deviceInfo = ["name" : name,
                      "id": String(id),
                      "type":deviceType,
                      "connected": String(true),]

    for _ in 0 ..< packets.numPackets {
      let p = ap.pointee
      var tmp = p.data
      let data = Data(bytes: &tmp, count: Int(p.length))
      let timestamp = p.timeStamp
      //            print("data \(data) timestamp \(timestamp)")
      streamHandler.send(data: ["data": data, "timestamp":timestamp, "device":deviceInfo])
      ap = MIDIPacketNext(ap)
    }
  }
}

class ConnectedNativeDevice : ConnectedVirtualOrNativeDevice {

    var entity : MIDIEntityRef?


  override init(id:String, type:String, streamHandler:StreamHandler, client: MIDIClientRef, ports:[Port]?) {
       super.init(id:id, type: type, streamHandler: streamHandler, client: client, ports: ports)

        self.ports = ports
        let idParts = id.split(separator: ":")
        
        // Store entity and get device/entity name
        if let deviceId = MIDIDeviceRef(idParts[0]) {
            if let entityId = Int(idParts[1]) {
                entity = MIDIDeviceGetEntity(deviceId, entityId)
                if let e = entity {
                    let entityName = SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyName, fromObject: e)
                    
                    var device:MIDIDeviceRef = 0
                    MIDIEntityGetDevice(e, &device)
                    let deviceName = SwiftFlutterMidiCommandPlugin.getMIDIProperty(kMIDIPropertyName, fromObject: device)
                    
                    name = "\(deviceName) \(entityName)"
                } else {
                    print("no entity")
                }
            } else {
                print("no entityId")
            }
        } else {
            print("no deviceId")
        }
        

        
        // MIDI Input with handler
         MIDIInputPortCreateWithBlock(client, "FlutterMidiCommand_InPort" as CFString, &inputPort) { (packetList, srcConnRefCon) in
             self.handlePacketList(packetList, srcConnRefCon: srcConnRefCon)
         }
        
        // MIDI output
        MIDIOutputPortCreate(client, "FlutterMidiCommand_OutPort" as CFString, &outputPort);

        openPorts()
    }
    
    override func openPorts() {
        print("open native ports")
        
        if let e = entity {

            if let ps = ports {
                for port in ps {
                    inSource = MIDIEntityGetSource(e, port.id)

                    switch port.type {
                    case "MidiPortType.IN":
                        let status = MIDIPortConnectSource(inputPort, inSource!, &name)
                        print("port open status \(status)")
                    case "MidiPortType.OUT":
                        outEndpoint = MIDIEntityGetDestination(e, port.id)
    //                    print("port endpoint \(endpoint)")
                        break
                    default:
                        print("unknown port type \(port.type)")
                    }
                }
            } else {
                print("open default ports")
                inSource = MIDIEntityGetSource(e, 0)
                let status = MIDIPortConnectSource(inputPort, inSource!, &name)
                if(status != noErr){
                    print("Error \(status) while calling MIDIPortConnectSource");
                }
                outEndpoint = MIDIEntityGetDestination(e, 0)
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
        let packets = packetList.pointee
        let packet:MIDIPacket = packets.packet
        var ap = buffer
        ap.initialize(to:packet)

        let deviceInfo = ["name" : name,
                          "id": String(id),
                          "type":"native"]
        
        var timestampFactor : Double = 1.0
        var tb = mach_timebase_info_data_t()
        let kError = mach_timebase_info(&tb)
        if (kError == 0) {
            timestampFactor = Double(tb.numer) / Double(tb.denom)
        }
        
//        print("tb \(tb) timestamp \(timestampFactor)")
        
        for _ in 0 ..< packets.numPackets {
            let p = ap.pointee
            var tmp = p.data
            let data = Data(bytes: &tmp, count: Int(p.length))
            let timestamp = Int(round(Double(p.timeStamp) * timestampFactor))
//            print("data \(data) timestamp \(timestamp)")
            streamHandler.send(data: ["data": data, "timestamp":timestamp, "device":deviceInfo])
            ap = MIDIPacketNext(ap)
        }
        
//        ap.deallocate()
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
        MIDIPortConnectSource(inputPort, inSource!, &name);
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

        let packetList = UnsafeMutablePointer<MIDIPacketList>.allocate(capacity: 1)
        var packet = MIDIPacketListInit(packetList)
        let time = timestamp ?? mach_absolute_time()
        packet = MIDIPacketListAdd(packetList, 1024, packet, time, bytes.count, bytes)

        let status = MIDIReceived(virtualSourceEndpoint, packetList)
        if(status != noErr){
            let error = "Error \(status) while publishing MIDI on own virtual source endpoint."
            errors.append(error)
            print(error)
        }

        packetList.deallocate()
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
            print(error)
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
                print(error)
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
            print(error)
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
                print(error)
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
                print(error)
            }
        }
    }

    func closeVirtualDestination(){
        let s = MIDIEndpointDispose(virtualDestinationEndpoint);
        if(s != 0){
            let error = "Error: \(s) while disposing MIDI endpoint"
            errors.append(error)
            print(error)
        }
    }
}

class ConnectedBLEDevice : ConnectedDevice, CBPeripheralDelegate {
    var peripheral:CBPeripheral
    var characteristic:CBCharacteristic?

    
    // BLE MIDI parsing
    enum BLE_HANDLER_STATE
    {
        case HEADER
        case TIMESTAMP
        case STATUS
        case STATUS_RUNNING
        case PARAMS
        case SYSTEM_RT
        case SYSEX
        case SYSEX_END
        case SYSEX_INT
    }

    var bleHandlerState = BLE_HANDLER_STATE.HEADER

    var sysExBuffer: [UInt8] = []
    var timestamp: UInt64 = 0
    var bleMidiBuffer:[UInt8] = []
    var bleMidiPacketLength:UInt8 = 0
    var bleSysExHasFinished = true

    var setupStream : StreamHandler?
    var connectResult : FlutterResult?

    init(id:String, type:String, streamHandler:StreamHandler, result:FlutterResult?, peripheral:CBPeripheral, ports:[Port]?) {
        self.peripheral = peripheral
        self.connectResult = result
        super.init(id: id, type: type, streamHandler: streamHandler)
    }
    
    func setupBLE(stream: StreamHandler) {
        setupStream = stream
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")])
    }

    
    override func close() {
        CBCentralManager().cancelPeripheralConnection(peripheral)
        characteristic = nil
    }
    
    override func send(bytes:[UInt8], timestamp: UInt64?) {
//        print("ble send \(id) \(bytes)")
        if (characteristic != nil) {

            let writeType = CBCharacteristicWriteType.withoutResponse
            let packetSize = peripheral.maximumWriteValueLength(for:writeType)
            // print("packetSize = \(packetSize)")

            var dataBytes = Data(bytes)

            if bytes.first == 0xF0 && bytes.last == 0xF7 { //  this is a sysex message, handle carefully
                if bytes.count > packetSize-3 { // Split into multiple messages of 20 bytes total

                    // First packet
                    var packet = dataBytes.subdata(in: 0..<packetSize-2)

                    print("count \(dataBytes.count)")

                    // Insert header(and empty timstamp high) and timestamp low in front Sysex Start
                    packet.insert(0x80, at: 0)
                    packet.insert(0x80, at: 0)

//                        print("packet \(packet)")
//                        print("packet \(hexEncodedString(packet))")

                    peripheral.writeValue(packet, for: characteristic!, type: writeType)

                    dataBytes = dataBytes.advanced(by: packetSize-2)

                    // More packets
                    while dataBytes.count > 0 {

                        print("count \(dataBytes.count)")

                        let pickCount = min(dataBytes.count, packetSize-1)
//                            print("pickCount \(pickCount)")
                        packet = dataBytes.subdata(in: 0..<pickCount) // Pick bytes for packet

                        // Insert header
                        packet.insert(0x80, at: 0)

                        if (packet.count < packetSize) { // Last packet
                            // Timestamp before Sysex End byte
                            print("insert end")
                            packet.insert(0x80, at: packet.count-1)
                        }

//                            print("packet \(hexEncodedString(packet))")

                        peripheral.writeValue(packet, for: characteristic!, type: writeType)

                        if (dataBytes.count > packetSize-2) {
                            dataBytes = dataBytes.advanced(by: pickCount) // Advance buffer
                        }
                        else {
                            print("done")
                            return
                        }
                    }
                } else {
                    // Insert timestamp low in front of Sysex End-byte
                    dataBytes.insert(0x80, at: bytes.count-1)

                    // Insert header(and empty timstamp high) and timestamp low in front of BLE Midi message
                    dataBytes.insert(0x80, at: 0)
                    dataBytes.insert(0x80, at: 0)

                    peripheral.writeValue(dataBytes, for: characteristic!, type: writeType)
                }
                return
            }

            // Insert header(and empty timstamp high) and timestamp low in front of BLE Midi message
            dataBytes.insert(0x80, at: 0)
            dataBytes.insert(0x80, at: 0)

            peripheral.writeValue(dataBytes, for: characteristic!, type: writeType)
        } else {
            print("No peripheral/characteristic in device")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let err = error {
            print("error writing to characteristic \(String(describing: characteristic.properties)): \(err.localizedDescription)")
        }
    }
    
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
                self.characteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                print("set up characteristic for device")
                setupStream?.send(data: "deviceConnected")
                if let res = connectResult {
                    res(nil)
                }
                return;
            }
        }

        if let res = connectResult {
            res(FlutterError.init(code: "BLEERROR", message: "Did not discover MIDI characteristics", details: id))
        }
    }
    
    func createMessageEvent(_ bytes:[UInt8], timestamp:UInt64, peripheral:CBPeripheral) {
//        print("send rx event \(bytes)")
        let data = Data(bytes: bytes, count: Int(bytes.count))
        streamHandler.send(data: ["data": data, "timestamp":timestamp, "device":[
                                                            "name" : peripheral.name ?? "-",
                                        "id":peripheral.identifier.uuidString,
                                                                    "type":"BLE"]])
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
//        print("perif didUpdateValueFor  \(String(describing: characteristic))")
        if let value = characteristic.value {
            parseBLEPacket(value, peripheral:peripheral)
        }
    }
    
    func parseBLEPacket(_ packet:Data, peripheral:CBPeripheral) -> Void {
//        print("parse \(packet.map { String(format: "%02hhx ", $0) }.joined())")
        
        if (packet.count > 1)
          {
            // parse BLE message
            bleHandlerState = BLE_HANDLER_STATE.HEADER

            let header = packet[0]
            var statusByte:UInt8 = 0

            for i in 1...packet.count-1 {
                let midiByte:UInt8 = packet[i]
//              print ("from bleHandlerState \(bleHandlerState) byte \(midiByte)")
                
                if ((((midiByte & 0x80) == 0x80) && (bleHandlerState != BLE_HANDLER_STATE.TIMESTAMP)) && (bleHandlerState != BLE_HANDLER_STATE.SYSEX_INT)) {
                    if (!bleSysExHasFinished) {
                        if ((midiByte & 0xF7) == 0xF7)
                        { // Sysex end
//                            print("sysex end on byte \(midiByte)")
                          bleSysExHasFinished = true
                          bleHandlerState = BLE_HANDLER_STATE.SYSEX_END
                        } else {
//                            print("Set to SYSEX_INT")
                            bleHandlerState = BLE_HANDLER_STATE.SYSEX_INT
                        }
                    } else {
                        bleHandlerState = BLE_HANDLER_STATE.TIMESTAMP
                    }
                } else {

                  // State handling
                  switch (bleHandlerState)
                  {
                  case BLE_HANDLER_STATE.HEADER:
                    if (!bleSysExHasFinished)
                    {
                      if ((midiByte & 0x80) == 0x80)
                      { // System messages can interrupt ongoing sysex
                        bleHandlerState = BLE_HANDLER_STATE.SYSEX_INT
                      }
                      else
                      {
                        // Sysex continue
                        //print("sysex continue")
                        bleHandlerState = BLE_HANDLER_STATE.SYSEX
                      }
                    }
                    break

                  case BLE_HANDLER_STATE.TIMESTAMP:
                    if ((midiByte & 0xFF) == 0xF0)
                    { // Sysex start
                      bleSysExHasFinished = false
                        sysExBuffer.removeAll()
                      bleHandlerState = BLE_HANDLER_STATE.SYSEX
                    }
                    else if ((midiByte & 0x80) == 0x80)
                    { // Status/System start
                      bleHandlerState = BLE_HANDLER_STATE.STATUS
                    }
                    else
                    {
                      bleHandlerState = BLE_HANDLER_STATE.STATUS_RUNNING
                    }
                    break

                  case BLE_HANDLER_STATE.STATUS:
                      bleHandlerState = BLE_HANDLER_STATE.PARAMS
                    break

                  case BLE_HANDLER_STATE.STATUS_RUNNING:
                    bleHandlerState = BLE_HANDLER_STATE.PARAMS
                    break;

                  case BLE_HANDLER_STATE.PARAMS: // After params can come TSlow or more params
                    break

                  case BLE_HANDLER_STATE.SYSEX:
                    break

                  case BLE_HANDLER_STATE.SYSEX_INT:
                    if ((midiByte & 0xF7) == 0xF7)
                    { // Sysex end
//                        print("sysex end")
                      bleSysExHasFinished = true
                      bleHandlerState = BLE_HANDLER_STATE.SYSEX_END
                    }
                    else
                    {
                        bleHandlerState = BLE_HANDLER_STATE.SYSTEM_RT
                    }
                    break;

                  case BLE_HANDLER_STATE.SYSTEM_RT:
                    if (!bleSysExHasFinished)
                    { // Continue incomplete Sysex
                      bleHandlerState = BLE_HANDLER_STATE.SYSEX
                    }
                    break

                  default:
                    print ("Unhandled state \(bleHandlerState)")
                    break
                  }
                }

//                print ("handle \(bleHandlerState) - \(midiByte) [\(String(format:"%02X", midiByte))]")

              // Data handling
              switch (bleHandlerState)
              {
              case BLE_HANDLER_STATE.TIMESTAMP:
//                print ("set timestamp")
                let tsHigh = header & 0x3f
                let tsLow = midiByte & 0x7f
                timestamp = UInt64(tsHigh) << 7 | UInt64(tsLow)
//                print ("timestamp is \(timestamp)")
                break

              case BLE_HANDLER_STATE.STATUS:

                bleMidiPacketLength = lengthOfMessageType(midiByte)
//                print("message length \(bleMidiPacketLength)")
                bleMidiBuffer.removeAll()
                bleMidiBuffer.append(midiByte)
                
                if bleMidiPacketLength == 1 {
                    createMessageEvent(bleMidiBuffer, timestamp: timestamp, peripheral:peripheral) // TODO Add timestamp
                } else {
//                    print ("set status")
                    statusByte = midiByte
                }
                break

              case BLE_HANDLER_STATE.STATUS_RUNNING:
//                print("set running status")
                bleMidiPacketLength = lengthOfMessageType(statusByte)
                bleMidiBuffer.removeAll()
                bleMidiBuffer.append(statusByte)
                bleMidiBuffer.append(midiByte)
                
                if bleMidiPacketLength == 2 {
                    createMessageEvent(bleMidiBuffer, timestamp: timestamp, peripheral:peripheral)
                }
                break

              case BLE_HANDLER_STATE.PARAMS:
//                print ("add param \(midiByte)")
                bleMidiBuffer.append(midiByte)
                
                if bleMidiPacketLength == bleMidiBuffer.count {
                    createMessageEvent(bleMidiBuffer, timestamp: timestamp, peripheral:peripheral)
                    bleMidiBuffer.removeLast(Int(bleMidiPacketLength)-1) // Remove all but status, which might be used for running msgs
                }
                break

              case BLE_HANDLER_STATE.SYSTEM_RT:
//                print("handle RT")
                createMessageEvent([midiByte], timestamp: timestamp, peripheral:peripheral)
                break

              case BLE_HANDLER_STATE.SYSEX:
//                print("add sysex")
                sysExBuffer.append(midiByte)
                break

              case BLE_HANDLER_STATE.SYSEX_INT:
//                print("sysex int")
                break

              case BLE_HANDLER_STATE.SYSEX_END:
//                print("finalize sysex")
                sysExBuffer.append(midiByte)
                createMessageEvent(sysExBuffer, timestamp: 0, peripheral:peripheral)
                break

              default:
                print ("Unhandled state (data) \(bleHandlerState)")
                break
              }
            }
          }
        }
    
    func lengthOfMessageType(_ type:UInt8) -> UInt8 {
        let midiType:UInt8 = type & 0xF0
        
        switch (type) {
            case 0xF6, 0xF8, 0xFA, 0xFB, 0xFC, 0xFF, 0xFE:
                return 1
            case 0xF1, 0xF3:
                    return 2
            default:
                break
        }
        
        switch (midiType) {
            case 0xC0, 0xD0:
                return 2
            case 0xF2, 0x80, 0x90, 0xA0, 0xB0, 0xE0:
                return 3
            default:
                break
        }
        return 0
    }
}
