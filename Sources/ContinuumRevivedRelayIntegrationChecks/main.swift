import Foundation
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

do { try await runRelayHTTPNotificationChecks() }
catch { print("FAIL relay HTTP notification behavior: \(error)"); exit(1) }
do { try await runRelayHTTPOutboxChecks() }
catch { print("FAIL relay HTTP outbox behavior: \(error)"); exit(1) }
do { try await runRelayTaskOwnershipChecks() }
catch { print("FAIL relay task ownership: \(error)"); exit(1) }
