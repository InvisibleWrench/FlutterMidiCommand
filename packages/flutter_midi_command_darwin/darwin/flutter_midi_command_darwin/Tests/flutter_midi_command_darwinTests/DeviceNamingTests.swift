import XCTest
@testable import flutter_midi_command_darwin

/// The naming rules `getDevices()` and a connected device share. Both call
/// `nativeEntityDisplayName`, which cannot be exercised directly because a
/// CoreMIDI device/entity/endpoint tree can only be fabricated by mutating the
/// machine's MIDI setup, so the decision itself lives in
/// `resolveNativeEntityName` and is tested here on the names CoreMIDI would
/// have returned.
final class DeviceNamingTests: XCTestCase {

    /// `nil` is an entity without endpoints; "Error" is what `getMIDIProperty`
    /// returns for a property it could not read.
    private func resolve(
        endpoint: String?,
        entity: String,
        device: String,
        isBluetoothPeripheral: Bool = false
    ) -> String {
        return SwiftFlutterMidiCommandPlugin.resolveNativeEntityName(
            endpointDisplayName: endpoint,
            entityName: entity,
            deviceName: device,
            isBluetoothPeripheral: isBluetoothPeripheral
        )
    }

    // MARK: - Native entities

    /// The observed tree for a Roland A-88MK2: the entity is an anonymous
    /// "Port 1", and only the endpoint qualifies it with the device name.
    func testPrefersTheEndpointDisplayName() {
        XCTAssertEqual(
            resolve(endpoint: "A-88MK2 Port 1", entity: "Port 1", device: "A-88MK2"),
            "A-88MK2 Port 1"
        )
    }

    func testFallsBackToTheEntityNameWhenTheEndpointHasNoDisplayName() {
        XCTAssertEqual(resolve(endpoint: "Error", entity: "Port 1", device: "A-88MK2"), "Port 1")
    }

    func testFallsBackToTheEntityNameWhenTheDisplayNameIsEmpty() {
        XCTAssertEqual(resolve(endpoint: "", entity: "Port 1", device: "A-88MK2"), "Port 1")
    }

    func testFallsBackToTheEntityNameWhenTheEntityHasNoEndpoints() {
        XCTAssertEqual(resolve(endpoint: nil, entity: "Port 1", device: "A-88MK2"), "Port 1")
    }

    func testFallsBackToTheDeviceNameWhenTheEntityIsUnnamed() {
        XCTAssertEqual(resolve(endpoint: nil, entity: "", device: "A-88MK2"), "A-88MK2")
        XCTAssertEqual(resolve(endpoint: "Error", entity: "Error", device: "A-88MK2"), "A-88MK2")
    }

    /// Nothing readable anywhere leaves the unreadable device name in place,
    /// which is what this has always surfaced. Pinned so that a device named
    /// "Error" in the list is traceable to a property read that failed.
    func testReturnsTheDeviceNameWhenNothingIsReadable() {
        XCTAssertEqual(resolve(endpoint: "Error", entity: "Error", device: "Error"), "Error")
    }

    // MARK: - BLE MIDI peripherals

    /// The OS BLE driver names the entity, and so the endpoint display name,
    /// after the transport; only the device carries the advertised name. This
    /// is the case `getDevices()` special-cased while a connected device did
    /// not, so the same peripheral was listed as "WIDI Bud Pro" and then
    /// reported itself as "Bluetooth" on every packet it delivered.
    func testPrefersTheDeviceNameForABluetoothPeripheral() {
        XCTAssertEqual(
            resolve(endpoint: "Bluetooth", entity: "Bluetooth", device: "WIDI Bud Pro", isBluetoothPeripheral: true),
            "WIDI Bud Pro"
        )
    }

    func testFallsBackToTheEndpointNameWhenABluetoothDeviceIsUnnamed() {
        XCTAssertEqual(
            resolve(endpoint: "Bluetooth", entity: "Error", device: "Error", isBluetoothPeripheral: true),
            "Bluetooth"
        )
    }

    func testFallsBackToTheEntityNameWhenABluetoothDeviceAndEndpointAreUnnamed() {
        XCTAssertEqual(
            resolve(endpoint: nil, entity: "Bluetooth", device: "", isBluetoothPeripheral: true),
            "Bluetooth"
        )
    }

    /// The device name wins only for a BLE peripheral; a USB entity keeps the
    /// endpoint display name it was listed under.
    func testDoesNotPreferTheDeviceNameForANativeEntity() {
        XCTAssertEqual(
            resolve(endpoint: "A-88MK2 Port 1", entity: "Port 1", device: "A-88MK2", isBluetoothPeripheral: false),
            "A-88MK2 Port 1"
        )
    }

    // MARK: - Port suffixes

    private func portName(_ baseName: String, portIndex: Int, logicalPortCount: Int) -> String {
        return SwiftFlutterMidiCommandPlugin.nativePortDisplayName(
            baseName: baseName,
            portIndex: portIndex,
            logicalPortCount: logicalPortCount
        )
    }

    /// An A-88MK2 port is its own entity with one endpoint, so it keeps the
    /// endpoint display name unsuffixed.
    func testLeavesASinglePortEntityUnsuffixed() {
        XCTAssertEqual(portName("A-88MK2 Port 1", portIndex: 0, logicalPortCount: 1), "A-88MK2 Port 1")
    }

    /// An entity exposing several sources or destinations is listed once per
    /// port, numbered from 1 to match how the OS counts ports.
    func testNumbersThePortsOfAMultiPortEntity() {
        XCTAssertEqual(portName("Digiface Dante", portIndex: 0, logicalPortCount: 4), "Digiface Dante [1]")
        XCTAssertEqual(portName("Digiface Dante", portIndex: 3, logicalPortCount: 4), "Digiface Dante [4]")
    }
}
