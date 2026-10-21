package it.aisma.penboard.stream

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.Executor

/**
 * Browses for the Mac's screen-stream Bonjour service (docs/EXECUTION-PLAN.md
 * v1.1, contracts C1/C2) and resolves the first instance whose TXT record is
 * valid, handing the caller a ready-to-dial (host, port, token) endpoint.
 *
 * TXT-record validation itself lives in the pure [parseEndpoint] companion
 * function, which takes plain Kotlin types (`Map<String, ByteArray>`, not
 * [NsdServiceInfo]) so it is unit-testable on the plain JVM like
 * proto/Packets.kt; everything else here is Android system-API plumbing,
 * exercised by device smoke testing instead (EXECUTION-PLAN B2 verify).
 *
 * Resolution is version-gated (fetched docs,
 * internal docs): API 34+ uses
 * [NsdManager.registerServiceInfoCallback], which keeps delivering fresh TXT
 * updates for the life of the registration -- exactly what a Mac-side
 * toggle-off/on (new token, same advertised instance name) needs. API 29-33
 * falls back to the deprecated one-shot [NsdManager.resolveService]; on that
 * range a fresh resolve is instead triggered by the discovery-level
 * found/lost cycle that Bonjour service withdrawal + re-advertisement (C1)
 * naturally produces on every Mac-side toggle.
 *
 * "First service wins" (C1, Open Decision D-5): once one service has started
 * resolving, every other [NsdManager.DiscoveryListener.onServiceFound] is
 * ignored until that one is lost.
 *
 * Threading: all state here is main-thread confined. NsdManager delivers
 * DiscoveryListener/ResolveListener callbacks on its own internal thread, so
 * those hop to main first and then drop themselves if [stop] (or a newer
 * [start]) has superseded their listener -- otherwise a callback already
 * queued when the user toggled streaming off could resolve and restart it.
 */
class StreamDiscovery(private val streamListener: Listener) {

    interface Listener {
        /** A valid endpoint is available -- (re)connect. May fire again later with a different token (Mac toggle off/on) while the same instance stays resolved. */
        fun onEndpoint(host: String, port: Int, token: String)

        /** The resolved (or being-resolved) service went away -- stop streaming and wait for a fresh onEndpoint. */
        fun onLost()
    }

    /** Pure result of validating one service's host/port/TXT against C1/C2. */
    data class Endpoint(val host: String, val port: Int, val token: String)

    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainThreadExecutor = Executor { command -> mainHandler.post(command) }

    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    /** Name of the service instance currently resolved (or being resolved); null when idle. Enforces first-wins (C1/D-5). */
    private var activeServiceName: String? = null
    private var activeResolveListener: NsdManager.ResolveListener? = null
    private var activeServiceInfoCallback: NsdManager.ServiceInfoCallback? = null
    private var lastEmitted: Endpoint? = null

    /** Idempotent: a second start() while already running is a no-op (repo pattern -- NSD listeners leak if double-registered). */
    fun start(manager: NsdManager) {
        if (discoveryListener != null) return
        nsdManager = manager

        val discovery =
            object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) {
                    Log.i(TAG, "discovery started for $serviceType")
                }

                override fun onServiceFound(service: NsdServiceInfo) = onMainIfCurrent {
                    if (activeServiceName != null) return@onMainIfCurrent // C1/D-5: first-wins, ignore any other Mac
                    activeServiceName = service.serviceName
                    resolve(manager, service)
                }

                override fun onServiceLost(service: NsdServiceInfo) = onMainIfCurrent {
                    if (service.serviceName != activeServiceName) return@onMainIfCurrent
                    cancelActiveResolution()
                    activeServiceName = null
                    lastEmitted = null
                    streamListener.onLost()
                }

                override fun onDiscoveryStopped(serviceType: String) {
                    Log.i(TAG, "discovery stopped for $serviceType")
                }

                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = onMainIfCurrent {
                    Log.w(TAG, "start discovery failed: $errorCode")
                    runCatching { manager.stopServiceDiscovery(this) }
                    discoveryListener = null
                }

