import ExtrasBase64
import Foundation
import NIO

/// `BSONEncoder` facilitates the encoding of `Encodable` values into BSON.
public class BSONEncoder {
    /**
     * Enum representing the various strategies for encoding `Date`s.
     *
     * As per the BSON specification, the default strategy is to encode `Date`s as BSON datetime objects.
     *
     * - SeeAlso: bsonspec.org
     */
    public enum DateEncodingStrategy {
        /// Encode the `Date` by deferring to its default encoding implementation.
        case deferredToDate

        /// Encode the `Date` as a BSON datetime object (default).
        /// Throws an `EncodingError` if the `Date` is further away from January 1, 1970 than can be represented
        /// by a 64-bit signed integer of milliseconds.
        case bsonDateTime

        /// Encode the `Date` as a 64-bit integer counting the number of milliseconds since January 1, 1970.
        /// Throws an `EncodingError` if the `Date` is too far away from then to be represented this way.
        case millisecondsSince1970

        /// Encode the `Date` as a BSON double counting the number of seconds since January 1, 1970.
        case secondsSince1970

        /// Encode the `Date` as an ISO-8601-formatted string (in RFC 339 format).
        case iso8601

        /// Encode the `Date` as a string formatted by the given formatter.
        case formatted(DateFormatter)

        /// Encode the `Date` by using the given closure.
        /// If the closure does not encode a value, an empty document will be encoded in its place.
        case custom((Date, Encoder) throws -> Void)
    }

    /**
     * Enum representing the various strategies for encoding `UUID`s.
     *
     * As per the BSON specification, the default strategy is to encode `UUID`s as BSON binary types with the UUID
     * subtype.
     *
     * - SeeAlso: bsonspec.org
     */
    public enum UUIDEncodingStrategy {
        /// Encode the `UUID` by deferring to its default encoding implementation.
        case deferredToUUID

        /// Encode the `UUID` as a BSON binary type (default).
        case binary
    }

    /**
     * Enum representing the various strategies for encoding `Data`s.
     *
     * As per the BSON specification, the default strategy is to encode `Data`s as BSON binary types with the generic
     * binary subtype.
     *
     * - SeeAlso: bsonspec.org
     */
    public enum DataEncodingStrategy {
        /**
         * Encode the `Data` by deferring to its default encoding implementation.
         *
         * Note: The default encoding implementation attempts to encode the `Data` as a `[UInt8]`, but because BSON
         * does not support integer types besides `Int32` or `Int64`, it actually gets encoded to BSON as an `[Int32]`.
         * This results in a space inefficient storage of the `Data` (using 4 bytes of BSON storage per byte of data).
         */
        case deferredToData

        /// Encode the `Data` as a BSON binary type (default).
        case binary

        /// Encode the `Data` as a base64 encoded string.
        case base64

        /// Encode the `Data` by using the given closure.
        /// If the closure does not encode a value, an empty document will be encoded in its place.
        case custom((Data, Encoder) throws -> Void)
    }

    /// The strategy to use for encoding `Date`s with this instance.
    public var dateEncodingStrategy: DateEncodingStrategy = .bsonDateTime

    /// The strategy to use for encoding `UUID`s with this instance.
    public var uuidEncodingStrategy: UUIDEncodingStrategy = .binary

    /// The strategy to use for encoding `Data`s with this instance.
    public var dataEncodingStrategy: DataEncodingStrategy = .binary

    /// Contextual user-provided information for use during encoding.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// Options set on the top-level encoder to pass down the encoding hierarchy.
    fileprivate struct _Options {
        let userInfo: [CodingUserInfoKey: Any]
        let dateEncodingStrategy: DateEncodingStrategy
        let uuidEncodingStrategy: UUIDEncodingStrategy
        let dataEncodingStrategy: DataEncodingStrategy
    }

