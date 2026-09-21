import Testing
@testable import Toolkit

// The attribute graph: what runs again, and what does not.
//
// The whole point of the graph is the second one. A test that only checked
// the values would pass with a graph that works everything out every time,
// which is what the toolkit did before. So every test here counts the rules
// that ran.

@Suite("The attribute graph")
struct GraphTests {
    @Test("A rule runs when its value is asked for, and not before")
    func aRuleIsLazy() {
        let graph = Graph()
        let rule = graph.rule { _ in 42 }
        #expect(graph.evaluations == 0)
        #expect(graph.value(of: rule) == 42)
        #expect(graph.evaluations == 1)
    }

    @Test("A value that nothing spoiled is not worked out again")
    func aCleanValueStays() {
        let graph = Graph()
        let rule = graph.rule { _ in 42 }
        _ = graph.value(of: rule)
        _ = graph.value(of: rule)
        _ = graph.value(of: rule)
        #expect(graph.evaluations == 1)
    }

    @Test("A rule that reads a source runs again after the source changes")
    func aChangeSpoilsTheReader() {
        let graph = Graph()
        let width = graph.source(10.0)
        let doubled = graph.rule { $0.value(of: width) * 2 }
        #expect(graph.value(of: doubled) == 20)

        graph.set(width, to: 30)
        #expect(graph.value(of: doubled) == 60)
        #expect(graph.evaluations == 2)
    }

    @Test("A change reaches everything downstream of it")
    func aChangeGoesAllTheWay() {
        let graph = Graph()
        let source = graph.source(1)
        let middle = graph.rule { $0.value(of: source) + 1 }
        let top = graph.rule { $0.value(of: middle) * 10 }
        #expect(graph.value(of: top) == 20)

        graph.set(source, to: 4)
        #expect(graph.value(of: top) == 50)
    }

    @Test("A change to one source leaves the rules that did not read it")
    func aChangeLeavesTheRest() {
        let graph = Graph()
        let left = graph.source(1)
        let right = graph.source(100)
        let fromLeft = graph.rule { $0.value(of: left) }
        let fromRight = graph.rule { $0.value(of: right) }
        _ = graph.value(of: fromLeft)
        _ = graph.value(of: fromRight)
        let before = graph.evaluations

        graph.set(left, to: 2)
        _ = graph.value(of: fromLeft)
        _ = graph.value(of: fromRight)
        // Only the rule that read the left source ran again.
        #expect(graph.evaluations == before + 1)
    }

    @Test("A rule depends on what it read this time, not on what it read once")
    func dependenciesFollowTheRun() {
        let graph = Graph()
        let takeLeft = graph.source(true)
        let left = graph.source(1)
        let right = graph.source(2)
        let choice = graph.rule { graph in
            graph.value(of: takeLeft) ? graph.value(of: left) : graph.value(of: right)
        }
        #expect(graph.value(of: choice) == 1)

        // It reads the right source now, so the left one is nothing to it.
        graph.set(takeLeft, to: false)
        #expect(graph.value(of: choice) == 2)
        let after = graph.evaluations
        graph.set(left, to: 99)
        #expect(graph.value(of: choice) == 2)
        #expect(graph.evaluations == after, "a source it no longer reads spoiled it")
    }

    @Test("A value that two rules read is worked out one time")
    func aSharedValueIsWorkedOutOnce() {
        let graph = Graph()
        let shared = graph.rule { _ in 7 }
        let first = graph.rule { $0.value(of: shared) + 1 }
        let second = graph.rule { $0.value(of: shared) + 2 }
        #expect(graph.value(of: first) == 8)
        #expect(graph.value(of: second) == 9)
        // Three rules ran: the two above and the one they share.
        #expect(graph.evaluations == 3)
    }

    @Test("An attribute that is forgotten leaves no edge behind")
    func forgettingRemovesTheEdges() {
        let graph = Graph()
        let source = graph.source(1)
        let reader = graph.rule { $0.value(of: source) }
        _ = graph.value(of: reader)
        #expect(graph.count == 2)

        graph.forget(reader)
        #expect(graph.count == 1)
        // The source no longer has anything to spoil.
        graph.set(source, to: 2)
        #expect(graph.evaluations == 1)
    }
}

@Suite("The move that a change belongs to")
struct GraphAnimationTests {
    @Test("A change with a move puts that move in the air for what it spoils")
    func theMoveReachesTheRule() {
        let graph = Graph()
        let source = graph.source(0.0)
        final class Seen: @unchecked Sendable { var animation: Animation? }
        let seen = Seen()
        let reader = graph.rule { graph -> Double in
            seen.animation = graph.animation
            return graph.value(of: source)
        }
        _ = graph.value(of: reader)
        #expect(seen.animation == nil)

        graph.set(source, to: 1, animation: .linear(duration: 1))
        _ = graph.value(of: reader)
        #expect(seen.animation == .linear(duration: 1))
    }

    @Test("The move reaches a rule that the spoiled rule reads")
    func theMoveGoesDownTheTree() {
        let graph = Graph()
        let source = graph.source(0.0)
        let other = graph.source(0.0)
        final class Seen: @unchecked Sendable { var animation: Animation? }
        let seen = Seen()
        // This rule is out of date for a reason of its own, and it carries
        // no move. It must still run inside the move of the rule above it.
        let leaf = graph.rule { graph -> Double in
            seen.animation = graph.animation
            return graph.value(of: other)
        }
        let top = graph.rule { graph in graph.value(of: source) + graph.value(of: leaf) }
        _ = graph.value(of: top)
        seen.animation = nil

        graph.set(other, to: 1)
        graph.set(source, to: 5, animation: .linear(duration: 1))
        _ = graph.value(of: top)
        #expect(seen.animation == .linear(duration: 1))
    }

    @Test("A rule that is not spoiled does not run inside a move")
    func aCleanRuleStaysOutOfTheMove() {
        let graph = Graph()
        let source = graph.source(0.0)
        final class Count: @unchecked Sendable { var runs = 0 }
        let count = Count()
        let leaf = graph.rule { _ -> Double in
            count.runs += 1
            return 1
        }
        let top = graph.rule { graph in graph.value(of: source) + graph.value(of: leaf) }
        _ = graph.value(of: top)
        #expect(count.runs == 1)

        graph.set(source, to: 5, animation: .linear(duration: 1))
        _ = graph.value(of: top)
        #expect(count.runs == 1, "a value that nothing changed was worked out again")
    }

    @Test("A move is over when the rule has run")
    func theMoveDoesNotStay() {
        let graph = Graph()
        let source = graph.source(0.0)
        final class Seen: @unchecked Sendable { var animation: Animation? }
        let seen = Seen()
        let reader = graph.rule { graph -> Double in
            seen.animation = graph.animation
            return graph.value(of: source)
        }
        graph.set(source, to: 1, animation: .linear(duration: 1))
        _ = graph.value(of: reader)
        graph.set(source, to: 2)
        _ = graph.value(of: reader)
        #expect(seen.animation == nil)
    }

    @Test("A move that a view names is in the air for the values inside it")
    func animatingPutsAMoveInTheAir() {
        let graph = Graph()
        var seen: Animation?
        graph.animating(.easeOut(duration: 0.5)) {
            seen = graph.animation
        }
        #expect(seen == .easeOut(duration: 0.5))
        #expect(graph.animation == nil, "the move outlasted its closure")
    }
}
