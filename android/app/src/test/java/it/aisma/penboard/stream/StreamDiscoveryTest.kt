package it.aisma.penboard.stream

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure TXT/endpoint validation (docs/EXECUTION-PLAN.md v1.1, C2, B2 verify):
 * [StreamDiscovery.parseEndpoint] takes plain `Map<String, ByteArray>` rather
 * than [android.net.nsd.NsdServiceInfo], so it runs on the plain JVM without
 * any Android system service.
 */
class StreamDiscoveryTest {

    private fun attrs(vararg pairs: Pair<String, String>): Map<String, ByteArray> =
        pairs.associate { (key, value) -> key to value.toByteArray(Charsets.US_ASCII) }

    @Test
    fun `valid v1 record with a well-formed token resolves to an endpoint`() {
        val endpoint =
            StreamDiscovery.parseEndpoint(
                attrs("v" to "1", "tok" to "0123456789abcdef0123456789abcdef"),
                host = "192.168.1.20",
                port = 54321,
            )
        assertEquals(StreamDiscovery.Endpoint("192.168.1.20", 54321, "0123456789abcdef0123456789abcdef"), endpoint)
    }

    @Test
    fun `missing v key is rejected`() {
        assertNull(StreamDiscovery.parseEndpoint(attrs("tok" to "0123456789abcdef0123456789abcdef"), "h", 1))
    }

    @Test
    fun `v other than 1 is rejected`() {
        assertNull(
            StreamDiscovery.parseEndpoint(attrs("v" to "2", "tok" to "0123456789abcdef0123456789abcdef"), "h", 1)
        )
    }

    @Test
    fun `missing tok key is rejected`() {
        assertNull(StreamDiscovery.parseEndpoint(attrs("v" to "1"), "h", 1))
    }

    @Test
    fun `tok with wrong length is rejected`() {
        assertNull(StreamDiscovery.parseEndpoint(attrs("v" to "1", "tok" to "0123456789abcdef"), "h", 1))
    }

    @Test
    fun `tok with uppercase hex is rejected -- case-sensitive per C2`() {
        assertNull(
            StreamDiscovery.parseEndpoint(attrs("v" to "1", "tok" to "0123456789ABCDEF0123456789ABCDEF"), "h", 1)
        )
    }

    @Test
    fun `tok with non-hex characters is rejected`() {
        assertNull(
            StreamDiscovery.parseEndpoint(attrs("v" to "1", "tok" to "gggggggggggggggggggggggggggggggg"), "h", 1)
        )
    }
}
