package it.aisma.penboard.ui

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.util.AttributeSet
import android.view.LayoutInflater
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import it.aisma.penboard.R

/**
 * Compact, edge-docked toolbar (PLAN.md: mode / color / width / undo / clear /
 * connection status). Plain custom View + XML per decision D2 -- no Compose,
 * no Material Components (dependency policy: androidx core/appcompat only),
 * so controls are plain [Button]s and hand-drawn color swatches rather than
 * Material chips/sliders.
 *
 * Every control invokes [listener] (so the caller can send the matching
 * CONTROL packet, PROTOCOL §5, and apply it locally) *and* updates its own
 * visual state immediately on click. The `setXxx` methods below let the
 * caller push state back in (persisted prefs on startup, inbound STATE_SYNC
 * from the Mac) without re-triggering the listener, since those are direct
 * property writes, not click events -- this is what avoids an echo loop
 * between "Mac told us to change color" and "tell the Mac to change color".
 */
class Toolbar
@JvmOverloads
constructor(context: Context, attrs: AttributeSet? = null, defStyleAttr: Int = 0) :
    LinearLayout(context, attrs, defStyleAttr) {

    interface Listener {
        fun onModeChanged(mode: Int)

        fun onColorSelected(colorIndex: Int)

        fun onWidthSelected(width: Int)

        fun onUndoClicked()

        fun onClearClicked()

        fun onDimToggled(enabled: Boolean)
    }

    var listener: Listener? = null

    private val connectionStatusText: TextView
    private val modeButton: Button
    private val dimButton: Button
    private val swatchViews: List<View>
    private val widthButtons: List<Button>

    private var mode = PenBoardPrefs.MODE_DRAW
    private var dimEnabled = false
    private var selectedColorIndex = Palette.DEFAULT_INDEX
    private var selectedWidth = PenBoardPrefs.DEFAULT_WIDTH

    init {
        orientation = VERTICAL
        LayoutInflater.from(context).inflate(R.layout.view_toolbar, this, true)

        connectionStatusText = findViewById(R.id.connectionStatusText)
        modeButton = findViewById(R.id.modeButton)
        dimButton = findViewById(R.id.dimButton)
        widthButtons =
            listOf(
                findViewById<Button>(R.id.widthButtonS).apply { tag = WIDTH_SMALL },
                findViewById<Button>(R.id.widthButtonM).apply { tag = WIDTH_MEDIUM },
                findViewById<Button>(R.id.widthButtonL).apply { tag = WIDTH_LARGE },
                findViewById<Button>(R.id.widthButtonXl).apply { tag = WIDTH_XLARGE },
            )
        val swatchRow = findViewById<LinearLayout>(R.id.colorSwatchRow)
        swatchViews = Palette.COLORS.indices.map { index -> buildSwatch(swatchRow, index) }

        modeButton.setOnClickListener {
            mode = if (mode == PenBoardPrefs.MODE_DRAW) PenBoardPrefs.MODE_LASER else PenBoardPrefs.MODE_DRAW
            applyModeAppearance()
            listener?.onModeChanged(mode)
        }
        dimButton.setOnClickListener {
            dimEnabled = !dimEnabled
            applyDimAppearance()
            listener?.onDimToggled(dimEnabled)
        }
        widthButtons.forEach { button ->
            button.setOnClickListener {
                selectedWidth = button.tag as Int
                applyWidthAppearance()
                listener?.onWidthSelected(selectedWidth)
            }
        }
        findViewById<Button>(R.id.undoButton).setOnClickListener { listener?.onUndoClicked() }
        findViewById<Button>(R.id.clearButton).setOnClickListener { listener?.onClearClicked() }

        applyModeAppearance()
        applyDimAppearance()
        applyWidthAppearance()
        applySwatchAppearance()
    }

    fun setConnectionStatus(text: String) {
        connectionStatusText.text = text
    }

    fun setMode(newMode: Int) {
        mode = newMode
        applyModeAppearance()
    }

    fun setColorIndex(index: Int) {
        selectedColorIndex = index
        applySwatchAppearance()
    }

    fun setWidth(width: Int) {
        selectedWidth = width
        applyWidthAppearance()
    }

    fun setDimEnabled(enabled: Boolean) {
        dimEnabled = enabled
        applyDimAppearance()
    }

    private fun buildSwatch(row: LinearLayout, index: Int): View {
        val size = (SWATCH_SIZE_DP * resources.displayMetrics.density).toInt()
        val margin = (SWATCH_MARGIN_DP * resources.displayMetrics.density).toInt()
        val swatch = View(context)
        val params = LinearLayout.LayoutParams(size, size)
        params.setMargins(margin, margin, margin, margin)
        swatch.layoutParams = params
        swatch.contentDescription = resources.getStringArray(R.array.palette_names)[index]
        swatch.setOnClickListener {
            selectedColorIndex = index
            applySwatchAppearance()
            listener?.onColorSelected(index)
        }
        row.addView(swatch)
        return swatch
    }

    private fun applySwatchAppearance() {
        swatchViews.forEachIndexed { index, view ->
            val drawable = GradientDrawable()
            drawable.shape = GradientDrawable.RECTANGLE
            drawable.setColor(Palette.COLORS[index])
            val selected = index == selectedColorIndex
            val strokeWidthPx = (if (selected) 4 else 1) * resources.displayMetrics.density
            drawable.setStroke(strokeWidthPx.toInt(), if (selected) Color.WHITE else Color.DKGRAY)
            view.background = drawable
        }
    }

    private fun applyModeAppearance() {
        modeButton.text = resources.getString(if (mode == PenBoardPrefs.MODE_LASER) R.string.mode_laser else R.string.mode_draw)
    }

    private fun applyDimAppearance() {
        dimButton.text = resources.getString(if (dimEnabled) R.string.dim_on else R.string.dim_off)
    }

    private fun applyWidthAppearance() {
        widthButtons.forEach { it.alpha = if (it.tag == selectedWidth) 1.0f else 0.5f }
    }

    companion object {
        private const val SWATCH_SIZE_DP = 28
        private const val SWATCH_MARGIN_DP = 4

        const val WIDTH_SMALL = 2
        const val WIDTH_MEDIUM = 6
        const val WIDTH_LARGE = 14
        const val WIDTH_XLARGE = 28
    }
}
