//
//  LZMATestDecoder.swift
//  SWCompression
//
//  Created by Timofey Solomko on 01.05.17.
//  Copyright © 2017 Timofey Solomko. All rights reserved.
//

import Foundation

final class LZMATestDecoder {

    private var pointerData: DataWithPointer

    private var lc: UInt8
    private var lp: UInt8
    private var pb: UInt8
    private var dictionarySize: Int

    private var rangeDecoder: LZMARangeDecoder
    private var posSlotDecoder: [LZMABitTreeDecoder] = []
    private var alignDecoder: LZMABitTreeDecoder
    private var lenDecoder: LZMALenDecoder
    private var repLenDecoder: LZMALenDecoder

    /**
     For literal decoding we need `1 << (lc + lp)` amount of tables.
     Each table contains 0x300 probabilities.
     */
    private var literalProbs: [[Int]]

    /**
     Array with all probabilities:

     - 0..<192: isMatch
     - 193..<205: isRep
     - 205..<217: isRepG0
     - 217..<229: isRepG1
     - 229..<241: isRepG2
     - 241..<433: isRep0Long
     */
    private var probabilities: [Int] = Array(repeating: LZMAConstants.probInitValue, count: 2 * 192 + 4 * 12)

    private var posDecoders: [Int]

    // 'Distance history table'.
    private var rep0: Int = 0
    private var rep1: Int = 0
    private var rep2: Int = 0
    private var rep3: Int = 0

    /// Is used to select exact variable from 'IsRep', 'IsRepG0', 'IsRepG1' and 'IsRepG2' arrays.
    private var state: Int = 0

    /// An array for storing output data
    var out: [UInt8] = []
    // This array will also serve as dictionary and out window.
    private var dictStart = 0
    private var dictEnd = 0


    init(_ pointerData: inout DataWithPointer, _ lc: UInt8, _ pb: UInt8, _ lp: UInt8,
         _ dictionarySize: Int) throws {
        self.pointerData = pointerData

        self.lc = lc
        self.lp = lp
        self.pb = pb
        self.dictionarySize = dictionarySize

        self.rangeDecoder = LZMARangeDecoder()

        self.literalProbs = Array(repeating: Array(repeating: LZMAConstants.probInitValue,
                                                   count: 0x300),
                                  count: 1 << (lc + lp).toInt())

        self.posSlotDecoder = []
        for _ in 0..<LZMAConstants.numLenToPosStates {
            self.posSlotDecoder.append(LZMABitTreeDecoder(numBits: 6, &self.pointerData))
        }
        self.alignDecoder = LZMABitTreeDecoder(numBits: LZMAConstants.numAlignBits, &self.pointerData)
        self.posDecoders = Array(repeating: LZMAConstants.probInitValue,
                                 count: 1 + LZMAConstants.numFullDistances - LZMAConstants.endPosModelIndex)

        // There are two types of matches so we need two decoders for them.
        self.lenDecoder = LZMALenDecoder(&self.pointerData)
        self.repLenDecoder = LZMALenDecoder(&self.pointerData)
    }

    private func resetProperties() throws {
        var properties = pointerData.alignedByte()
        if properties >= (9 * 5 * 5) {
            throw LZMAError.WrongProperties
        }
        /// The number of literal context bits
        self.lc = properties % 9
        properties /= 9
        /// The number of pos bits
        self.pb = properties / 5
        /// The number of literal pos bits
        self.lp = properties % 5
    }

    func resetDictionary(_ dictSize: Int) {
        self.dictionarySize = dictSize
        self.dictStart = self.dictEnd
    }

    private func resetState() {
        self.state = 0

        self.rep0 = 0
        self.rep1 = 0
        self.rep2 = 0
        self.rep3 = 0

        self.probabilities = Array(repeating: LZMAConstants.probInitValue, count: 2 * 192 + 4 * 12)
        self.literalProbs = Array(repeating: Array(repeating: LZMAConstants.probInitValue,
                                                   count: 0x300),
                                  count: 1 << (lc + lp).toInt())

        self.posSlotDecoder = []
        for _ in 0..<LZMAConstants.numLenToPosStates {
            self.posSlotDecoder.append(LZMABitTreeDecoder(numBits: 6, &self.pointerData))
        }
        self.alignDecoder = LZMABitTreeDecoder(numBits: LZMAConstants.numAlignBits, &self.pointerData)
        self.posDecoders = Array(repeating: LZMAConstants.probInitValue,
                                 count: 1 + LZMAConstants.numFullDistances - LZMAConstants.endPosModelIndex)
        self.lenDecoder = LZMALenDecoder(&self.pointerData)
        self.repLenDecoder = LZMALenDecoder(&self.pointerData)
    }

