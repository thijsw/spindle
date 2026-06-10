// Entry point for the spindle-tests executable. Add each new suite here.

tocParserTests()
discIDTests()
metadataTests()
verificationTests()
await ripEngineTests()
await encodingTests()
await transferTests()
Harness.finish()
