//
//  fluttermidicommand_bleParsingTests.swift
//  fluttermidicommand_bleParsingTests
//
//  Created by Morten Mortensen on 09/05/2020.
//

import XCTest
import flutter_midi_command

class fluttermidicommand_bleParsingTests: XCTestCase {
    
    var plugin: SwiftFlutterMidiCommandPlugin?

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        plugin = SwiftFlutterMidiCommandPlugin()
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        plugin = nil
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        
        let packet = Data([ 0x80, 0x80, 0xB1, 0x00, 0x1F])
        plugin!.parseBLEPacket(packet)
//        let call = FlutterMethodCall( methodName: "parseBlePacket", arguments: packet )
//        plugin!.handle( call, result: {(result)->Void in
//            if let strResult = result as? String {
//                XCTAssertEqual( "iOS 12.4", strResult )
//            }
//            else {
//                XCTFail("Unexpected type expected: String")
//            }
//        })
    }
    
    func testPCParsing() throws {
        let packet = Data([ 0x80, 0x80, 0xC1, 0x7F])
        plugin!.parseBLEPacket(packet)
    }
    
    func testMultiParsing() throws {
        let packet = Data([ 0x80, 0x80, 0xB1, 0x00, 0x1F, 0xB1, 0x00, 0x1F, 0xB1, 0x00, 0x1F])
        plugin!.parseBLEPacket(packet)
    }
    
    func testRTClockParsing() throws {
        let packet = Data([ 0x80, 0x80, 0xF8])
        plugin!.parseBLEPacket(packet)
    }
    
    func testRTStartParsing() throws {
        let packet = Data([ 0x80, 0x80, 0xFA])
        plugin!.parseBLEPacket(packet)
    }
    
    func testRTContinueParsing() throws {
        let packet = Data([ 0x80, 0x80, 0xFB])
        plugin!.parseBLEPacket(packet)
    }
    
    func testRTStopParsing() throws {
        let packet = Data([ 0x80, 0x80, 0xFC])
        plugin!.parseBLEPacket(packet)
    }
    
    func testMultiRTParsing() throws {
        let packet = Data([ 0x80, 0x80, 0xFC, 0xFA, 0xFB, 0xFC])
        plugin!.parseBLEPacket(packet)
    }
    
    func testNRPNParsing() throws {
           let packet = Data([ 0x80, 0x80,
                               0xB1, 0x63, 0x36, // Param MSB
                               0xB1, 0x62, 0x01, // Param LSB
                               0xB1, 0x06, 0x04 // Value MSB
           ])
           plugin!.parseBLEPacket(packet)
       }
    
    func testSysexParsing() throws {
              let packet = Data([ 0x80, 0x80, 0xF0, 0x7D, 0x5B, 0x7B, 0x22, 0x6E, 0x61, 0x6D, 0x65, 0x22, 0x3A, 0x22, 0x54, 0x61, 0x69, 0x6E, 0x5D, 0xF7
              ])
              plugin!.parseBLEPacket(packet)
          }

    
    func testMultiSysexParsing() throws {
        let packet1 = Data([ 0x80, 0x80, 0x10, 0x7D, 0x5B, 0x7B, 0x22, 0x6E, 0x61, 0x6D, 0x65, 0x22, 0x3A, 0x22, 0x54, 0x61, 0x69, 0x6E, 0x5D, 0x10
        ])
        plugin!.parseBLEPacket(packet1)
        
        let packet2 = Data([ 0x80, 0x80, 0x20, 0x7D, 0x5B, 0x7B, 0x22, 0x6E, 0x61, 0x6D, 0x65, 0x22, 0x3A, 0x22, 0x54, 0x61, 0x69, 0x6E, 0x5D, 0x20
        ])
        plugin!.parseBLEPacket(packet2)
        
        let packet3 = Data([ 0x80, 0x80, 0x30, 0x7D, 0x5B, 0x7B, 0x22, 0x6E, 0x61, 0x6D, 0x65, 0x22, 0x3A, 0x22, 0x54, 0x61, 0x69, 0x6E, 0x5D, 0x30
        ])
        plugin!.parseBLEPacket(packet3)
        
        let packet4 = Data([ 0x80, 0x80, 0x40, 0x7D, 0x5B, 0x7B, 0x22, 0x6E, 0x61, 0x6D, 0x65, 0x22, 0x3A, 0x22, 0x54, 0x61, 0x69, 0x6E, 0x5D, 0xF7
        ])
        plugin!.parseBLEPacket(packet4)
    }

//    func testPerformanceExample() throws {
//        // This is an example of a performance test case.
//        measure {
//            // Put the code you want to measure the time of here.
//        }
//    }

}
