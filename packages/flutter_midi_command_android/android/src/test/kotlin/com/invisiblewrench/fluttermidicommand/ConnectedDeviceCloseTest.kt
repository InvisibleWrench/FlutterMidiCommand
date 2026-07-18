package com.invisiblewrench.fluttermidicommand

import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Regression tests for issue #158: unplugging a connected USB MIDI device
 * crashed the app because `ConnectedDevice.close()` called `inputPort.flush()`
 * on a dead file descriptor and the resulting `IOException: EPIPE` aborted the
 * rest of teardown and the disconnection notifications.
 *
 * `close()` routes every fragile Android teardown call through
 * [runTeardownQuietly] and then unconditionally fires the notifications, so
 * these tests lock in the two guarantees that keep the crash fixed: a throwing
 * step never aborts the later steps, and the helper never propagates.
 */
class ConnectedDeviceCloseTest {

    @Test
    fun runsEveryStepEvenWhenSomeThrow() {
        val ran = mutableListOf<String>()

        runTeardownQuietly(
            {
                ran.add("flush")
                throw IOException("write failed: EPIPE (Broken pipe)")
            },
            { ran.add("closeInput") },
            {
                ran.add("closeOutput")
                throw IllegalStateException("already closed")
            },
            { ran.add("closeDevice") },
        )

        assertEquals(
            listOf("flush", "closeInput", "closeOutput", "closeDevice"),
            ran,
        )
    }

    @Test
    fun neverPropagates() {
        // If this threw, the test would fail; passing proves the EPIPE is
        // swallowed so the notifications after the teardown block in close()
        // always run.
        runTeardownQuietly(
            { throw IOException("write failed: EPIPE (Broken pipe)") },
        )
    }
}
