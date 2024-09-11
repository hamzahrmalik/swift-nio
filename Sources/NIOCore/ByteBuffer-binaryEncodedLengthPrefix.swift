//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(Windows)
import ucrt
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Bionic)
import Bionic
#else
#error("The Byte Buffer module was unable to identify your C library.")
#endif

/// Describes a way to encode and decode an integer as bytes
///
public protocol NIOBinaryIntegerEncodingStrategy {
    /// Read an integer from a buffer.
    /// If there are not enough bytes to read an integer of this encoding, return nil, and do not move the reader index.
    /// If the the full integer can be read, move the reader index to after the integer, and return the integer.
    /// - Parameters:
    ///   - as: The type of integer to be read.
    ///   - buffer: The buffer to read from.
    /// - Returns: The integer that was read, or nil if it was not possible to read it.
    func readInteger<IntegerType: FixedWidthInteger>(
        as: IntegerType.Type,
        from buffer: inout ByteBuffer
    ) -> IntegerType?

    /// Write an integer to a buffer. Move the writer index to after the written integer.
    /// - Parameters:
    ///    - integer: The type of the integer to write.
    ///    - buffer: The buffer to write to.
    /// - Returns: The number of bytes used to write the integer.
    func writeInteger<IntegerType: FixedWidthInteger>(
        _ integer: IntegerType,
        to buffer: inout ByteBuffer
    ) -> Int

    /// An estimate of the bytes required to write integers using ths strategy.
    /// Callers may use this to reserve bytes before writing the integer.
    /// If the actual bytes used by the write function is more or less than this, it may be necessary to shuffle bytes.
    /// Therefore, an accurate prediction here will improve performance.
    var requiredBytesHint: Int { get }

    /// Write an integer to a buffer. Move the writer index to after the written integer.
    /// Call this function if you have already reserved some capacity for an integer to be written.
    /// Implementors should consider using a less efficient encoding, if possible,to fit exactly within the reserved capacity.
    /// Otherwise, callers may need to shift bytes to reconcile the difference.
    /// It is up to the implementor to find the balance between performance and size.
    /// - Parameters:
    ///   - integer: The integer to write
    ///   - reservedCapacity: The capacity already reserved for writing this integer
    ///   - buffer: The buffer to write into.
    /// - Returns: The number of bytes used to write the integer.
    func writeIntegerWithReservedCapacity(
        _ integer: Int,
        reservedCapacity: Int,
        to buffer: inout ByteBuffer
    ) -> Int
}

extension NIOBinaryIntegerEncodingStrategy {
    @inlinable
    public var requiredBytesHint: Int { 1 }

    @inlinable
    public func writeIntegerWithReservedCapacity<IntegerType: FixedWidthInteger>(
        _ integer: IntegerType,
        reservedCapacity: Int,
        to buffer: inout ByteBuffer
    ) -> Int {
        self.writeInteger(integer, to: &buffer)
    }
}

extension ByteBuffer {
    /// Read a binary encoded integer, moving the `readerIndex` appropriately.
    /// If there are not enough bytes, nil is returned.
    @inlinable
    public mutating func readEncodedInteger<Strategy: NIOBinaryIntegerEncodingStrategy>(_ strategy: Strategy) -> Int? {
        strategy.readInteger(as: Int.self, from: &self)
    }

    /// Write a binary encoded integer.
    ///
    /// - Returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func writeEncodedInteger<
        Integer: FixedWidthInteger,
        Strategy: NIOBinaryIntegerEncodingStrategy
    >(
        _ value: Integer,
        strategy: Strategy
    ) -> Int {
        strategy.writeInteger(value, to: &self)
    }