    /// The options set on the top-level encoder.
    fileprivate var options: _Options {
        _Options(
            userInfo: self.userInfo,
            dateEncodingStrategy: self.dateEncodingStrategy,
            uuidEncodingStrategy: self.uuidEncodingStrategy,
            dataEncodingStrategy: self.dataEncodingStrategy
        )
    }

    /// Initializes `self`.
    public init(options: CodingStrategyProvider? = nil) {
        self.configureWithOptions(options: options)
    }

    /// Initializes `self` by using the options of another `BSONEncoder` and the provided options, with preference
    /// going to the provided options in the case of conflicts.
    internal init(copies other: BSONEncoder, options: CodingStrategyProvider?) {
        self.userInfo = other.userInfo
        self.dateEncodingStrategy = other.dateEncodingStrategy
        self.uuidEncodingStrategy = other.uuidEncodingStrategy
        self.dataEncodingStrategy = other.dataEncodingStrategy

        self.configureWithOptions(options: options)
    }

    internal func configureWithOptions(options: CodingStrategyProvider?) {
        self.dateEncodingStrategy = options?.dateCodingStrategy?.rawValue.encoding ?? self.dateEncodingStrategy
        self.uuidEncodingStrategy = options?.uuidCodingStrategy?.rawValue.encoding ?? self.uuidEncodingStrategy
        self.dataEncodingStrategy = options?.dataCodingStrategy?.rawValue.encoding ?? self.dataEncodingStrategy
    }

    /**
     * Encodes the given top-level value and returns its BSON representation.
     *
     * - Parameter value: The value to encode.
     * - Returns: A new `BSONDocument` containing the encoded BSON data.
     * - Throws: `EncodingError` if any value throws an error during encoding.
     */
    public func encode<T: Encodable>(_ value: T) throws -> BSONDocument {
        let encodedBSON: BSON = try self.encodeFragment(value)
        switch encodedBSON {
        case let .document(doc):
            return doc
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Top-level \(T.self) was not encoded as a complete document."
                )
            )
        }
    }

    /**
     * Encodes the given top-level optional value and returns its BSON representation. Returns nil if the
     * value is nil or if it contains no data.
     *
     * - Parameter value: The value to encode.
     * - Returns: A new `BSONDocument` containing the encoded BSON data, or nil if there is no data to encode.
     * - Throws: `EncodingError` if any value throws an error during encoding.
     */
    public func encode<T: Encodable>(_ value: T?) throws -> BSONDocument? {
        guard let value = value else {
            return nil
        }
        let encoded: BSONDocument = try self.encode(value)
        return encoded == [:] ? nil : encoded
    }

    /**
     * Encodes the given array of top-level values and returns an array of their BSON representations.
     *
     * - Parameter values: The values to encode.
     * - Returns: A new `[Document]` containing the encoded BSON data.
     * - Throws: `EncodingError` if any value throws an error during encoding.
     */
    public func encode<T: Encodable>(_ values: [T]) throws -> [BSONDocument] {
        try values.map { try self.encode($0) }
    }

    /**
     * Encodes the given array of top-level optional values and returns an array of their BSON representations.
     * Any value that is nil or contains no data will be mapped to nil.
     *
     * - Parameter values: The values to encode.
     * - Returns: A new `[Document?]` containing the encoded BSON data. Any value that is nil or
     *            contains no data will be mapped to nil.
     * - Throws: `EncodingError` if any value throws an error during encoding.
     */
    public func encode<T: Encodable>(_ values: [T?]) throws -> [BSONDocument?] {
        try values.map { try self.encode($0) }
    }

    /**
     * Encodes the given top-level value and returns its BSON representation.
     *
     * - Parameter value: The value to encode.
     * - Returns: A new `BSON` containing the encoded BSON data.
     * - Throws: `EncodingError` if any value throws an error during encoding.
     */
    internal func encodeFragment<T: Encodable>(_ value: T) throws -> BSON {
        let encoder = _BSONEncoder(options: self.options)

        do {
            guard let boxedValue = try encoder.box_(value) else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: [],
                        debugDescription: "Top-level \(T.self) did not encode any values."
                    )
                )
            }
            return try boxedValue.toBSON()
        } catch let error as BSONErrorProtocol {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: error.errorDescription ?? "Unknown Error occurred while encoding BSON"
                )
            )
        }
    }
}

