package it.aisma.penboard.ui

import androidx.core.graphics.toColorInt

/** The v1 color palette (PROTOCOL §7). List index is the wire value for SET_COLOR. */
object Palette {
    val COLORS: List<Int> =
        listOf(
            "#E5484D".toColorInt(), // 0 Red
            "#3B82F6".toColorInt(), // 1 Blue
            "#30A46C".toColorInt(), // 2 Green
            "#F5D90A".toColorInt(), // 3 Yellow
            "#111111".toColorInt(), // 4 Black
            "#FFFFFF".toColorInt(), // 5 White
        )

    const val DEFAULT_INDEX = 4 // Black

    fun colorFor(index: Int): Int = COLORS.getOrElse(index) { COLORS[DEFAULT_INDEX] }
}
