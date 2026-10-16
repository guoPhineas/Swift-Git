//
//  main.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation
import Swift_Git

// Deterministic input; run with `swift run -c release swift-git-benchmark`.
let body = Data((0..<(1_024 * 1_024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 256) })
let object = GitObject(kind: .blob, body: body)
let clock = ContinuousClock()
for algorithm in GitHashAlgorithm.allCases {
    var last = object.id(using: algorithm)
    let elapsed = clock.measure {
        for _ in 0..<100 { last = object.id(using: algorithm) }
    }
    print("\(algorithm.rawValue): 100 × 1 MiB, \(elapsed), digest=\(last.hex)")
}