                /** Runs [body] on main, only if this listener is still the active discovery. */
                private fun onMainIfCurrent(body: () -> Unit) {
                    mainHandler.post { if (discoveryListener === this) body() }
                }

                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                    // Mirrors the official sample: retry once rather than
                    // risk leaking a listener the system still thinks is registered.
                    Log.w(TAG, "stop discovery failed: $errorCode")
                    runCatching { manager.stopServiceDiscovery(this) }
                }
            }
        discoveryListener = discovery
        manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
    }

    /** Idempotent: safe to call when not running, or twice in a row. */
    fun stop() {
        val manager = nsdManager
        val discovery = discoveryListener
        if (manager != null && discovery != null) {
            runCatching { manager.stopServiceDiscovery(discovery) }
        }
        cancelActiveResolution()
        discoveryListener = null
        nsdManager = null
        activeServiceName = null
        lastEmitted = null
    }

    private fun resolve(manager: NsdManager, service: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            resolveModern(manager, service)
        } else {
            resolveLegacy(manager, service)
        }
    }

    private fun resolveModern(manager: NsdManager, service: NsdServiceInfo) {
        val callback =
            object : NsdManager.ServiceInfoCallback {
                override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                    if (activeServiceInfoCallback !== this) return
                    Log.w(TAG, "registerServiceInfoCallback failed: $errorCode")
                    activeServiceInfoCallback = null
                    activeServiceName = null
                }

                override fun onServiceUpdated(serviceInfo: NsdServiceInfo) {
                    if (activeServiceInfoCallback !== this) return
                    handleResolved(serviceInfo)
                }

                override fun onServiceLost() {
                    if (activeServiceInfoCallback !== this) return
                    activeServiceInfoCallback = null
                    activeServiceName = null
                    lastEmitted = null
                    streamListener.onLost() // already on main (mainThreadExecutor)
                }

                override fun onServiceInfoCallbackUnregistered() {
                    if (activeServiceInfoCallback === this) activeServiceInfoCallback = null
                }
            }
        activeServiceInfoCallback = callback
        manager.registerServiceInfoCallback(service, mainThreadExecutor, callback)
    }

    // resolveService is deprecated at API 34+ (in favor of registerServiceInfoCallback,
    // used by resolveModern above) but is the only resolution API on API 29-33,
    // which this app still supports (minSdk 29) -- deliberate use, not an oversight.
    @Suppress("DEPRECATION")
    private fun resolveLegacy(manager: NsdManager, service: NsdServiceInfo) {
        val resolveListener =
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    mainHandler.post {
                        if (activeResolveListener !== this) return@post
                        Log.w(TAG, "resolveService failed: $errorCode")
                        activeResolveListener = null
                        activeServiceName = null
                    }
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    mainHandler.post {
                        if (activeResolveListener !== this) return@post
                        activeResolveListener = null
                        handleResolved(serviceInfo)
                    }
                }
            }
        activeResolveListener = resolveListener
        manager.resolveService(service, resolveListener)
    }

    // NsdServiceInfo.host is deprecated at API 34+ (in favor of the plural
    // getHostAddresses(), for dual-stack IPv4/IPv6 services) but is the only
    // host accessor on API 29-33, which this app still supports (minSdk 29);
    // a single MJPEG endpoint only ever needs one address either way.
    @Suppress("DEPRECATION")
    private fun handleResolved(serviceInfo: NsdServiceInfo) {
        val host = serviceInfo.host?.hostAddress
        if (host == null) {
            Log.w(TAG, "resolved service has no host address")
            return
        }
        val endpoint = parseEndpoint(serviceInfo.attributes, host, serviceInfo.port)
        if (endpoint == null) {
            Log.w(TAG, "ignoring service with invalid/absent TXT record (C2)")
            return
        }
        if (endpoint == lastEmitted) return // no-op refresh -- nothing actually changed
        lastEmitted = endpoint
        streamListener.onEndpoint(endpoint.host, endpoint.port, endpoint.token) // always called on main
    }

    /** Pre-34: no cancel API for an in-flight resolveService() call -- the reference-identity guards inside its own callbacks discard it once it's no longer active. */
    private fun cancelActiveResolution() {
        activeResolveListener = null
        val callback = activeServiceInfoCallback
        if (callback != null) {
            activeServiceInfoCallback = null
            val manager = nsdManager
            if (manager != null) runCatching { manager.unregisterServiceInfoCallback(callback) }
        }
    }

    companion object {
        private const val TAG = "StreamDiscovery"

        /** Bonjour service type (C1) -- byte-identical to the Mac's NWListener.Service type string. */
        const val SERVICE_TYPE = "_penboard-stream._tcp"

        private val TOKEN_PATTERN = Regex("^[0-9a-f]{32}$")

        /**
         * Validates one resolved service's TXT record against C2: "v" must be
         * exactly "1"; "tok" must be 32 lowercase hex characters. Returns null
         * for anything else (absent keys, wrong version, malformed token) --
         * per C2, an invalid/absent record means the tablet ignores the
         * service entirely rather than guessing.
         */
        fun parseEndpoint(attributes: Map<String, ByteArray>, host: String, port: Int): Endpoint? {
            val version = attributes["v"]?.toString(Charsets.US_ASCII) ?: return null
            if (version != "1") return null
            val token = attributes["tok"]?.toString(Charsets.US_ASCII) ?: return null
            if (!TOKEN_PATTERN.matches(token)) return null
            return Endpoint(host, port, token)
        }
    }
}
