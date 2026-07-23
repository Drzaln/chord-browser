# 001 — GRDB over Core Data

**Status:** accepted (M1)

BROWSER_SPEC 2 leaves the persistence choice open and asks for a justification.
Section 7.2 then sets requirements that are much harder to satisfy than "store
some rows": migrations must be sequential, forward-only, individually named, and
each must have a test that runs it against a fixture database captured from the
previous version, kept in the repo permanently.

GRDB's `DatabaseMigrator` is that model directly. A migration is a named
function; a fixture is an ordinary `.sqlite` file that a test opens. Core Data's
model-version and mapping-model flow does not produce a per-step artifact you can
test the same way, and its lightweight migration is implicit — inference happens
inside the framework, in the one subsystem where 3.7 says a bug costs the user
data rather than a reload. Being able to read the migration and the test side by
side is worth more here than anything Core Data offers.

Two supporting reasons. 7.2 already forbids persisting `Codable` app models
directly, so Core Data's managed-object-as-model convenience is ruled out by the
spec — row types and mappers get written either way, which erases the difference
in boilerplate. And 6.5 requires history and tab writes on a serial background
queue; `DatabaseQueue` is exactly that, with `Sendable` conformances that satisfy
Swift 6 strict concurrency, where `NSManagedObjectContext` thread confinement
remains awkward to express.

The cost is one third-party dependency, pinned to an exact version (7.7.1) as
7.6 requires. That is the only dependency in the project.
