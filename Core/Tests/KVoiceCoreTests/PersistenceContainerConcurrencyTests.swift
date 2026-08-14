import Foundation
import SwiftData
import Testing

@testable import KVoiceCore

/// Pins the contract of ``TestContainer``'s creation lock.
///
/// The lock exists because two suite runs died with `SIGSEGV` inside CoreData's
/// store setup — `addPersistentStore → createTablesForEntities →
/// _generateTriggerSQL → -[__NSDictionaryM setObject:forKey:]` — which is
/// CoreData compiling the model into SQL while mutating shared state, with
/// ~35 parallel tests each minting a container. See `PersistenceTestSupport`.
///
/// **What this test does and does not prove.** It does not reproduce that
/// crash: the race is rare and load-sensitive, and 24 concurrent creations in a
/// warm process do not trigger it (they did not before the lock existed
/// either). What it does prove is that the fix is sound in both directions —
/// creation under contention still terminates (no deadlock, no lock inversion
/// against the actors that build containers) and still yields *isolated*
/// stores, which is the property a careless "share one container" fix would
/// quietly destroy.
@Suite("Model container creation under contention")
struct ModelContainerConcurrencyTests {

    @Test("many containers minted at once stay separate stores")
    func concurrentCreation() async throws {
        let count = 24

        let containers = try await withThrowingTaskGroup(of: ModelContainer.self) { group in
            for _ in 0..<count {
                group.addTask { try TestContainer.inMemory() }
            }
            var made: [ModelContainer] = []
            for try await container in group { made.append(container) }
            return made
        }

        #expect(containers.count == count)

        // One insert each: if the lock had collapsed them onto one store, the
        // last container would see 24 recordings rather than its own.
        for container in containers {
            let context = ModelContext(container)
            context.insert(Recording(title: "R", folderName: "R", audioFileName: "R.m4a"))
            try context.save()
            #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
        }
    }
}
