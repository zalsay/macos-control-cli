import Foundation

@main struct Main {
    static func main() {
        let a = NSObject(), b = NSObject(), wrong = NSObject()
        var c = NavigationCorrelation()
        let e = c.begin(a)
        precondition(!c.matches(b, epoch: e) && c.matches(a, epoch: e))
        precondition(!c.noteFinished(wrong, epoch: e))
        precondition(!c.noteFinished(a, epoch: e + 1))
        precondition(c.reserveContinuation(parent: a, epoch: e) == nil)
        precondition(c.noteFinished(a, epoch: e))
        precondition(c.reserveContinuation(parent: wrong, epoch: e) == nil)
        precondition(c.reserveContinuation(parent: a, epoch: e + 1) == nil)
        guard let ticket = c.reserveContinuation(parent: a, epoch: e) else { fatalError("reservation") }
        precondition(c.hasPendingContinuation)
        precondition(c.reserveContinuation(parent: a, epoch: e) == nil)
        precondition(!c.finish(a, epoch: e))
        precondition(c.adoptContinuation(b, ticket: UUID(), parent: a, epoch: e) == nil)
        precondition(c.adoptContinuation(b, ticket: ticket, parent: wrong, epoch: e) == nil)
        precondition(c.adoptContinuation(b, ticket: ticket, parent: a, epoch: e + 1) == nil)
        precondition(c.adoptContinuation(a, ticket: ticket, parent: a, epoch: e) == nil)
        precondition(c.hasPendingContinuation)
        guard let e2 = c.adoptContinuation(b, ticket: ticket, parent: a, epoch: e) else { fatalError("adopt") }
        precondition(e2 != e && c.matches(b, epoch: e2) && !c.matches(a, epoch: e))
        precondition(c.isRetired(a) && !c.isRetired(b) && !c.hasPendingContinuation)
        precondition(!c.finish(a, epoch: e))
        precondition(c.adoptContinuation(wrong, ticket: ticket, parent: a, epoch: e) == nil)
        precondition(c.reserveContinuation(parent: b, epoch: e2) == nil)
        precondition(c.noteFinished(b, epoch: e2))
        guard let ticket2 = c.reserveContinuation(parent: b, epoch: e2) else { fatalError("second reservation") }
        precondition(c.adoptContinuation(a, ticket: ticket2, parent: b, epoch: e2) == nil)
        let child = NSObject()
        guard let e3 = c.adoptContinuation(child, ticket: ticket2, parent: b, epoch: e2) else { fatalError("second adopt") }
        precondition(c.isRetired(a) && c.isRetired(b))
        precondition(c.finish(child, epoch: e3))
        precondition(c.isRetired(a) && c.isRetired(b))
        precondition(!c.finish(child, epoch: e3))

        var bounded = NavigationCorrelation()
        var parent: NSObject = NSObject()
        let firstParent = parent
        var generation = bounded.begin(parent)
        for _ in 0..<8 {
            precondition(bounded.noteFinished(parent, epoch: generation))
            guard let t = bounded.reserveContinuation(parent: parent, epoch: generation) else { fatalError("within limit") }
            let next = NSObject()
            guard let nextEpoch = bounded.adoptContinuation(next, ticket: t, parent: parent, epoch: generation) else { fatalError("within limit adopt") }
            parent = next; generation = nextEpoch
        }
        precondition(bounded.noteFinished(parent, epoch: generation))
        precondition(bounded.reserveContinuation(parent: parent, epoch: generation) == nil)
        precondition(bounded.finish(parent, epoch: generation))
        precondition(bounded.isRetired(firstParent))
        let fresh = NSObject()
        let freshEpoch = bounded.begin(fresh)
        precondition(!bounded.isRetired(firstParent))
        precondition(bounded.noteFinished(fresh, epoch: freshEpoch))
        guard let pending = bounded.reserveContinuation(parent: fresh, epoch: freshEpoch) else { fatalError("fresh root") }
        bounded.invalidate()
        precondition(!bounded.hasPendingContinuation && !bounded.matches(fresh, epoch: freshEpoch))
        precondition(bounded.adoptContinuation(NSObject(), ticket: pending, parent: fresh, epoch: freshEpoch) == nil)

        var retained = NavigationCorrelation()
        weak var weakRoot: NSObject?
        var strongRoot: NSObject? = NSObject()
        weakRoot = strongRoot
        let rootEpoch = retained.begin(strongRoot!)
        strongRoot = nil
        precondition(weakRoot != nil)
        precondition(retained.noteFinished(weakRoot!, epoch: rootEpoch))
        let t = retained.reserveContinuation(parent: weakRoot!, epoch: rootEpoch)!
        let next = NSObject()
        let nextEpoch = retained.adoptContinuation(next, ticket: t, parent: weakRoot!, epoch: rootEpoch)!
        precondition(weakRoot != nil && retained.isRetired(weakRoot!))
        precondition(retained.finish(next, epoch: nextEpoch) && weakRoot != nil)
        retained.invalidate()
        precondition(weakRoot == nil)

        // A provisional continuation must descend from a real finished parent.
        var provisional = NavigationCorrelation()
        let root = NSObject(), child1 = NSObject(), child2 = NSObject(), outsider = NSObject()
        let rootGeneration = provisional.begin(root)
        precondition(!provisional.isUncommittedContinuation(root, epoch: rootGeneration))
        precondition(provisional.reserveProvisionalContinuation(parent: root, epoch: rootGeneration) == nil)
        precondition(provisional.noteFinished(root, epoch: rootGeneration))
        let finishedTicket = provisional.reserveContinuation(parent: root, epoch: rootGeneration)!
        precondition(!provisional.confirmProvisionalContinuation(ticket: finishedTicket, parent: root, epoch: rootGeneration))
        let childGeneration = provisional.adoptContinuation(child1, ticket: finishedTicket, parent: root, epoch: rootGeneration)!
        precondition(provisional.isUncommittedContinuation(child1, epoch: childGeneration))
        let provisionalTicket = provisional.reserveProvisionalContinuation(parent: child1, epoch: childGeneration)!
        precondition(!provisional.confirmProvisionalContinuation(ticket: UUID(), parent: child1, epoch: childGeneration))
        precondition(!provisional.confirmProvisionalContinuation(ticket: provisionalTicket, parent: outsider, epoch: childGeneration))
        precondition(!provisional.confirmProvisionalContinuation(ticket: provisionalTicket, parent: child1, epoch: childGeneration + 1))
        precondition(!provisional.noteCommitted(child1, epoch: childGeneration))
        precondition(provisional.hasPendingContinuation)
        precondition(provisional.confirmProvisionalContinuation(ticket: provisionalTicket, parent: child1, epoch: childGeneration))
        precondition(provisional.matches(child1, epoch: childGeneration) && !provisional.hasPendingContinuation)
        precondition(provisional.noteCommitted(child1, epoch: childGeneration))
        precondition(!provisional.isUncommittedContinuation(child1, epoch: childGeneration))
        precondition(provisional.reserveProvisionalContinuation(parent: child1, epoch: childGeneration) == nil)

        // A provisional ticket may instead adopt a different native child.
        var chain = NavigationCorrelation()
        let eRoot = chain.begin(root)
        precondition(chain.noteFinished(root, epoch: eRoot))
        let tRoot = chain.reserveContinuation(parent: root, epoch: eRoot)!
        let eChild = chain.adoptContinuation(child1, ticket: tRoot, parent: root, epoch: eRoot)!
        let tChild = chain.reserveProvisionalContinuation(parent: child1, epoch: eChild)!
        precondition(chain.adoptContinuation(root, ticket: tChild, parent: child1, epoch: eChild) == nil)
        precondition(chain.adoptContinuation(child1, ticket: tChild, parent: child1, epoch: eChild) == nil)
        precondition(chain.hasPendingContinuation)
        let eNext = chain.adoptContinuation(child2, ticket: tChild, parent: child1, epoch: eChild)!
        precondition(chain.isRetired(root) && chain.isRetired(child1))
        precondition(!chain.matches(child1, epoch: eChild) && chain.matches(child2, epoch: eNext))
        precondition(!chain.confirmProvisionalContinuation(ticket: tChild, parent: child1, epoch: eChild))
        chain.invalidate()
        precondition(!chain.isRetired(root) && !chain.isUncommittedContinuation(child2, epoch: eNext))
        print("navigation correlation: PASS")
    }
}