/// :nodoc: An internal class to implement the `Encoder` protocol.
internal class _BSONEncoder: Encoder {
    /// The encoder's storage.
    internal var storage: _BSONEncodingStorage

    /// Options set on the top-level encoder.
    fileprivate let options: BSONEncoder._Options

    /// The path to the current point in encoding.
    public var codingPath: [CodingKey]

    /// Contextual user-provided information for use during encoding.
    public var userInfo: [CodingUserInfoKey: Any] {
        self.options.userInfo
    }

    /// Initializes `self` with the given top-level encoder options.
    fileprivate init(options: BSONEncoder._Options, codingPath: [CodingKey] = []) {
        self.options = options
        self.storage = _BSONEncodingStorage()
        self.codingPath = codingPath
    }

    /// Returns whether a new element can be encoded at this coding path.
    ///
    /// `true` if an element has not yet been encoded at this coding path; `false` otherwise.
    fileprivate var canEncodeNewValue: Bool {
        self.storage.count == self.codingPath.count
    }

    public func container<Key>(keyedBy _: Key.Type) -> KeyedEncodingContainer<Key> {
        // If an existing keyed container was already requested, return that one.
        let topContainer: MutableDictionary
        if self.canEncodeNewValue {
            // We haven't yet pushed a container at this level; do so here.
            topContainer = self.storage.pushKeyedContainer()
        } else {
            guard let container = self.storage.containers.last as? MutableDictionary else {
                fatalError(
                    "Attempt to push new keyed encoding container when already previously encoded at this path.")
            }
            topContainer = container
        }
        let container = _BSONKeyedEncodingContainer<Key>(
            referencing: self, codingPath: self.codingPath, wrapping: topContainer
        )
        return KeyedEncodingContainer(container)
    }

    public func unkeyedContainer() -> UnkeyedEncodingContainer {
        // If an existing unkeyed container was already requested, return that one.
        let topContainer: MutableArray
        if self.canEncodeNewValue {
            // We haven't yet pushed a container at this level; do so here.
            topContainer = self.storage.pushUnkeyedContainer()
        } else {
            guard let container = self.storage.containers.last as? MutableArray else {
                fatalError(
                    "Attempt to push new unkeyed encoding container when already previously encoded at this path.")
            }
            topContainer = container
        }

        return _BSONUnkeyedEncodingContainer(referencing: self, codingPath: self.codingPath, wrapping: topContainer)
    }

    public func singleValueContainer() -> SingleValueEncodingContainer {
        self
    }
}

internal struct _BSONEncodingStorage {
    /// The container stack.
    /// Elements may be any `BSONRepresentable` type.
    internal var containers: [BSONRepresentable] = []

    /// Initializes `self` with no containers.
    fileprivate init() {}

    fileprivate var count: Int {
        self.containers.count
    }

    fileprivate mutating func pushKeyedContainer() -> MutableDictionary {
        let dictionary = MutableDictionary()
        self.containers.append(dictionary)
        return dictionary
    }

    fileprivate mutating func pushUnkeyedContainer() -> MutableArray {
        let array = MutableArray()
        self.containers.append(array)
        return array
    }

    fileprivate mutating func push(container: BSONRepresentable) {
        self.containers.append(container)
    }

    fileprivate mutating func popContainer() -> BSONRepresentable {
        guard !self.containers.isEmpty else {
            fatalError("Empty container stack.")
        }
        // swiftlint:disable:next force_unwrapping
        return self.containers.popLast()! // guaranteed safe because of precondition.
    }
}