    func decodeUncompressed() {
        let dataSize = self.pointerData.alignedByte().toInt() << 8 + self.pointerData.alignedByte().toInt() + 1
        for _ in 0..<dataSize {
            let byte = pointerData.alignedByte()
            out.append(byte)
            dictEnd += 1
            if dictEnd - dictStart == dictionarySize {
                dictStart += 1
            }
        }
    }

    func decodeLZMA2(_ controlByte: UInt8, _ dictSize: Int) throws {
        let uncompressedSizeBits = controlByte & 0x1F
        let reset = (controlByte & 0x60) >> 5
        let unpackSize = (uncompressedSizeBits.toInt() << 16) +
            self.pointerData.alignedByte().toInt() << 8 + self.pointerData.alignedByte().toInt() + 1
        let compressedSize = self.pointerData.alignedByte().toInt() << 8 + self.pointerData.alignedByte().toInt() + 1
        var dataStartIndex = pointerData.index
        switch reset {
        case 0:
            break
        case 1:
            self.resetState()
        case 2:
            try self.resetProperties()
            self.resetState()
            dataStartIndex += 1
        case 3:
            try self.resetProperties()
            self.resetState()
            dataStartIndex += 1
            self.resetDictionary(dictSize)
        default:
            throw LZMA2Error.WrongReset
        }
        var uncompressedSize = unpackSize
        let startCount = out.count
        try decodeLZMA(&uncompressedSize)
        guard unpackSize == out.count - startCount && pointerData.index - dataStartIndex == compressedSize
            else { throw LZMA2Error.WrongSizes }
    }

