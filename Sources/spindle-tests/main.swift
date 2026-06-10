// Entry point for the spindle-tests executable. Add each new suite here.

tocParserTests()
discIDTests()
metadataTests()
await ripEngineTests()
await encodingTests()
Harness.finish()