/// `_BSONReferencingEncoder` is a special subclass of `_BSONEncoder` which has its own storage, but references the
/// contents of a different encoder. It's used in superEncoder(), which returns a new encoder for encoding a
/// superclass -- the lifetime of the encoder should not escape the scope it's created in, but it doesn't
// necessarily know when it's done being used (to write to the original container).
private class _BSONReferencingEncoder: _BSONEncoder {
    /// The type of container we're referencing.
    private enum Reference {
        /// Referencing a specific index in an array container.
        case array(MutableArray, Int)

        /// Referencing a specific key in a dictionary container.
        case dictionary(MutableDictionary, String)
    }

    /// The encoder we're referencing.
    fileprivate let encoder: _BSONEncoder

    /// The container reference itself.
    private let reference: Reference

    fileprivate init(referencing encoder: _BSONEncoder, at index: Int, wrapping array: MutableArray) {
        self.encoder = encoder
        self.reference = .array(array, index)
        super.init(options: encoder.options, codingPath: encoder.codingPath)

        self.codingPath.append(_BSONKey(index: index))
    }

    /// Initializes `self` by referencing the given dictionary container in the given encoder.
    fileprivate init(referencing encoder: _BSONEncoder, key: CodingKey, wrapping dictionary: MutableDictionary) {
        self.encoder = encoder
        self.reference = .dictionary(dictionary, key.stringValue)
        super.init(options: encoder.options, codingPath: encoder.codingPath)

        self.codingPath.append(key)
    }

    override fileprivate var canEncodeNewValue: Bool {
        // With a regular encoder, the storage and coding path grow together.
        // A referencing encoder, however, inherits its parents coding path, as well as the key it was created for.
        // We have to take this into account.
        self.storage.count == self.codingPath.count - self.encoder.codingPath.count - 1
    }

    /// Finalizes `self` by writing the contents of our storage to the referenced encoder's storage.
    deinit {
        let value: BSONRepresentable
        switch self.storage.count {
        case 0: value = BSONDocument()
        case 1: value = self.storage.popContainer()
        default: fatalError("Referencing encoder deallocated with multiple containers on stack.")
        }

        switch self.reference {
        case let .array(array, index):
            array.insert(value, at: index)

        case let .dictionary(dictionary, key):
            dictionary[key] = value
        }
    }
}

/// Extend `_BSONEncoder` to add methods for "boxing" values.
extension _BSONEncoder {
    /// Converts a `CodableNumber` to a `BSONRepresentable` type. Throws if `value` cannot be
    /// exactly represented by an `Int`, `Int32`, `Int64`, or `Double`.
    fileprivate func boxNumber<T: CodableNumber>(_ value: T) throws -> BSONRepresentable {
        guard let number = value.bsonValue else {
            throw EncodingError._numberError(at: self.codingPath, value: value)
        }
        return number
    }

    /// Returns the value as a `BSONRepresentable` if possible. Otherwise, returns an empty `BSONDocument`.
    fileprivate func box<T: Encodable>(_ value: T) throws -> BSONRepresentable {
        try self.box_(value) ?? BSONDocument()
    }

    private func handleCustomStrategy<T: Encodable>(
        encodeFunc f: (T, Encoder) throws -> Void,
        forValue value: T
    ) throws -> BSONRepresentable? {
        let depth = self.storage.count

        do {
            try f(value, self)
        } catch {
            if self.storage.count > depth {
                _ = self.storage.popContainer()
            }
            throw error
        }

        // The closure didn't encode anything.
        guard self.storage.count > depth else {
            return nil
        }

        return self.storage.popContainer()
    }

