@Test
fun invalidCreateContainerCall_doesNotLeakPendingResultToNextPick() {
    // Simulate CREATE_CONTAINER with no password -> should resolve with error
    // and NOT leave pendingFlutterResult set. A subsequent PICK_CONTAINER call
    // must not throw "Reply already submitted".
    // (Requires a test MethodChannel.Result fake recording success/error calls
    // and asserting each result.error()/success() fires exactly once.)
}