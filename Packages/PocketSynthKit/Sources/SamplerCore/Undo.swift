/// Undo history for the sampler (SAMPLER_SPEC §6, DESIGN §5.3).
///
/// The project is a small value type (pads, sequences, mixer: tens of KB), so each step
/// stores the state from before the edit instead of an apply/revert command pair. That
/// makes every edit undoable by construction. Repeated edits with the same coalescing key
/// (a slider drag) within `coalesceWindow` seconds merge into one step.
public struct UndoHistory<State: Sendable>: Sendable {
    public struct Entry: Sendable {
        public var label: String
        public var state: State
        var key: String?
        var time: Double
    }

    public static var limit: Int { 200 }
    public static var coalesceWindow: Double { 1.0 }

    public private(set) var undoStack: [Entry] = []
    public private(set) var redoStack: [Entry] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    /// Records `before` as the state to return to.
    public mutating func record(_ before: State, label: String, key: String? = nil, at time: Double) {
        redoStack.removeAll()
        if let key, let last = undoStack.last, last.key == key, time - last.time < Self.coalesceWindow {
            undoStack[undoStack.count - 1].time = time // keep the oldest state, extend the window
            return
        }
        undoStack.append(Entry(label: label, state: before, key: key, time: time))
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
    }

    /// Returns the state to restore, given the current one (which becomes redoable).
    public mutating func undo(current: State) -> State? {
        guard let e = undoStack.popLast() else { return nil }
        redoStack.append(Entry(label: e.label, state: current, key: nil, time: 0))
        return e.state
    }

    public mutating func redo(current: State) -> State? {
        guard let e = redoStack.popLast() else { return nil }
        undoStack.append(Entry(label: e.label, state: current, key: nil, time: 0))
        return e.state
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
