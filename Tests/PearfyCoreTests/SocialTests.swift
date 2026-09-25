import Foundation
import PearfyData
import PearfySocial
import Testing

@Test func socialActorNormalizesHandleAndUsesUUIDv7Default() throws {
    let actor = try SocialActor(ownerID: UUIDv7.generate(), kind: .person, handle: "Alice.Dev")
    #expect(actor.handle == "alice.dev")
    #expect(UUIDv7.timestampMilliseconds(from: actor.id) != nil)
    #expect(actor.visibility == .public)
}

@Test func socialActorRejectsUnsafeHandles() throws {
    var invalidHandleRejected = false
    do {
        _ = try SocialActor(ownerID: UUIDv7.generate(), kind: .person, handle: "../Alice")
    } catch SocialGraphError.invalidHandle {
        invalidHandleRejected = true
    }
    #expect(invalidHandleRejected)
}

@Test func socialActorDecodingReappliesHandleValidation() throws {
    let validPayload = #"{"id":"00000000-0000-0000-0000-000000000001","ownerID":"00000000-0000-0000-0000-000000000002","kind":"person","handle":"Alice.Dev","visibility":"public"}"#
    let actor = try JSONDecoder().decode(SocialActor.self, from: Data(validPayload.utf8))
    #expect(actor.handle == "alice.dev")

    let invalidPayload = validPayload.replacingOccurrences(of: "Alice.Dev", with: "../Alice")
    var invalidHandleRejected = false
    do {
        _ = try JSONDecoder().decode(SocialActor.self, from: Data(invalidPayload.utf8))
    } catch DecodingError.dataCorrupted {
        invalidHandleRejected = true
    }
    #expect(invalidHandleRejected)
}