    /// Returns the date as a `BSONRepresentable`, or nil if no values were encoded by the custom encoder strategy.
    private func boxDate(_ date: Date) throws -> BSONRepresentable? {
        func validateDate() throws {
            guard date.isValidBSONDate() else {
                throw EncodingError.invalidValue(
                    date,
                    EncodingError.Context(
                        codingPath: self.codingPath,
                        debugDescription: "Date must be representable as an Int64 number of milliseconds since epoch"
                    )
                )
            }
        }

        switch self.options.dateEncodingStrategy {
        case .bsonDateTime:
            try validateDate()
            return date
        case .deferredToDate:
            try date.encode(to: self)
            return self.storage.popContainer()
        case .millisecondsSince1970:
            try validateDate()
            return date.msSinceEpoch
        case .secondsSince1970:
            return date.timeIntervalSince1970
        case let .formatted(formatter):
            return formatter.string(from: date)
        case .iso8601:
            return BSONDecoder.iso8601Formatter.string(from: date)
        case let .custom(f):
            return try self.handleCustomStrategy(encodeFunc: f, forValue: date)
        }
    }

    /// Returns the uuid as a `BSONRepresentable`.
    private func boxUUID(_ uuid: UUID) throws -> BSONRepresentable {
        switch self.options.uuidEncodingStrategy {
        case .deferredToUUID:
            try uuid.encode(to: self)
            return self.storage.popContainer()
        case .binary:
            return try BSONBinary(from: uuid)
        }
    }

    private func boxData(_ data: Data) throws -> BSONRepresentable? {
        switch self.options.dataEncodingStrategy {
        case .deferredToData:
            try data.encode(to: self)
            return self.storage.popContainer()
        case .binary:
            return try BSONBinary(data: data, subtype: .generic)
        case .base64:
            return String(base64Encoding: data)
        case let .custom(f):
            return try self.handleCustomStrategy(encodeFunc: f, forValue: data)
        }
    }

    /// Returns the value as a `BSONRepresentable` if possible. Otherwise, returns nil.
    fileprivate func box_<T: Encodable>(_ value: T) throws -> BSONRepresentable? {
        switch value {
        case let date as Date:
            return try self.boxDate(date)
        case let bson as BSON:
            if case let .datetime(d) = bson {
                return try boxDate(d)
            } else {
                return bson.bsonValue
            }
        case let uuid as UUID:
            return try self.boxUUID(uuid)
        case let data as Data:
            return try self.boxData(data)
        default:
            break
        }

        // if it's already a `BSONValue`, just return it.
        if let bsonValue = value as? BSONRepresentable {
            return bsonValue
        } else if let bsonArray = value as? [BSONRepresentable] {
            return try bsonArray.map { try $0.toBSON() }
        }

        // The value should request a container from the _BSONEncoder.
        let depth = self.storage.count
        do {
            try value.encode(to: self)
        } catch {
            // If the value pushed a container before throwing, pop it back off to restore state.
            if self.storage.count > depth { _ = self.storage.popContainer() }
            throw error
        }

        // The top container should be a new container.
        guard self.storage.count > depth else {
            return nil
        }
        return self.storage.popContainer()
    }
}

private struct _BSONKeyedEncodingContainer<K: CodingKey>: KeyedEncodingContainerProtocol {
    typealias Key = K

    /// A reference to the encoder we're writing to.
    private let encoder: _BSONEncoder

    /// A reference to the container we're writing to.
    private let container: MutableDictionary

    /// The path of coding keys taken to get to this point in encoding.
    public private(set) var codingPath: [CodingKey]

