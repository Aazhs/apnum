package dev.apnum.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Text
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.apnum.android.sky.Rgb
import dev.apnum.android.sky.SkyTheme

private fun Rgb.c() = Color(toArgb())
private fun Rgb.luminance() = 0.3 * r + 0.59 * g + 0.11 * b

/** Dark Material 3 colours that follow the sun, like the Mac app: ground, near and mid ridges, and the sky accent. */
fun skyColorScheme(sky: SkyTheme) = darkColorScheme(
    primary = sky.primary.c(),
    onPrimary = if (sky.primary.luminance() > 0.45) Color(0xFF14111F) else Color.White,
    primaryContainer = sky.surfaceHigh.c(),
    onPrimaryContainer = Color(0xFFF2F1F8),
    secondary = sky.primary.mix(Rgb(1.0, 1.0, 1.0), 0.25).c(),
    background = sky.background.c(),
    onBackground = Color(0xFFEFEFF6),
    surface = sky.surface.c(),
    onSurface = Color(0xFFEFEFF6),
    surfaceVariant = sky.surfaceHigh.c(),
    onSurfaceVariant = Color(0xFFCFCFDC),
    surfaceContainer = sky.surface.c(),
    surfaceContainerHigh = sky.surfaceHigh.c(),
    surfaceContainerHighest = sky.surfaceHigh.mix(Rgb(1.0, 1.0, 1.0), 0.06).c(),
    outline = Color(0x66FFFFFF),
    outlineVariant = Color(0x22FFFFFF),
    error = Color(0xFFFFB4AB),
)

private val base = TextStyle(fontFamily = FontFamily.SansSerif)

private val typography = Typography(
    displayLarge = base.copy(fontSize = 64.sp, fontWeight = FontWeight.ExtraLight, letterSpacing = (-1).sp),
    displayMedium = base.copy(fontSize = 48.sp, fontWeight = FontWeight.ExtraLight, letterSpacing = (-0.5).sp),
    displaySmall = base.copy(fontSize = 36.sp, fontWeight = FontWeight.Thin),
    headlineMedium = base.copy(fontSize = 28.sp, fontWeight = FontWeight.Light),
    titleLarge = base.copy(fontSize = 22.sp, fontWeight = FontWeight.Normal),
    titleMedium = base.copy(fontSize = 16.sp, fontWeight = FontWeight.Medium),
    bodyLarge = base.copy(fontSize = 16.sp, fontWeight = FontWeight.Normal),
    bodyMedium = base.copy(fontSize = 14.sp, fontWeight = FontWeight.Normal),
    labelLarge = base.copy(fontSize = 14.sp, fontWeight = FontWeight.Medium),
    labelMedium = base.copy(fontSize = 12.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.5.sp),
)

private val shapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp), small = RoundedCornerShape(14.dp), medium = RoundedCornerShape(20.dp),
    large = RoundedCornerShape(28.dp), extraLarge = RoundedCornerShape(36.dp),
)

@Composable
fun ApnumTheme(sky: SkyTheme, content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = skyColorScheme(sky), typography = typography, shapes = shapes, content = content)
}

/** A calm rounded card with a small title, used for each section of the home screen. */
@Composable
fun Section(title: String, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Card(
        modifier = modifier,
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
            content()
        }
    }
}
