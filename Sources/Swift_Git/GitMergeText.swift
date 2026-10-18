//
//  GitMergeText.swift
//  Swift-Git
//
//  Created by Phineas Guo on 2026/10/16.
//

import Foundation

enum GitMergeText {
    struct Edit { let start: Int; let end: Int; let lines: [String] }
    struct Result { let data: Data; let conflicted: Bool }

    static func merge(base: Data, ours: Data, theirs: Data) throws -> Result? {
        guard [base, ours, theirs].allSatisfy({ $0.count <= 2 * 1_024 * 1_024 && !$0.contains(0) }),
              let base = String(data: base, encoding: .utf8), let ours = String(data: ours, encoding: .utf8),
              let theirs = String(data: theirs, encoding: .utf8) else { return nil }
        func lines(_ text: String) -> [String] {
            if text.isEmpty { return [] }
            var result = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) + "\n" }
            if text.hasSuffix("\n") { result.removeLast() }
            else { result[result.count - 1].removeLast() }
            return result
        }
        let original = lines(base), left = lines(ours), right = lines(theirs)
        guard original.count + left.count + right.count <= 6000 else { return nil }
        func edits(_ new: [String]) throws -> [Edit] {
            let difference = new.difference(from: original)
            var removed = Set<Int>(), inserted = Set<Int>()
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            var old = 0, next = 0, start: Int?, replacement = [String](), result = [Edit]()
            func finish() {
                if let from = start { result.append(.init(start: from, end: old, lines: replacement)) }
                start = nil; replacement = []
            }
            while old < original.count || next < new.count {
                try Task.checkCancellation()
                if removed.contains(old) { if start == nil { start = old }; old += 1 }
                else if inserted.contains(next) { if start == nil { start = old }; replacement.append(new[next]); next += 1 }
                else { finish(); old += 1; next += 1 }
            }
            finish(); return result
        }
        let edits = try edits(left).map { (false, $0) } + edits(right).map { (true, $0) }
        let ordered = edits.sorted { $0.1.start == $1.1.start ? $0.1.end < $1.1.end : $0.1.start < $1.1.start }
        var output = "", position = 0, index = 0, conflicted = false
        while index < ordered.count {
            let start = ordered[index].1.start
            var end = ordered[index].1.end, group = [ordered[index]]
            index += 1
            while index < ordered.count {
                let next = ordered[index].1
                let touchesInsertion = next.start == end && (next.start == next.end || group.contains { $0.1.start == $0.1.end && $0.1.start == end })
                guard next.start < end || next.start == start || touchesInsertion else { break }
                group.append(ordered[index]); end = max(end, next.end); index += 1
            }
            output += original[position..<start].joined()
            func project(_ incoming: Bool) -> String {
                var result = "", cursor = start
                for (_, edit) in group.filter({ $0.0 == incoming }).sorted(by: { $0.1.start < $1.1.start }) {
                    result += original[cursor..<edit.start].joined() + edit.lines.joined(); cursor = edit.end
                }
                return result + original[cursor..<end].joined()
            }
            let hasOurs = group.contains { !$0.0 }, hasTheirs = group.contains { $0.0 }
            let ours = project(false), theirs = project(true)
            if !hasOurs { output += theirs }
            else if !hasTheirs || ours == theirs { output += ours }
            else {
                conflicted = true
                output += "<<<<<<< HEAD\n" + ours + (ours.hasSuffix("\n") || ours.isEmpty ? "" : "\n")
                    + "=======\n" + theirs + (theirs.hasSuffix("\n") || theirs.isEmpty ? "" : "\n") + ">>>>>>> Incoming\n"
            }
            position = end
        }
        output += original[position...].joined()
        return .init(data: Data(output.utf8), conflicted: conflicted)
    }
}