    /// Initializes `self` with the given references.
    fileprivate init(
        referencing encoder: _BSONEncoder,
        codingPath: [CodingKey],
        wrapping container: MutableDictionary
    ) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.container = container
    }

    public mutating func encodeNil(forKey key: Key) throws { self.container[key.stringValue] = BSONNull() }
    public mutating func encode(_ value: Bool, forKey key: Key) throws { self.container[key.stringValue] = value }
    public mutating func encode(_ value: Int, forKey key: Key) throws {
        self.container[key.stringValue] = BSON(value).bsonValue
    }

    public mutating func encode(_ value: Int8, forKey key: Key) throws { try self.encodeNumber(value, forKey: key) }
    public mutating func encode(_ value: Int16, forKey key: Key) throws { try self.encodeNumber(value, forKey: key) }
    public mutating func encode(_ value: Int32, forKey key: Key) throws { self.container[key.stringValue] = value }
    public mutating func encode(_ value: Int64, forKey key: Key) throws { self.container[key.stringValue] = value }
    public mutating func encode(_ value: UInt, forKey key: Key) throws { try self.encodeNumber(value, forKey: key) }
    public mutating func encode(_ value: UInt8, forKey key: Key) throws { try self.encodeNumber(value, forKey: key) }
    public mutating func encode(_ value: UInt16, forKey key: Key) throws { try self.encodeNumber(value, forKey: key) }
    public mutating func encode(_ value: UInt32, forKey key: Key) throws { try self.encodeNumber(value, forKey: key) }
    public mutating func encode(_ value: UInt64, forKey key: Key) throws { try self.encodeNumber(value, forKey: key) }
    public mutating func encode(_ value: String, forKey key: Key) throws { self.container[key.stringValue] = value }
    public mutating func encode(_ value: Float, forKey key: Key) throws { try self.encodeNumber(value, forKey: key) }
    public mutating func encode(_ value: Double, forKey key: Key) throws { self.container[key.stringValue] = value }

    private mutating func encodeNumber<T: CodableNumber>(_ value: T, forKey key: Key) throws {
        // put the key on the codingPath in case the attempt to convert the number fails and we throw
        self.encoder.codingPath.append(key)
        defer { self.encoder.codingPath.removeLast() }
        self.container[key.stringValue] = try self.encoder.boxNumber(value)
    }

    public mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        self.encoder.codingPath.append(key)
        defer { self.encoder.codingPath.removeLast() }
        self.container[key.stringValue] = try self.encoder.box(value)
    }

    public mutating func nestedContainer<NestedKey>(
        keyedBy _: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let dictionary = MutableDictionary()
        self.container[key.stringValue] = dictionary

        self.codingPath.append(key)
        defer { self.codingPath.removeLast() }

        let container = _BSONKeyedEncodingContainer<NestedKey>(
            referencing: self.encoder, codingPath: self.codingPath, wrapping: dictionary
        )
        return KeyedEncodingContainer(container)
    }

    public mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let array = MutableArray()
        self.container[key.stringValue] = array

        self.codingPath.append(key)
        defer { self.codingPath.removeLast() }

        return _BSONUnkeyedEncodingContainer(referencing: self.encoder, codingPath: self.codingPath, wrapping: array)
    }

    public mutating func superEncoder() -> Encoder {
        _BSONReferencingEncoder(referencing: self.encoder, key: _BSONKey.super, wrapping: self.container)
    }

    public mutating func superEncoder(forKey key: Key) -> Encoder {
        _BSONReferencingEncoder(referencing: self.encoder, key: key, wrapping: self.container)
    }
}

