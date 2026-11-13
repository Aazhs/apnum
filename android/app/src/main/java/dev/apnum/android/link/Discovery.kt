package dev.apnum.android.link

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.net.Inet4Address
import java.net.InetAddress

/** A Mac advertising `_apnum._tcp`. */
data class FoundMac(val name: String, val id: String?, val host: String, val port: Int)

interface MacDiscovery {
    val found: StateFlow<List<FoundMac>>
    fun start()
    fun stop()
}

@Suppress("DEPRECATION")
class NsdDiscovery(context: Context) : MacDiscovery {
    private val nsd = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val state = MutableStateFlow<List<FoundMac>>(emptyList())
    override val found: StateFlow<List<FoundMac>> = state

    private var listener: NsdManager.DiscoveryListener? = null
    private val queue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    @Synchronized
    override fun start() {
        if (listener != null) return
        state.value = emptyList()
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { synchronized(this@NsdDiscovery) { listener = null } }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) = enqueue(info)
            override fun onServiceLost(info: NsdServiceInfo) {
                state.value = state.value.filterNot { it.name == info.serviceName }
            }
        }
        listener = l
        runCatching { nsd.discoverServices("_apnum._tcp", NsdManager.PROTOCOL_DNS_SD, l) }.onFailure { listener = null }
    }

    @Synchronized
    override fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        queue.clear()
        resolving = false
    }

    @Synchronized
    private fun enqueue(info: NsdServiceInfo) {
        queue.addLast(info)
        next()
    }

    // Older Android allows one resolve at a time.
    @Synchronized
    private fun next() {
        if (resolving) return
        val info = queue.removeFirstOrNull() ?: return
        resolving = true
        val done = { synchronized(this) { resolving = false; next() } }
        runCatching {
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = done()
                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    toFound(serviceInfo)?.let { f -> state.value = state.value.filterNot { it.name == f.name } + f }
                    done()
                }
            })
        }.onFailure { done() }
    }

    private fun toFound(i: NsdServiceInfo): FoundMac? {
        val addresses: List<InetAddress> =
            if (Build.VERSION.SDK_INT >= 34) i.hostAddresses else listOfNotNull(i.host)
        val address = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull() ?: return null
        val host = (address.hostAddress ?: return null).substringBefore('%')
        val id = i.attributes["id"]?.toString(Charsets.UTF_8)
        return FoundMac(i.serviceName, id, host, i.port)
    }
}
