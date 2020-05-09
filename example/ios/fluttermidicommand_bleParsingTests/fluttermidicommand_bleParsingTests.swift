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

//    func testPerformanceExample() throws {
//        // This is an example of a performance test case.
//        measure {
//            // Put the code you want to measure the time of here.
//        }
//    }

}
