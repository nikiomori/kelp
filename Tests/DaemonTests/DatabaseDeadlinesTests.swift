import Core
import Foundation
import Testing

@testable import Daemon

// MARK: What a call waits, what's said of one past its time, what's promised

/// A call that waits on database work waits longer than the work can take, added up from the times kelpd gives each
/// part: else the tab says "timed out" of a change kelpd still commits, and a second Save makes it twice.
@Test func aDatabaseCallWaitsLongerThanItsWork() throws {
    let slack = DatabaseTimes.slack, read = DatabaseEngines.readTimeout, write = DatabaseEngines.writeTimeout
    // One connection's call of `seconds`, each way it's reached
    func worst(_ seconds: TimeInterval) -> TimeInterval {
        let mysql = MySQLWire.handshakeTimeout + seconds + slack + 2 * MySQLWire.killTimeout
        let postgres = DatabaseTimes.connect + seconds + slack
        let container = DatabaseTimes.compose + seconds + 10   // psql's run: its time and 10 s
        return max(mysql, postgres, container)
    }
    let reach = DatabaseTimes.reach
    #expect(try #require(DatabaseApply.timeout) > reach + worst(write))
    // The tables, the version, the databases: a connection each
    #expect(try #require(DatabaseCheck.timeout) > reach + 3 * worst(read))
    // MySQL's client: whether it can roll back (a read's time and 5 s), then the trial
    let trial = max(worst(read + 5) + worst(DatabaseTimes.trial), worst(2 * read))
    let agentsChange =
        reach + worst(DatabaseTimes.superuser) + worst(DatabaseTimes.longestRead) + trial + DatabaseQuery.answerWithin
        + worst(write)
    #expect(try #require(DatabaseQuery.timeout) > agentsChange)
}

/// A MySQL call past its time that KILL QUERY stopped may have finished first: what's said doesn't tell the user a
/// rerun is safe.
@Test func aStoppedMySQLCallSaysToLookFirst() {
    for stopped in [true, false] {
        #expect(
            MySQLWire.late("No answer from app in 310 s.", stopped: stopped).hasSuffix("look before running it again."))
    }
}

/// A change held to the rows its trial changed is asked as that many; Appwrite's, which can't be held, says the number
/// is the trial's, not that it's what will change. Every other way holds it, through a client too.
@Test func aChangeNotHeldToItsRowsDoesNotPromiseThem() {
    let held = Databases.question("UPDATE orders SET a = 1", database: "app", changed: 2)
    #expect(held == "Allow changing 2 rows of orders in app?")
    let unheld = Databases.question("UPDATE orders SET a = 1", database: "app", changed: 2, held: false)
    #expect(unheld == "Allow changing rows of orders in app? Tried just now, it changed 2 rows.")
    func holds(_ engine: DatabaseInfo.Engine, host: String?) -> Bool {
        let c = DatabaseConnection(database: DatabaseInfo(name: "app", engine: engine, host: host))
        return DatabaseEngines.runner(c, off: Slots(1)).holdsAllowed
    }
    for engine in DatabaseInfo.Engine.allCases where engine != .appwrite {
        #expect(holds(engine, host: nil) && holds(engine, host: "localhost"), "\(engine)")
    }
    #expect(!holds(.appwrite, host: "https://appwrite.example.com"))
}
