/// Marker wrappers for controller parameters. The controller macro reads the
/// wrapper declaration and resolves the wrapped value from the request.
@propertyWrapper
public struct PathVariable<Value: Sendable>: Sendable {
    public var wrappedValue: Value
    public let name: String?

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
        name = nil
    }

    public init(wrappedValue: Value, name: String) {
        self.wrappedValue = wrappedValue
        self.name = name
    }
}

@propertyWrapper
public struct QueryParam<Value: Sendable>: Sendable {
    public var wrappedValue: Value
    public let name: String?

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
        name = nil
    }

    public init(wrappedValue: Value, name: String) {
        self.wrappedValue = wrappedValue
        self.name = name
    }
}

@propertyWrapper
public struct HeaderParam<Value: Sendable>: Sendable {
    public var wrappedValue: Value
    public let name: String?

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
        name = nil
    }

    public init(wrappedValue: Value, name: String) {
        self.wrappedValue = wrappedValue
        self.name = name
    }
}

@propertyWrapper
public struct RequestBody<Value: Sendable>: Sendable {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}