private struct _BSONUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    /// A reference to the encoder we're writing to.
    private let encoder: _BSONEncoder

    /// A reference to the container we're writing to.
    private let container: MutableArray

    /// The path of coding keys taken to get to this point in encoding.
    public private(set) var codingPath: [CodingKey]

    /// The number of elements encoded into the container.
    public var count: Int {
        self.container.count
    }

    /// Initializes `self` with the given references.
    fileprivate init(referencing encoder: _BSONEncoder, codingPath: [CodingKey], wrapping container: MutableArray) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.container = container
    }

    public mutating func encodeNil() throws { self.container.add(BSONNull()) }
    public mutating func encode(_ value: Bool) throws { self.container.add(value) }
    public mutating func encode(_ value: Int) throws { self.container.add(BSON(value).bsonValue) }
    public mutating func encode(_ value: Int8) throws { try self.encodeNumber(value) }
    public mutating func encode(_ value: Int16) throws { try self.encodeNumber(value) }
    public mutating func encode(_ value: Int32) throws { self.container.add(value) }
    public mutating func encode(_ value: Int64) throws { self.container.add(value) }
    public mutating func encode(_ value: UInt) throws { try self.encodeNumber(value) }
    public mutating func encode(_ value: UInt8) throws { try self.encodeNumber(value) }
    public mutating func encode(_ value: UInt16) throws { try self.encodeNumber(value) }
    public mutating func encode(_ value: UInt32) throws { try self.encodeNumber(value) }
    public mutating func encode(_ value: UInt64) throws { try self.encodeNumber(value) }
    public mutating func encode(_ value: String) throws { self.container.add(value) }
    public mutating func encode(_ value: Float) throws { try self.encodeNumber(value) }
    public mutating func encode(_ value: Double) throws { self.container.add(value) }

    private mutating func encodeNumber<T: CodableNumber>(_ value: T) throws {
        self.encoder.codingPath.append(_BSONKey(index: self.count))
        defer { self.encoder.codingPath.removeLast() }

        self.container.add(try self.encoder.boxNumber(value))
    }

    public mutating func encode<T: Encodable>(_ value: T) throws {
        self.encoder.codingPath.append(_BSONKey(index: self.count))
        defer { self.encoder.codingPath.removeLast() }

        self.container.add(try self.encoder.box(value))
    }

    public mutating func nestedContainer<NestedKey>(keyedBy _: NestedKey.Type)
        -> KeyedEncodingContainer<NestedKey>
    {
        self.codingPath.append(_BSONKey(index: self.count))
        defer { self.codingPath.removeLast() }

        let dictionary = MutableDictionary()
        self.container.add(dictionary)

        let container = _BSONKeyedEncodingContainer<NestedKey>(
            referencing: self.encoder, codingPath: self.codingPath, wrapping: dictionary
        )
        return KeyedEncodingContainer(container)
    }

    public mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        self.codingPath.append(_BSONKey(index: self.count))
        defer { self.codingPath.removeLast() }

        let array = MutableArray()
        self.container.add(array)
        return _BSONUnkeyedEncodingContainer(referencing: self.encoder, codingPath: self.codingPath, wrapping: array)
    }

    public mutating func superEncoder() -> Encoder {
        _BSONReferencingEncoder(referencing: self.encoder, at: self.container.count, wrapping: self.container)
    }
}

/// :nodoc:
extension _BSONEncoder: SingleValueEncodingContainer {
    private func assertCanEncodeNewValue() {
        guard self.canEncodeNewValue else {
            fatalError("Attempt to encode value through single value container when previously value already encoded.")
        }
    }

    public func encodeNil() throws {
        self.assertCanEncodeNewValue()
        self.storage.push(container: BSONNull())
    }

    public func encode(_ value: Bool) throws { try self.encodeBSONType(value) }
    public func encode(_ value: Int) throws { try self.encodeNumber(value) }
    public func encode(_ value: Int8) throws { try self.encodeNumber(value) }
    public func encode(_ value: Int16) throws { try self.encodeNumber(value) }
    public func encode(_ value: Int32) throws { try self.encodeBSONType(value) }
    public func encode(_ value: Int64) throws { try self.encodeBSONType(value) }
    public func encode(_ value: UInt) throws { try self.encodeNumber(value) }
    public func encode(_ value: UInt8) throws { try self.encodeNumber(value) }
    public func encode(_ value: UInt16) throws { try self.encodeNumber(value) }
    public func encode(_ value: UInt32) throws { try self.encodeNumber(value) }
    public func encode(_ value: UInt64) throws { try self.encodeNumber(value) }
    public func encode(_ value: String) throws { try self.encodeBSONType(value) }
    public func encode(_ value: Float) throws { try self.encodeNumber(value) }
    public func encode(_ value: Double) throws { try self.encodeBSONType(value) }

