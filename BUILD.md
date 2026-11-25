# iBrain

iBrain is the Swift memory engine used by Pin. Its packages represent entities and their relationships, associate facts with supporting source records, and handle revisions, conflicts and withdrawal. Pin imports the core, semantics, retrieval and vision products from this directory.

Run `swift test` from this directory on a Mac with the Swift toolchain. This distribution includes its test fixtures. The verified suite ran 186 tests on macOS and 186 on an iPhone Simulator. In Xcode, choose the IBrain-Package scheme to run all test targets. The SavedPlaceEvaluation executable requires macOS 26 and Foundation Models. Pin's itinerary evaluation is a separate integration test in the Pin distribution.

See LICENSE for the MIT terms.
