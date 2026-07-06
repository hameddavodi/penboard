# PenBoard release R8 rules.
#
# The app has zero third-party runtime dependencies (AndroidX core/appcompat
# only, both of which ship their own consumer-rules.pro that AGP merges in
# automatically). Activity/Service classes declared in AndroidManifest.xml
# and referenced Intent component classes are kept automatically by AGP's
# manifest-derived rules -- no entries needed here for MainActivity or
# PenBoardService. BLE callbacks (PenGattServer's BluetoothGattServerCallback,
# PenBoardService's PenGattServer.Callback) are plain anonymous `object :`
# expressions with direct static references, not reflection -- R8 traces
# these fine with no keep rules.
#
# The one reflection-adjacent surface: custom Views inflated from XML by
# fully-qualified class name (LayoutInflater looks up the (Context,
# AttributeSet) constructor by string). AGP's aapt-derived keep rules cover
# this automatically, but this project has no instrumented/Espresso test to
# verify that at runtime post-shrink, so keep both explicitly rather than
# relying solely on the implicit mechanism.
-keep public class it.aisma.penboard.ui.PadView {
    public <init>(...);
}
-keep public class it.aisma.penboard.ui.Toolbar {
    public <init>(...);
}
