import SwiftUI
import AppKit

// ╔══════════════════════════════════════════════════════════════════╗
// ║  DESIGN TOKENS — aquí vive todo el estilo visual de Fluxio.       ║
// ║                                                                  ║
// ║  Es el ÚNICO archivo de tema: las vistas no llevan números ni     ║
// ║  colores escritos a mano, todo sale de aquí. Puedes cambiar       ║
// ║  colores, tamaños, radios, sombras y tipografías sin tocar el     ║
// ║  resto del código. Después vuelve a ejecutar ./build_and_run.sh.  ║
// ║                                                                  ║
// ║  Basado en el sistema de diseño (DESIGN.md): tipografía Inter,    ║
// ║  rejilla de 8 pt, radios 6/8/16/20, bordes finos y la sombra      ║
// ║  "tecla". Los colores son los de Fluxio (no los del sistema).     ║
// ║                                                                  ║
// ║  Colores: escribe el hex como 0xRRGGBB (ej: 0x00B9FD).            ║
// ║  Cada color tiene versión para modo claro (light) y oscuro (dark).║
// ╚══════════════════════════════════════════════════════════════════╝

enum DesignTokens {

    // MARK: - Colores

    enum Colors {
        // ── Marca ──────────────────────────────────────────────────
        /// Color de acento principal (azul cian de la marca Fluxio).
        static let accent = Color.dynamic(light: 0x00B9FD, dark: 0x00B9FD)
        /// Segundo color de la marca (violeta): final del degradado.
        static let accentEnd = Color.dynamic(light: 0x8363FB, dark: 0x8363FB)
        /// Degradado de la marca, de cian a violeta en diagonal (como el logo).
        /// Se usa en la opción resaltada de la rueda, el botón principal y la selección.
        static let accentGradient = LinearGradient(colors: [accent, accentEnd],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
        /// Igual, pero de izquierda a derecha (para elementos horizontales como la línea de tiempo).
        static let accentGradientHorizontal = LinearGradient(colors: [accent, accentEnd],
                                                             startPoint: .leading, endPoint: .trailing)
        /// Acento suave, usado en fondos de opciones resaltadas.
        static let accentSoft = Color.dynamic(light: 0x00B9FD, dark: 0x00B9FD, opacity: 0.18)
        /// Texto sobre el acento (por ejemplo, la opción seleccionada).
        /// Azul noche del fondo del logo: se lee bien sobre los dos colores del degradado.
        static let onAccent = Color.dynamic(light: 0x020614, dark: 0x020614)

        /// Botón principal: cian sólido con texto azul noche (contraste 9:1; el blanco sobre cian solo da 2,2:1).
        static let primaryButton = accent
        static let onPrimaryButton = onAccent

        // ── Superficies (neutros aprobados para el modo Completo) ──
        /// Fondo de la ventana (nivel 0).
        static let canvas = Color.dynamic(light: 0xF5F5F7, dark: 0x040506)
        /// Barra lateral y tarjetas (nivel 1).
        static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x07080A)
        /// Campos de texto, pozos y etiquetas (nivel 2, "hundido").
        static let recessed = Color.dynamic(light: 0xEDEDEF, dark: 0x111214)
        /// Pastilla de la pestaña elegida (blanca en claro, gris elevado en oscuro).
        static let tabPill = Color.dynamic(light: 0xFFFFFF, dark: 0x2A2B2F)
        /// Bordes finos de tarjetas, campos y separadores.
        static let border = Color.dynamic(light: 0xDCDCE0, dark: 0x363739)

