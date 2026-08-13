// corpusgen: rebuilds the word lists by hand.
//
// The app builds them itself on first launch; this exists for rebuilding after
// installing new dictionaries or apps, and for checking what came out.
//
//   swift run corpusgen

import Foundation
import WmpCore

do {
    let counts = try WordListBuilder.build { step in
        FileHandle.standardError.write("\(step)\n".data(using: .utf8)!)
    }
    print("thai: \(counts.thai) words")
    print("english: \(counts.english) words")
    print("written to \(WordListBuilder.storageDirectory.path)")
} catch {
    FileHandle.standardError.write("failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
