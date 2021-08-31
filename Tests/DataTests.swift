import XCTest
import Archivable

final class DataTests: XCTestCase {
    func testPrimitives() async {
        await Data()
            .adding(UInt8(1))
            .adding(UInt16(2))
            .adding(UInt32(3))
            .adding(UInt64(4))
            .adding(true)
            .adding(false)
            .adding(Date(timeIntervalSince1970: 10))
            .adding([Date(timeIntervalSince1970: 10), .init(timeIntervalSince1970: 20)]
                        .flatMap(\.data))
            .adding(UUID())
            .wrapping(Data([1,2,3,4,5,6]))
            .compressed
            .mutating {
                await $0.decompress()
                XCTAssertEqual(1, $0.removeFirst())
                XCTAssertEqual(2, $0.uInt16())
                XCTAssertEqual(3, $0.uInt32())
                XCTAssertEqual(4, $0.uInt64())
                XCTAssertEqual(true, $0.bool())
                XCTAssertEqual(false, $0.bool())
                XCTAssertEqual(Date(timeIntervalSince1970: 10).timestamp, $0.date().timestamp)
                XCTAssertEqual(Date(timeIntervalSince1970: 10).timestamp, $0.date().timestamp)
                XCTAssertEqual(Date(timeIntervalSince1970: 20).timestamp, $0.date().timestamp)
                XCTAssertNotNil($0.uuid())
                XCTAssertEqual(Data([1,2,3,4,5,6]), $0.unwrap())
            }
    }
    
    func testPrototype() async {
        struct A: Equatable, Storable {
            let number: Int
            
            var data: Data {
                Data()
                    .adding(UInt16(number))
            }
            
            init(data: inout Data) {
                number = .init(data.uInt16())
            }
            
            init(number: Int) {
                self.number = number
            }
        }
        
        let a = await Data()
            .adding(A(number: 5).data)
            .prototype() as A
        XCTAssertEqual(A(number: 5), a)
        
        let b = await Data()
            .adding(A(number: 5).data)
            .prototype(A.self)
            .number
        XCTAssertEqual(5, b)
    }
}