    func decodeLZMA(_ uncompressedSize: inout Int) throws {
        // First, we need to initialize Rande Decoder.
        guard let rD = LZMARangeDecoder(&self.pointerData) else {
            throw LZMAError.RangeDecoderInitError
        }
        self.rangeDecoder = rD

        // Main decoding cycle.
        while true {
            // If uncompressed size was defined and everything is unpacked then stop.
            if uncompressedSize == 0 {
                if rangeDecoder.isFinishedOK {
                    break
                }
            }

            let posState = out.count & ((1 << pb.toInt()) - 1)
            if rangeDecoder.decode(bitWithProb: &probabilities[(state << LZMAConstants.numPosBitsMax) + posState]) == 0 {
                if uncompressedSize == 0 { throw LZMAError.ExceededUncompressedSize }

                // DECODE LITERAL:
                /// Previous literal (zero, if there was none).
                let prevByte = dictEnd == 0 ? 0 : out[1 <= dictEnd ? dictEnd - 1 : dictionarySize - 1 + dictEnd]
                /// Decoded symbol. Initial value is 1.
                var symbol = 1
                /**
                 Index of table with literal probabilities. It is based on the context which consists of:
                 - `lc` high bits of from previous literal.
                 If there were none, i.e. it is the first literal, then this part is skipped.
                 - `lp` low bits from current position in output.
                 */
                let litState = ((out.count & ((1 << lp.toInt()) - 1)) << lc.toInt()) + (prevByte >> (8 - lc)).toInt()
                // If state is greater than 7 we need to do additional decoding with 'matchByte'.
                if state >= 7 {
                    /**
                     Byte in output at position that is the `distance` bytes before current position,
                     where the `distance` is the distance from the latest decoded match.
                     */
                    var matchByte = out[rep0 + 1 <= dictEnd ? dictEnd - rep0 - 1 : dictionarySize - rep0 - 1 + dictEnd]
                    repeat {
                        let matchBit = ((matchByte >> 7) & 1).toInt()
                        matchByte <<= 1
                        let bit = rangeDecoder.decode(bitWithProb: &literalProbs[litState][((1 + matchBit) << 8) + symbol])
                        symbol = (symbol << 1) | bit
                        if matchBit != bit {
                            break
                        }
                    } while symbol < 0x100
                }
                while symbol < 0x100 {
                    symbol = (symbol << 1) | rangeDecoder.decode(bitWithProb: &literalProbs[litState][symbol])
                }
                let byte = (symbol - 0x100).toUInt8()

                out.append(byte)
                uncompressedSize -= 1
                dictEnd += 1
                if dictEnd - dictStart == dictionarySize {
                    dictStart += 1
                }
                // END.

                // Finally, we need to update `state`.
                if state < 4 {
                    state = 0
                } else if state < 10 {
                    state -= 3
                } else {
                    state -= 6
                }

                continue
            }

            var len: Int
            if rangeDecoder.decode(bitWithProb: &probabilities[193 + state]) != 0 {
                // REP MATCH CASE
                if uncompressedSize == 0 { throw LZMAError.ExceededUncompressedSize }
                if dictEnd == 0 { throw LZMAError.WindowIsEmpty }
                if rangeDecoder.decode(bitWithProb: &probabilities[205 + state]) == 0 {
                    // (We use last distance from 'distance history table').
                    if rangeDecoder.decode(bitWithProb: &probabilities[241 + (state << LZMAConstants.numPosBitsMax) + posState]) == 0 {
                        // SHORT REP MATCH CASE
                        state = state < 7 ? 9 : 11
                        let byte = out[rep0 + 1 <= dictEnd ? dictEnd - rep0 - 1 : dictionarySize - rep0 - 1 + dictEnd]
                        out.append(byte)
                        uncompressedSize -= 1
                        dictEnd += 1
                        if dictEnd - dictStart == dictionarySize {
                            dictStart += 1
                        }
                        continue
                    }
                } else { // REP MATCH CASE
                    // (It means that we use distance from 'distance history table').
                    // So the following code selectes one distance from history...
                    // based on the binary data.
                    let dist: Int
                    if rangeDecoder.decode(bitWithProb: &probabilities[217 + state]) == 0 {
                        dist = rep1
                    } else {
                        if rangeDecoder.decode(bitWithProb: &probabilities[229 + state]) == 0 {
                            dist = rep2
                        } else {
                            dist = rep3
                            rep3 = rep2
                        }
                        rep2 = rep1
                    }
                    rep1 = rep0
                    rep0 = dist
                }
                len = repLenDecoder.decode(with: &rangeDecoder, posState: posState)
                state = state < 7 ? 8 : 11
            } else { // SIMPLE MATCH CASE
                // First, we need to move history of distance values.
                rep3 = rep2
                rep2 = rep1
                rep1 = rep0
                len = lenDecoder.decode(with: &rangeDecoder, posState: posState)
                state = state < 7 ? 7 : 10

                // DECODE DISTANCE:
                /// Is used to define context for distance decoding.
                var lenState = len
                if lenState > LZMAConstants.numLenToPosStates - 1 {
                    lenState = LZMAConstants.numLenToPosStates - 1
                }

                /// Defines decoding scheme for distance value.
                let posSlot = posSlotDecoder[lenState].decode(with: &rangeDecoder)
                if posSlot < 4 {
                    // If `posSlot` is less than 4 then distance has defined value (no need to decode).
                    // And distance is actually equal to `posSlot`.
                    rep0 = posSlot
                } else {
                    let numDirectBits = (posSlot >> 1) - 1
                    var dist = ((2 | (posSlot & 1)) << numDirectBits)
                    if posSlot < LZMAConstants.endPosModelIndex {
                        // In this case we need a sequence of bits decoded with bit tree...
                        // ...(separate trees for different `posSlot` values)...
                        // ...and 'Reverse' scheme to get distance value.
                        dist += LZMABitTreeDecoder.bitTreeReverseDecode(probs: &posDecoders,
                                                                        startIndex: dist - posSlot,
                                                                        bits: numDirectBits,
                                                                        rangeDecoder: &rangeDecoder)
                    } else {
                        // Middle bits of distance are decoded as direct bits from RangeDecoder.
                        dist += rangeDecoder.decode(directBits: (numDirectBits - LZMAConstants.numAlignBits))
                            << LZMAConstants.numAlignBits
                        // Low 4 bits are decoded with a bit tree decoder (called 'AlignDecoder')...
                        // ...with "Reverse" scheme.
                        dist += alignDecoder.reverseDecode(with: &rangeDecoder)
                    }
                    rep0 = dist
                }
                // END.

                // Check if finish marker is encountered.
                // Distance value of 2^32 is used to indicate 'End of Stream' marker.
                if UInt32(rep0) == 0xFFFFFFFF {
                    guard rangeDecoder.isFinishedOK else { throw LZMAError.RangeDecoderFinishError }
                    break
                }

                if uncompressedSize == 0 { throw LZMAError.ExceededUncompressedSize }
                if rep0 >= dictionarySize || (rep0 > dictEnd && dictEnd < dictionarySize) { throw LZMAError.NotEnoughToRepeat }
            }
            // Converting from zero-based length of the match to the real one.
            len += LZMAConstants.matchMinLen
            if uncompressedSize > -1 && uncompressedSize < len { throw LZMAError.RepeatWillExceed }
            for _ in 0..<len {
                let byte = out[rep0 + 1 <= dictEnd ? dictEnd - rep0 - 1 : dictionarySize - rep0 - 1 + dictEnd]
                out.append(byte)
                uncompressedSize -= 1
                dictEnd += 1
                if dictEnd - dictStart == dictionarySize {
                    dictStart += 1
                }
            }
        }
    }
    
}