        // ── Rueda radial ───────────────────────────────────────────
        /// Relleno de cada "gajo" de la rueda en reposo.
        static let sliceFill = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 0.55, darkOpacity: 0.08)
        /// Fondo de la rueda, su pastilla y las tarjetas flotantes: casi blanco en claro, como en Windows.
        /// Casi opaco a propósito: así no se oscurece por un lado cuando detrás hay algo negro.
        static let glass = Color.dynamic(light: 0xF6F6F8, dark: 0x28282A, lightOpacity: 0.98, darkOpacity: 0.98)
        /// Borde fino de los gajos.
        static let sliceStroke = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightOpacity: 0.08, darkOpacity: 0.10)

        // ── Texto ──────────────────────────────────────────────────
        /// Texto principal y secundario (los de macOS: se adaptan solos al tema).
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary

        // ── Estados ────────────────────────────────────────────────
        static let success = Color.dynamic(light: 0x2EA44F, dark: 0x3FCB65)
        static let error = Color.dynamic(light: 0xD73A49, dark: 0xFF6B6B)
        /// Aviso (ej: el comando de Terminal apunta a otra copia de Fluxio).
        static let warning = Color.orange

        // ── Edición de imagen y video ──────────────────────────────
        /// Fondo de la línea de tiempo cuando no hay miniaturas (audio).
        static let timelineTrack = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightOpacity: 0.08, darkOpacity: 0.12)
        /// Oscurecido de lo que queda fuera del corte o del recorte.
        static let scrim = Color.black.opacity(0.45)
        static let scrimStrong = Color.black.opacity(0.55)
        /// Línea de posición de reproducción y asas del recorte.
        static let playhead = Color.white
        /// Líneas guía (tercios) dentro del recorte.
        static let guide = Color.white.opacity(0.5)

        /// Línea punteada de la zona para soltar archivos.
        static let dropZoneStroke = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightOpacity: 0.18, darkOpacity: 0.22)
    }

    // MARK: - Espaciados (rejilla de 8 pt; 4 y 12 para ajustes finos)

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 40
        /// Relleno interior de las tarjetas.
        static let cardPadding: CGFloat = 24
        /// Relleno de los botones (vertical × horizontal).
        static let buttonV: CGFloat = 8
        static let buttonH: CGFloat = 12
    }

    // MARK: - Radios de esquina

    enum Radius {
        /// Etiquetas pequeñas (versión, extensiones).
        static let badge: CGFloat = 6
        /// Botones y campos de texto.
        static let button: CGFloat = 8
        static let input: CGFloat = 8
        /// Tarjetas.
        static let card: CGFloat = 16
        /// Tarjetas grandes: las de la ventana flotante (zona para soltar, progreso, resultado).
        static let largeCard: CGFloat = 20
        /// Cápsulas (formatos, filtros).
        static let pill: CGFloat = 9999
        /// Esquinas de cada gajo de la rueda (0 = en punta). Se limita solo si el gajo es muy estrecho.
        static let slice: CGFloat = 12
        /// Miniaturas de la línea de tiempo.
        static let thumbnail: CGFloat = 4
    }

    // MARK: - Bordes

    enum Stroke {
        /// Borde fino ("hairline") de tarjetas, campos y gajos.
        static let hairline: CGFloat = 1
        /// Borde de la zona para soltar cuando arrastras algo encima.
        static let focus: CGFloat = 2
        /// Línea punteada de la zona para soltar.
        static let dropZone: CGFloat = 1.5
        static let dropZoneDash: [CGFloat] = [5, 4]
        /// Borde punteado de los botones desactivados.
        static let disabledDash: [CGFloat] = [3, 3]
        /// Separación entre la tarjeta y su línea punteada.
        static let dropZoneInset: CGFloat = 6
    }

    // MARK: - Tipografía (Inter, incluida en la app; SF Pro solo para iconos)

    enum Typography {
        /// Un estilo de texto: tamaño, peso, espaciado entre letras (tracking) e interlineado.
        struct Style {
            let size: CGFloat
            let weight: Weight
            /// Espacio extra entre letras, en puntos (positivo, como pide el sistema de diseño).
            let tracking: CGFloat
            /// Alto de línea como múltiplo del tamaño (solo afecta a textos de varias líneas).
            let lineHeight: CGFloat
            var uppercase = false
            var monospaced = false

            var font: Font { Fonts.font(self) }
        }

        enum Weight: CGFloat {
            case regular = 400, medium = 500, semibold = 600, bold = 700
        }

        /// Etiqueta en mayúsculas (encabezados de grupo).
        static let eyebrow = Style(size: 11, weight: .medium, tracking: 0.8, lineHeight: 1.2, uppercase: true)
        /// Textos pequeños: notas, ayudas.
        static let caption = Style(size: 12, weight: .regular, tracking: 0.1, lineHeight: 1.4)
        /// Texto normal de la interfaz.
        static let body = Style(size: 13, weight: .regular, tracking: 0.1, lineHeight: 1.4)
        /// Etiquetas de navegación, botones y tarjetas.
        static let label = Style(size: 13, weight: .medium, tracking: 0.1, lineHeight: 1.2)
        /// Etiquetas más grandes (filas de la lista, barra lateral).
        static let labelLarge = Style(size: 14, weight: .medium, tracking: 0.2, lineHeight: 1.2)
        /// Título de una tarjeta.
        static let headline = Style(size: 16, weight: .semibold, tracking: 0, lineHeight: 1.15)
        /// Subtítulos de sección.
        static let subheading = Style(size: 20, weight: .medium, tracking: 0.2, lineHeight: 1.2)
        /// Título de página.
        static let title = Style(size: 24, weight: .semibold, tracking: 0, lineHeight: 1.15)
        /// Nombre de cada pestaña de Ajustes (normal y elegida).
        static let tab = Style(size: 11, weight: .regular, tracking: 0.2, lineHeight: 1.1)
        static let tabSelected = Style(size: 11, weight: .semibold, tracking: 0.2, lineHeight: 1.1)
        /// Datos técnicos: versión, rutas, comandos (monoespaciada).
        static let mono = Style(size: 12, weight: .regular, tracking: 0.2, lineHeight: 1.4, monospaced: true)

        // Rueda radial
        /// Texto dentro de cada opción de la rueda (ej: "PNG").
        static let sliceLabel = Style(size: 13, weight: .semibold, tracking: 0.1, lineHeight: 1.1)
        /// Texto bajo el icono del centro de la rueda.
        static let wheelCenter = Style(size: 11, weight: .semibold, tracking: 0.2, lineHeight: 1.1)
        /// Pistas pequeñas en el centro de la rueda ("⇥ cambiar").
        static let wheelHint = Style(size: 10, weight: .regular, tracking: 0.3, lineHeight: 1.1)
    }

    // MARK: - Iconos (SF Symbols)

    enum IconSize {
        static let small: CGFloat = 14
        /// Iconos de cada opción de la rueda.
        static let slice: CGFloat = 17
        static let medium: CGFloat = 18
        static let large: CGFloat = 20
        /// Iconos de las pestañas de Ajustes (y alto de su caja).
        static let tab: CGFloat = 19
        static let tabBox: CGFloat = 22
        /// Icono de la zona para soltar.
        static let hero: CGFloat = 30
        /// Iconos de la barra lateral y de la zona para soltar del modo Completo.
        static let nav: CGFloat = 15
        static let dropZone: CGFloat = 24
    }

    // MARK: - Sombras y elevación

    enum Shadow {
        struct Layer {
            let color: Color
            let radius: CGFloat
            let y: CGFloat
        }

        /// Ventanas flotantes (rueda, tarjetas sobre el escritorio): sombra amplia y suave.
        static let floating = [Layer(color: .black.opacity(0.4), radius: 20, y: 4)]
        /// Botón principal: elevación sutil.
        static let lift = [Layer(color: .black.opacity(0.25), radius: 2, y: 2),
                           Layer(color: .black.opacity(0.03), radius: 1.5, y: 3.5)]

        /// Sombra "tecla" (dentro de tarjetas y botones): brillo arriba y sombra abajo, por dentro.
        static let keyHighlight = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 0.8, darkOpacity: 0.05)
        static let keyShade = Color.dynamic(light: 0x000000, dark: 0x000000, lightOpacity: 0.05, darkOpacity: 0.2)
    }

    // MARK: - Estados de los controles

    enum State {
        /// Al pasar el ratón: se aclara un poco.
        static let hoverBrightness: Double = 0.04
        /// Al pulsar: se encoge muy poco (sin volverse transparente, para no perder contraste).
        static let pressedScale: CGFloat = 0.98
        /// Controles bloqueados que no son botones (ej: el formato de un archivo que se está convirtiendo).
        static let disabledOpacity: Double = 0.4
    }

    // MARK: - Geometría de la rueda radial

    enum Wheel {
        /// Radio exterior de la rueda.
        static let outerRadius: CGFloat = 150
        /// Radio del círculo central (zona "cancelar").
        static let innerRadius: CGFloat = 58
        /// Separación entre gajos.
        static let sliceGap: CGFloat = 4
        /// Cuánto crece el gajo resaltado.
        static let hoverScale: CGFloat = 1.06
        /// Margen alrededor de la rueda (para el fondo translúcido).
        static let backdropPadding: CGFloat = 10
        /// Franja encima de la rueda con la categoría («Convertir a», «Herramientas»…).
        static let categoryBand: CGFloat = 30
        /// Margen de la ventana alrededor del fondo, para que la sombra flotante no se corte.
        static let shadowMargin: CGFloat = 28
        /// Lado de la ventana de la rueda (la rueda y el margen de la sombra); la ventana mide esto más `categoryBand` de alto.
        static var windowSide: CGFloat { (outerRadius + backdropPadding + shadowMargin) * 2 }
        /// Ancho mínimo y máximo de la etiqueta de cada gajo.
        static let labelMinWidth: CGFloat = 54
        static let labelMaxWidth: CGFloat = 96
        /// Espacio entre el icono y el texto de cada gajo.
        static let labelSpacing: CGFloat = 3
        /// Margen del texto a cada lado dentro del gajo, y cuánto puede encoger la letra si una palabra no cabe.
        static let labelSideInset: CGFloat = 8
        static let labelMinScale: CGFloat = 0.78
        static let labelMinScaleOneWord: CGFloat = 0.68
        /// El fondo de la rueda deja un agujero transparente en el centro; su borde queda este margen por dentro de los gajos.
        static let centerHoleInset: CGFloat = 6
        /// Opacidad mínima del agujero: invisible, pero la ventana sigue recibiendo el arrastre ahí.
        static let holeHitOpacity: Double = 0.02
        /// Miniatura del archivo que flota en el centro de la rueda.
        static let thumbSize: CGFloat = 66
        /// Con la rueda fija (soltaste en el centro) aparece la pista «cambiar»: la miniatura se achica y sube.
        static let thumbSizePinned: CGFloat = 54
        static let thumbPinnedLift: CGFloat = 9
        /// La pista «cambiar» / «volver»: separación entre icono y palabra, y distancia al borde del hueco.
        static let hintIconSpacing: CGFloat = 4
        static let hintBottomInset: CGFloat = 16
        static let thumbCorner: CGFloat = 10
        /// Con varios archivos se ven como mucho tres, un poco girados.
        static let thumbStackMax = 3
        static let thumbStackAngles: [Double] = [0, -7, 6]
    }

    // MARK: - Estante flotante (Float)

    enum Shelf {
        /// Ancho de la tarjeta y alto aproximado cerrada (sin la lista).
        static let cardWidth: CGFloat = 136
        static let cardHeight: CGFloat = 150
        /// Margen transparente alrededor de la tarjeta para que la sombra se difumine entera (radio 20 + caída 4).
        static let shadowMargin: CGFloat = 32
        /// La ventana es mayor que la tarjeta (sombra y lista desplegada); lo de fuera es transparente.
        static let windowSize = CGSize(width: cardWidth + shadowMargin * 2, height: 470 + shadowMargin * 2)
        static let listMaxHeight: CGFloat = 300
        /// Miniaturas: el montón de arriba y cada archivo de la lista.
        static let pileSize: CGFloat = 72
        static let rowThumbSize: CGFloat = 52
        static let closeSize: CGFloat = 18
        /// La ✕ se ve de 18 pt, pero se puede pulsar en 24 pt alrededor.
        static let closeTarget: CGFloat = 24
        static let closeIcon: CGFloat = 9
        /// Icono que acompaña al cursor al arrastrar los archivos fuera.
        static let dragIconSize: CGFloat = 48
        /// Al abrirse queda a esta distancia del cursor; se pega al borde si lo sueltas a menos de `snapDistance`.
        static let cursorGap: CGFloat = 24
        static let edgeMargin: CGFloat = 8
        static let snapDistance: CGFloat = 60
        /// Crece un poco mientras arrastras archivos encima.
        static let targetScale: CGFloat = 1.04
    }

    // MARK: - Ventana flotante

    enum Panel {
        /// Tamaño de la tarjeta para soltar archivos cuando no hay nada.
        static let idleCardSize = CGSize(width: 168, height: 168)
        /// Ancho de la tarjeta de progreso / resultado.
        static let statusCardWidth: CGFloat = 250
        /// Segundos que se muestra el resultado antes de ocultarse.
        static let resultDuration: Double = 6
        /// Ancho de la columna de teclas en las pistas ("⇧ Convertir").
        static let hintKeyWidth: CGFloat = 14
        /// Mientras arrastras un archivo por la pantalla, la tarjeta crece un poco y el icono sube (invitación).
        static let inviteScale: CGFloat = 1.05
        static let inviteIconLift: CGFloat = -5
        /// Al pasar el ratón por encima (sin arrastrar), el icono sube un poco.
        static let hoverIconLift: CGFloat = -2
        /// Línea punteada en degradado de la invitación.
        static let inviteStroke: CGFloat = 2
    }

    // MARK: - Ajustes

    enum Settings {
        static let windowSize = CGSize(width: 780, height: 560)
        /// Ancho mínimo de cada pestaña.
        static let tabMinWidth: CGFloat = 84
        /// Ancho de los campos numéricos y del selector de formato.
        static let numberFieldWidth: CGFloat = 80
        static let pickerWidth: CGFloat = 140
    }

    // MARK: - Modo Completo (ventana de gestión de archivos)

    enum FullMode {
        /// Tamaño inicial y mínimo de la ventana.
        static let windowSize = CGSize(width: 1080, height: 820)
        static let windowMinSize = CGSize(width: 860, height: 600)
        /// Redondeo de las esquinas de la ventana (el de macOS), para la animación de cambio de modo.
        static let windowCornerRadius: CGFloat = 12
        /// Barra lateral: ancho, alto de cada sección y alto del logo de texto.
        static let sidebarWidth: CGFloat = 230
        static let navItemHeight: CGFloat = 38
        static let wordmarkHeight: CGFloat = 22
        /// Alto reservado arriba para los botones de la ventana (cerrar, minimizar…).
        static let titlebarHeight: CGFloat = 28
        /// Ancho máximo del contenido (en ventanas muy anchas queda centrado).
        static let contentMaxWidth: CGFloat = 960
        /// Zona grande para soltar archivos.
        static let dropZoneMinHeight: CGFloat = 210
        static let dropIconCircle: CGFloat = 64
        /// Filas de la cola: icono del archivo, ancho del selector de formato y del área de estado.
        static let rowIconSize: CGFloat = 32
        static let formatMenuWidth: CGFloat = 170
        static let statusWidth: CGFloat = 150
        /// Botones al final de cada fila (fijo, para que las columnas no se muevan).
        static let rowActionsWidth: CGFloat = 156
        /// Barra de progreso de cada archivo.
        static let progressHeight: CGFloat = 4
        /// Ancho máximo del texto de ayuda de la zona para soltar.
        static let dropTextMaxWidth: CGFloat = 460
        /// Icono grande de "Acerca de".
        static let aboutIconSize: CGFloat = 96
    }

    // MARK: - Línea de tiempo (ventana "Cortar…")

    enum Timeline {
        /// Alto de la línea de tiempo.
        static let height: CGFloat = 52
        /// Ancho de las asas de inicio y fin.
        static let handleWidth: CGFloat = 14
        /// Redondeo de las asas.
        static let handleRadius: CGFloat = 6
        /// Grosor del marco (color de acento) de la selección.
        static let borderWidth: CGFloat = 3
        /// Línea de reproducción: ancho y cuánto sobresale.
        static let playheadWidth: CGFloat = 2
        static let playheadOverhang: CGFloat = 8
        /// Ventana de edición: ancho mínimo.
        static let editorMinWidth: CGFloat = 600
    }

    // MARK: - Ventanas de edición ("Recortar…" y "Cortar…")

    enum Editor {
        /// Recortar: tamaño mínimo de la imagen y de la ventana.
        static let cropCanvasMin = CGSize(width: 560, height: 380)
        static let cropWindowMin = CGSize(width: 620, height: 500)
        /// Ancho máximo del selector de proporciones.
        static let aspectPickerMaxWidth: CGFloat = 460
        /// Grosor del marco de recorte y de las asas de las esquinas.
        static let frameWidth: CGFloat = 2
        /// Tamaño visible de cada asa de esquina y zona donde se puede agarrar.
        static let cornerHandle: CGFloat = 14
        static let cornerHitArea: CGFloat = 30
        /// Grosor de las guías de tercios.
        static let guideWidth: CGFloat = 0.5
        /// Cortar: alto mínimo del video y alto fijo del reproductor de audio.
        static let videoMinHeight: CGFloat = 300
        static let audioHeight: CGFloat = 60
        /// Margen extra alrededor de cada asa para que sea fácil de agarrar.
        static let handleHitInset: CGFloat = 6
    }

    // MARK: - Ventanas de herramientas (molde común)

    enum ToolWindow {
        /// Esquinas de la ventana (las cuatro iguales).
        static let cornerRadius: CGFloat = 16
        static let headerHeight: CGFloat = 52
        static let footerHeight: CGFloat = 60
        static let closeSize: CGFloat = 22
        /// Elegir el orden (unir PDF, unir videos).
        static let orderWidth: CGFloat = 460
        static let orderRowHeight: CGFloat = 56
        static let orderVisibleRows = 6
        static let orderThumbSize: CGFloat = 40
        static let orderNumberWidth: CGFloat = 18
        static let orderArrowSize = CGSize(width: 30, height: 20)
        /// La fila que arrastras crece un poco.
        static let orderDragScale: CGFloat = 1.02
        /// Al soltar, tiempo que tarda la fila o la tarjeta en llegar a su hueco (el muelle de `Motion.toast` ya ha parado).
        static let dropSettle: Double = 0.55
    }

    // MARK: - Editar foto

    enum PhotoEditor {
        /// La vista previa se calcula sobre una copia de este tamaño máximo (en píxeles), para que vaya fluida.
        static let previewMaxPixels = 1400
        static let previewMinWidth: CGFloat = 480
        static let controlsWidth: CGFloat = 290
        static let contentHeight: CGFloat = 540
    }

    // MARK: - Metadatos

    enum MetadataEditor {
        static let contentWidth: CGFloat = 560
        static let contentHeight: CGFloat = 420
        static let labelWidth: CGFloat = 170
        static let fieldHeight: CGFloat = 26
        static let searchWidth: CGFloat = 220
        static let noteWidth: CGFloat = 300
    }

    // MARK: - Anotar, añadir fondo y ocultar

    enum Markup {
        /// Lienzo de Anotar y Ocultar.
        static let canvasSize = CGSize(width: 720, height: 440)
        static let toolSize = CGSize(width: 38, height: 30)
        static let colorDot: CGFloat = 16
        static let sizeSliderWidth: CGFloat = 110
        static let stylePickerWidth: CGFloat = 220
        /// Añadir fondo: vista previa cuadrada, ancho de los controles y tamaño de cada muestra.
        static let backgroundPreview: CGFloat = 460
        static let backgroundControls: CGFloat = 250
        static let swatch: CGFloat = 40
    }

    // MARK: - Collage

    enum Collage {
        static let previewSide: CGFloat = 460
        static let previewWidth = 900
        static let controlsWidth: CGFloat = 300
        static let menuWidth: CGFloat = 190
        static let chip: CGFloat = 22
        static let orderVisibleRows = 4
    }

    // MARK: - Herramientas de video

    enum VideoTools {
        static let previewSize = CGSize(width: 640, height: 360)
        static let frameChip = CGSize(width: 104, height: 60)
    }

    // MARK: - Herramientas de audio

    enum AudioTools {
        static let width: CGFloat = 560
        static let bins = 140
        static let waveHeight: CGFloat = 110
        static let channelHeight: CGFloat = 54
        static let bleepLane: CGFloat = 34
        static let edge: CGFloat = 12
    }

    // MARK: - Organizar páginas de PDF

    enum PDFOrganize {
        /// Columnas de la cuadrícula, tamaño de cada tarjeta y hueco entre ellas.
        static let columns = 4
        static let card = CGSize(width: 128, height: 152)
        static let gap: CGFloat = 12
        /// Franja de arriba (número y girar) y espacio para la miniatura debajo.
        static let cardHeader: CGFloat = 36
        static let thumbBox: CGFloat = 104
        /// Filas que se ven a la vez; con más páginas, la cuadrícula se desplaza.
        static let visibleRows = 2.6
        static let badge: CGFloat = 22
        static let button: CGFloat = 24
        /// La tarjeta que arrastras crece un poco; al pasar el ratón sube un poco.
        static let dragScale: CGFloat = 1.05
        static let hoverLift: CGFloat = 2
    }

    // MARK: - Icono de la rueda (barra lateral)

    enum WheelGlyph {
        /// Lado del icono (puntos), número de gajos, hueco central (fracción del lado), separación y esquinas.
        static let size: CGFloat = 18
        static let slices = 6
        static let innerRatio: CGFloat = 0.2
        static let gap: CGFloat = 1.6
        static let corner: CGFloat = 1.2
    }

    // MARK: - Pestañas

    enum Tabs {
        static let height: CGFloat = 34
        static let inset: CGFloat = 4
        static let pillRadius: CGFloat = 10
    }

    // MARK: - Personalizar rueda

    enum WheelCustomize {
        static let previewSide: CGFloat = 280
        static let modePickerWidth: CGFloat = 260
        static let placementWidth: CGFloat = 250
        static let rowHeight: CGFloat = 42
        /// Flechas subir/bajar: icono pequeño, pero zona de clic de 24 pt de ancho (las dos caben en la fila).
        static let arrowIcon: CGFloat = 10
        static let arrowTarget = CGSize(width: 24, height: 21)
    }

    // MARK: - PDF creados desde documentos (DOCX, Markdown… → PDF)

    enum DocumentPDF {
        /// Tamaño de página en puntos (A4 = 595 × 842; Carta = 612 × 792).
        static let pageSize = CGSize(width: 595, height: 842)
        /// Margen alrededor del texto, en puntos (72 pt = 2,54 cm).
        static let margin: CGFloat = 64
        /// Fuente del texto. "-apple-system" = SF Pro. Prueba "Georgia" o "Helvetica Neue".
        static let fontFamily = "-apple-system"
        static let fontSizePt = 11
        /// Color de los títulos (hex CSS).
        static let headingColor = "#1A1A1A"
        /// Color de los enlaces.
        static let linkColor = "#00B9FD"
    }

    // MARK: - Animaciones

    enum Motion {
        /// Aparición de la rueda (spring suave).
        static var wheelAppear: Animation {
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.38, dampingFraction: 0.72)
        }
        /// Cambio de opción resaltada.
        /// La pastilla de las pestañas se desliza a la nueva.
        static var tabSlide: Animation {
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.82)
        }
        static var hover: Animation {
            reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.22, dampingFraction: 0.8)
        }
        /// Respuesta de botones al pasar el ratón o pulsar.
        static var control: Animation {
            reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.12)
        }

        // Micro interacciones del modo Lite

        /// La tarjeta "Suelta aquí" invita a soltar mientras arrastras un archivo por la pantalla.
        static var invite: Animation {
            reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.62)
        }
        /// La línea punteada avanza (una vuelta del patrón en este tiempo).
        static let inviteDashCycle: Double = 0.6
        /// El archivo flota en el centro de la rueda: una subida y bajada completa en este tiempo (segundos).
        static let floatCycle: Double = 2.6
        /// Cuánto sube y baja (puntos) y cuánto se balancea (grados).
        static let floatRise: CGFloat = 3
        static let floatTilt: Double = 2.5
        /// Al resaltar una opción, el archivo se acerca a ella y se ladea un poco.
        static let floatLeanDistance: CGFloat = 5
        static let floatLeanTilt: Double = 4
        static var floatLean: Animation {
            reduceMotion ? .linear(duration: 0) : .spring(response: 0.36, dampingFraction: 0.7)
        }
        /// Cada gajo de la rueda aparece un poco después que el anterior.
        static var sliceStagger: Double { reduceMotion ? 0 : 0.025 }
        static var sliceAppear: Animation {
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.66)
        }
        /// La rueda nace del punto por donde entra el archivo (escala inicial).
        static let wheelOriginScale: CGFloat = 0.45
        /// Salto del icono del gajo resaltado.
        static let iconPopScale: CGFloat = 1.18
        static var iconPop: Animation {
            reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.26, dampingFraction: 0.5)
        }
        /// Cambio de icono con escala y desenfoque (al cambiar de rueda).
        static let swapBlur: CGFloat = 6
        static let swapScale: CGFloat = 0.6
        /// La tarjeta de resultado entra subiendo, con desenfoque.
        static let toastRise: CGFloat = 14
        static let toastBlur: CGFloat = 8
        static let toastScale: CGFloat = 0.94
        static var toast: Animation {
            reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.78)
        }
        /// El check de "Listo" se dibuja.
        static var checkDraw: Animation {
            reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.42).delay(0.12)
        }
        /// Sacudida del error.
        static let shakeDistance: CGFloat = 7
        static let shakeCount: CGFloat = 3
        static var shake: Animation? { reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.1) }
        /// Cambio de los dígitos del porcentaje.
        static var digits: Animation {
            reduceMotion ? .linear(duration: 0) : .spring(response: 0.3, dampingFraction: 0.85)
        }

        // Micro interacciones del modo Completo

        /// Barra lateral: el resaltado aparece en su sitio creciendo desde este tamaño, y el icono salta.
        static let navSelectScale: CGFloat = 0.94
        static var navSelect: Animation {
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.8)
        }
        /// Cuánto se queda el icono grande antes de volver (segundos).
        static let navPopHold: Double = 0.12
        /// Filas de la cola: aparecen escalonadas al agregar y se disuelven al quitarlas.
        static var rowStagger: Double { reduceMotion ? 0 : 0.035 }
        static let rowStaggerMax: Double = 0.4
        static let rowRise: CGFloat = 10
        static let rowBlur: CGFloat = 6
        static var row: Animation {
            reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82)
        }
        /// Cambio de estado de una fila (En cola → Convirtiendo → Listo) con fundido y desenfoque.
        static var statusSwap: Animation {
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.85)
        }
        /// El contador de la cola salta al cambiar.
        static var badgePop: Animation {
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.55)
        }
        /// Brillo que recorre "Convirtiendo…" (una pasada cada tanto).
        static let shimmerCycle: Double = 1.6
        static let shimmerWidth: CGFloat = 0.35
        /// Barrido de caracteres al terminar un archivo (el nombre se transforma en el del resultado).
        static let scrambleDuration: Double = 0.7
        /// Ancho de la banda de caracteres brillantes (en letras).
        static let scrambleBand: Double = 5
        /// Cambio entre los modos Lite y Completo: la ventana se transforma en la otra.
        static let modeMorphDuration: Double = 0.35
        /// Curva suave de entrada y salida, sin rebote (puntos de control de una curva Bézier).
        static let modeMorphCurve: (Float, Float, Float, Float) = (0.4, 0, 0.2, 1)
        /// Al final del cambio de modo, la ventana real aparece debajo con este fundido (así su sombra no salta).
        static let modeRevealDuration: Double = 0.1
        /// Y después la animación se desvanece sobre la ventana real (los fondos translúcidos no saltan).
        static let modeHandoffDuration: Double = 0.08
        /// Con "Reducir movimiento": solo un fundido.
        static let modeFadeDuration: Double = 0.2

        /// Respeta "Reducir movimiento" en Ajustes del Sistema → Accesibilidad → Pantalla.
        static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
}

// MARK: - Ayudante para colores claro/oscuro (no necesitas tocar esto)

extension Color {
    static func dynamic(light: UInt32, dark: UInt32, opacity: Double = 1) -> Color {
        dynamic(light: light, dark: dark, lightOpacity: opacity, darkOpacity: opacity)
    }

    static func dynamic(light: UInt32, dark: UInt32, lightOpacity: Double, darkOpacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkOpacity : lightOpacity)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