    private func encodeNumber<T: CodableNumber>(_ value: T) throws {
        self.assertCanEncodeNewValue()
        self.storage.push(container: try self.boxNumber(value))
    }

    private func encodeBSONType<T: BSONRepresentable>(_ value: T) throws {
        self.assertCanEncodeNewValue()
        self.storage.push(container: value)
    }

    public func encode<T: Encodable>(_ value: T) throws {
        self.assertCanEncodeNewValue()
        self.storage.push(container: try self.box(value))
    }
}

/// Indicates that a type can be converted to a `BSON`.
internal protocol BSONRepresentable {
    func toBSON() throws -> BSON
}

extension Array: BSONRepresentable where Element == BSON {
    internal func toBSON() -> BSON {
        .array(self)
    }
}

extension BSONValue {
    internal func toBSON() -> BSON {
        self.bson
    }
}

/// A private class wrapping a Swift array so we can pass it by reference for
/// encoder storage purposes. We use this rather than NSMutableArray because
/// it allows us to preserve Swift type information.
private class MutableArray: BSONRepresentable {
    func toBSON() throws -> BSON {
        .array(try self.array.map { try $0.toBSON() })
    }

    fileprivate static var bsonType: BSONType { .array }
    internal static let extJSONTypeWrapperKeys: [String] = []

    fileprivate var array = [BSONRepresentable]()

    fileprivate func add(_ value: BSONRepresentable) {
        self.array.append(value)
    }

    fileprivate var count: Int { self.array.count }

    fileprivate func insert(_ value: BSONRepresentable, at index: Int) {
        self.array.insert(value, at: index)
    }

    fileprivate init() {}
}

/// A private class wrapping a Swift dictionary so we can pass it by reference
/// for encoder storage purposes. We use this rather than NSMutableDictionary
/// because it allows us to preserve Swift type information.
private class MutableDictionary: BSONRepresentable {
    internal static let extJSONTypeWrapperKeys: [String] = []
    fileprivate static var bsonType: BSONType { .document }

    // rather than using a dictionary, do this so we preserve key orders
    fileprivate var keys = [String]()
    fileprivate var values = [BSONRepresentable]()
    fileprivate var latestKeyIndexes = [String: Int]()

    fileprivate subscript(key: String) -> BSONRepresentable? {
        get {
            guard let index = self.latestKeyIndexes[key] else {
                return nil
            }
            return self.values[index]
        }
        set(newValue) {
            if let newValue = newValue {
                if let index = self.latestKeyIndexes[key] {
                    self.keys.remove(at: index)
                    self.values.remove(at: index)
                }
                self.keys.append(key)
                self.values.append(newValue)
                self.latestKeyIndexes[key] = self.values.endIndex - 1
            } else {
                guard let index = self.latestKeyIndexes[key] else {
                    return
                }
                self.keys.remove(at: index)
                self.values.remove(at: index)
            }
        }
    }

    /// Converts self to a `BSONDocument` with equivalent key-value pairs.
    fileprivate func toDocument() throws -> BSONDocument {
        var doc = BSONDocument()
        for i in 0..<self.keys.count {
            let value = self.values[i]
            try doc.append(key: self.keys[i], value: try value.toBSON())
        }
        return doc
    }

    fileprivate func toBSON() throws -> BSON {
        .document(try self.toDocument())
    }

    fileprivate init() {}
}

private extension EncodingError {
    static func _numberError<T: CodableNumber>(at path: [CodingKey], value: T) -> EncodingError {
        let description = "Value \(String(describing: value)) of type \(type(of: value)) cannot be " +
            "exactly represented by a BSON number type (Int, Int32, Int64 or Double)."
        return .invalidValue(value, Context(codingPath: path, debugDescription: description))
    }
}