    /// Prefixes bytes written by `writeData` with the number of bytes written.
    /// The number of bytes written is encoded usng `strategy`
    ///
    /// - Note: This function works by reserving the number of bytes suggested by `strategy` before the data.
    /// It then writes the data, and then goes back to write the length.
    /// If the reserved capacity turns out to be too little or too much, then the data will be shifted.
    /// Therefore, this function is most performant if the strategy is able to use the same number of bytes that it reserved.
    ///
    /// - Parameters:
    ///     - strategy: The strategy to use for encoding the length.
    ///     - writeData: A closure that takes a buffer, writes some data to it, and returns the number of bytes written.
    /// - Returns: Number of total bytes written. This is the length of the written data + the number of bytes used to write the length before it.
    @discardableResult
    @inlinable
    public mutating func writeLengthPrefixed<Strategy: NIOBinaryIntegerEncodingStrategy>(
        strategy: Strategy,
        writeData: (_ buffer: inout ByteBuffer) throws -> Int
    ) rethrows -> Int {
        /// The index at which we write the length
        let lengthPrefixIndex = self.writerIndex
        /// The space which we reserve for writing the length
        let reservedCapacity = strategy.requiredBytesHint
        self.writeRepeatingByte(0, count: reservedCapacity)

        /// The index at which we start writing the data originally. We may later move the data if the reserved space for the length wasn't right
        let originalDataStartIndex = self.writerIndex
        /// The length of the data written
        let dataLength: Int
        do {
            dataLength = try writeData(&self)
        } catch {
            // Clean up our write so that it as if we never did it.
            self.moveWriterIndex(to: lengthPrefixIndex)
            throw error
        }
        /// The index at the end of the written data originally. We may later move the data if the reserved space for the length wasn't right
        let originalDataEndIndex = self.writerIndex

        // Quick check to make sure the user didn't do something silly
        precondition(
            originalDataEndIndex - originalDataStartIndex == dataLength,
            "writeData returned \(dataLength) bytes, but actually \(originalDataEndIndex - originalDataStartIndex) bytes were written. They must be the same."
        )

        // We write the length after the data to begin with. We will move it later

        /// The actual number of bytes used to write the length written. The user may write more or fewer bytes than what we reserved
        let actualIntegerLength = strategy.writeIntegerWithReservedCapacity(
            dataLength,
            reservedCapacity: reservedCapacity,
            to: &self
        )

        switch actualIntegerLength {
        case reservedCapacity:
            // Good, exact match, swap the values and then "delete" the trailing bytes by moving the index back
            self._moveBytes(from: originalDataEndIndex, to: lengthPrefixIndex, size: actualIntegerLength)
            self.moveWriterIndex(to: originalDataEndIndex)
        case ..<reservedCapacity:
            // We wrote fewer bytes. We now have to move the length bytes from the end, and
            // _then_ shrink the rest of the buffer onto it.
            self._moveBytes(from: originalDataEndIndex, to: lengthPrefixIndex, size: actualIntegerLength)
            let newDataStartIndex = lengthPrefixIndex + actualIntegerLength
            self._moveBytes(
                from: originalDataStartIndex,
                to: newDataStartIndex,
                size: dataLength
            )
            self.moveWriterIndex(to: newDataStartIndex + dataLength)
        case reservedCapacity...:
            // We wrote more bytes. We now have to create enough space. Once we do, we have the same
            // implementation as the matching case.
            let extraSpaceNeeded = actualIntegerLength - reservedCapacity
            self._createSpace(before: lengthPrefixIndex, requiredSpace: extraSpaceNeeded)

            // Clean up the indices.
            let newDataEndIndex = originalDataEndIndex + extraSpaceNeeded
            // We wrote the length after the data, so we have to move those bytes to the space at the front
            self._moveBytes(from: newDataEndIndex, to: lengthPrefixIndex, size: actualIntegerLength)
            self.moveWriterIndex(to: newDataEndIndex)
        default:
            fatalError("Unreachable")
        }

        let totalBytesWritten = self.writerIndex - lengthPrefixIndex
        return totalBytesWritten
    }

    /// Reads a slice which is prefixed with a length. The length will be read using `strategy`, and then that many bytes will be read to create a slice.
    /// - Returns: The slice, if there are enough bytes to read it fully. In this case, the readerIndex will move to after the slice.
    /// If there are not enough bytes to read the full slice, the readerIndex will stay unchanged.
    @inlinable
    public mutating func readLengthPrefixedSlice<Strategy: NIOBinaryIntegerEncodingStrategy>(
        _ strategy: Strategy
    ) -> ByteBuffer? {
        let originalReaderIndex = self.readerIndex
        guard let length = strategy.readInteger(as: Int.self, from: &self), let slice = self.readSlice(length: length)
        else {
            self.moveReaderIndex(to: originalReaderIndex)
            return nil
        }
        return slice
    }
}

// MARK: - Helpers for writing length-prefixed things

