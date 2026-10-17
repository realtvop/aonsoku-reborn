package github.realtvop.aonsoku.plugins.debug

import android.util.Log
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.mockito.MockedStatic
import org.mockito.Mockito

class NativeLoggerTest {
    private lateinit var mockedLog: MockedStatic<Log>

    @Before
    fun setUp() {
        mockedLog = Mockito.mockStatic(Log::class.java)
        mockedLog.`when`<Int> { Log.d(Mockito.anyString(), Mockito.anyString()) }.thenReturn(0)
        mockedLog.`when`<Int> { Log.i(Mockito.anyString(), Mockito.anyString()) }.thenReturn(0)
        mockedLog.`when`<Int> { Log.w(Mockito.anyString(), Mockito.anyString()) }.thenReturn(0)
        mockedLog.`when`<Int> { Log.e(Mockito.anyString(), Mockito.anyString()) }.thenReturn(0)
    }

    @After
    fun tearDown() {
        mockedLog.close()
    }

    @Test
    fun testLogAndRetrieve() {
        NativeLogger.clear()
        NativeLogger.debug("debug message", "test-source")
        NativeLogger.info("info message", "test-source")
        NativeLogger.warn("warn message", "test-source")
        NativeLogger.error("error message", "test-source")

        val entries = NativeLogger.getEntries()
        assertEquals(4, entries.size)
        assertEquals(NativeLogger.Entry.Level.DEBUG, entries[0].level)
        assertEquals("debug message", entries[0].message)
        assertEquals("test-source", entries[0].source)
        assertEquals(NativeLogger.Entry.Level.ERROR, entries[3].level)
    }

    @Test
    fun testLogWithoutSource() {
        NativeLogger.clear()
        NativeLogger.info("no source message")

        val entries = NativeLogger.getEntries()
        assertEquals(1, entries.size)
        assertEquals("", entries[0].source)
    }

    @Test
    fun testMaxEntriesPerSource() {
        NativeLogger.clear()
        for (i in 0 until 250) {
            NativeLogger.debug("Message $i", "heavy-source")
        }

        val entries = NativeLogger.getEntries()
        assertEquals(200, entries.size)
        assertEquals("Message 50", entries[0].message)
        assertEquals("Message 249", entries[199].message)
    }

    @Test
    fun testMultipleSources() {
        NativeLogger.clear()
        NativeLogger.info("src1 msg1", "source1")
        Thread.sleep(2)
        NativeLogger.info("src2 msg1", "source2")
        Thread.sleep(2)
        NativeLogger.info("src1 msg2", "source1")

        val entries = NativeLogger.getEntries()
        assertEquals(3, entries.size)
        assertEquals("source1", entries[0].source)
        assertEquals("source2", entries[1].source)
        assertEquals("source1", entries[2].source)
    }

    @Test
    fun testClear() {
        NativeLogger.clear()
        NativeLogger.debug("test", "test-source")
        assertTrue(NativeLogger.getEntries().isNotEmpty())

        NativeLogger.clear()
        assertTrue(NativeLogger.getEntries().isEmpty())
    }

    @Test
    fun testTimestampOrder() {
        NativeLogger.clear()
        NativeLogger.debug("first")
        NativeLogger.debug("second")
        NativeLogger.debug("third")

        val entries = NativeLogger.getEntries()
        assertEquals(3, entries.size)
        assertTrue(entries[0].timestamp <= entries[1].timestamp)
        assertTrue(entries[1].timestamp <= entries[2].timestamp)
    }

    @Test
    fun testIndependentSourceBuckets() {
        NativeLogger.clear()
        for (i in 0 until 300) {
            NativeLogger.debug("heavy $i", "heavy")
        }
        NativeLogger.info("light message", "light")

        val entries = NativeLogger.getEntries()
        assertEquals(201, entries.size)
        assertEquals("light", entries[200].source)
    }
}