extension ByteBuffer {
    /// Write the length of `buffer` using `strategy`. Then write the buffer.
    /// - Parameters:
    ///   - buffer: The buffer to be written.
    ///   - strategy: The encoding strategy to use.
    /// - Returns: The total bytes written. This is the bytes needed to write the length, plus the length of the buffer itself.
    @discardableResult
    @inlinable
    public mutating func writeLengthPrefixedBuffer<
        Strategy: NIOBinaryIntegerEncodingStrategy
    >(
        _ buffer: ByteBuffer,
        strategy: Strategy
    ) -> Int {
        var written = 0
        written += self.writeEncodedInteger(buffer.readableBytes, strategy: strategy)
        written += self.writeImmutableBuffer(buffer)
        return written
    }

    /// Write the length of `string` using `strategy`. Then write the string.
    /// - Parameters:
    ///  - string: The string to be written.
    ///  - strategy: The encoding strategy to use.
    /// - Returns: The total bytes written. This is the bytes needed to write the length, plus the length of the string itself.
    @discardableResult
    @inlinable
    public mutating func writeLengthPrefixedString<
        Strategy: NIOBinaryIntegerEncodingStrategy
    >(
        _ string: String,
        strategy: Strategy
    ) -> Int {
        var written = 0
        // writeString always writes the String as UTF8 bytes, without a null-terminator
        // So the length will be the utf8 count
        written += self.writeEncodedInteger(string.utf8.count, strategy: strategy)
        written += self.writeString(string)
        return written
    }

    /// Write the length of `bytes` using `strategy`. Then write the bytes.
    /// - Parameters:
    ///  - bytes: The bytes to be written.
    ///  - strategy: The encoding strategy to use.
    /// - Returns: The total bytes written. This is the bytes needed to write the length, plus the length of the bytes themselves.
    @discardableResult
    @inlinable
    public mutating func writeLengthPrefixedBytes<
        Bytes: Sequence,
        Strategy: NIOBinaryIntegerEncodingStrategy
    >(
        _ bytes: Bytes,
        strategy: Strategy
    ) -> Int
    where Bytes.Element == UInt8 {
        let numberOfBytes = bytes.withContiguousStorageIfAvailable { b in
            UnsafeRawBufferPointer(b).count
        }
        if let numberOfBytes {
            var written = 0
            written += self.writeEncodedInteger(numberOfBytes, strategy: strategy)
            written += self.writeBytes(bytes)
            return written
        } else {
            return self.writeLengthPrefixed(strategy: strategy) { buffer in
                buffer.writeBytes(bytes)
            }
        }
    }
}

extension ByteBuffer {
    /// Creates `requiredSpace` bytes of free space immediately before `index`.
    /// e.g. given [a, b, c, d, e, f, g, h, i, j] and calling this function with (before: 4, requiredSpace: 2) would result in
    /// [a, b, c, d, 0, 0, e, f, g, h, i, j]
    /// 2 extra bytes of space were created before index 4 (the letter e).
    /// The total bytes written will be equal to `requiredSpace`, and the writer index will be moved accordingly.
    @usableFromInline
    mutating func _createSpace(before index: Int, requiredSpace: Int) {
        let bytesToMove = self.writerIndex - index

        // Add the required number of bytes to the end first
        self.writeRepeatingByte(0, count: requiredSpace)
        // Move the data forward by that many bytes, to make space at the front
        self.withVeryUnsafeMutableBytes { pointer in
            _ = memmove(
                // Destination: This is forward from the index where we want to make space
                pointer.baseAddress!.advanced(by: index + requiredSpace),
                // Source: This is the index where we want to make space
                pointer.baseAddress!.advanced(by: index),
                // This is the number of bytes which will be moved
                bytesToMove
            )
        }
    }

    /// Move the `size` bytes starting from `source` to `destination`.
    /// `source` and `destination` must both be within the writable range.
    @usableFromInline
    mutating func _moveBytes(from source: Int, to destination: Int, size: Int) {
        precondition(source >= self.readerIndex && destination < self.writerIndex && source >= destination)
        precondition(source + size <= self.writerIndex)

        // The precondition above makes this safe: our indices are in the valid range, so we can safely use them here
        self.withVeryUnsafeMutableBytes { pointer in
            _ = memmove(
                pointer.baseAddress!.advanced(by: destination),
                pointer.baseAddress!.advanced(by: source),
                size
            )
        }
    }
}
