# Dock-e

Dock-e es una barra de escritorio flotante para Linux basada en
[Plank](https://launchpad.net/plank). Conserva el motor, la integración con
ventanas y la arquitectura en Vala de Plank, pero amplía su interfaz con un
lanzador de aplicaciones y controles del sistema integrados en el propio
proyecto.

El objetivo es ofrecer una barra compacta y coherente visualmente, sin depender
de lanzadores o paneles externos para sus funciones principales.

## Estado actual

La barra ocupa prácticamente todo el ancho de la pantalla y conserva márgenes
laterales e inferior para producir el efecto flotante. Su contenido está
dividido en tres zonas:

- **Izquierda:** botón de Dock-e y acceso al lanzador nativo.
- **Centro:** aplicaciones fijadas y ventanas abiertas, con ampliación animada,
  indicadores sólidos para aplicaciones activas y áreas de interacción que
  llegan hasta el borde inferior.
- **Derecha:** volumen, Bluetooth, Wi-Fi, batería y hora.

## Lanzador nativo

El botón de Dock-e abre un lanzador construido dentro del proyecto. Incluye:

- Búsqueda difusa de aplicaciones instaladas.
- Pestañas **Frequently used** y **All**.
- Registro persistente de aplicaciones utilizadas.
- Catálogo alfabético con separadores por inicial.
- Navegación mediante ratón y teclado.
- Menú de sesión para bloquear, suspender, cerrar sesión, reiniciar o apagar.
- Tamaño y posición estables sobre la barra.

El icono del botón está en `data/dock-menu.jpg` y se incorpora al binario a
través de los recursos de GLib.

## Paneles del sistema

Los indicadores de la derecha utilizan una ventana nativa compartida en lugar
de depender visualmente de los menús estándar de GTK. El contenido cambia según
el indicador seleccionado:

- **Volumen:** dispositivo de salida, volumen, silencio, entrada de micrófono,
  controles por aplicación y acceso a la configuración avanzada.
- **Bluetooth:** encendido y dispositivos emparejados.
- **Wi-Fi:** encendido y redes detectadas.
- **Batería:** porcentaje y estado de carga.
- **Hora:** fecha y calendario.

Los paneles mantienen la barra visible mientras se utilizan y comparten fondo,
bordes, espaciado y posición.

## Estructura del proyecto

```text
data/
  dock-menu.jpg                 Recurso del botón principal
  plank.gresource.xml           Registro de recursos incluidos en el binario
  themes/                       Temas y valores visuales de la barra

lib/
  DockController.vala           Crea y coordina barra, proveedores y paneles
  DockRenderer.vala             Renderizado, estados y animaciones
  PositionManager.vala          Geometría de las tres zonas de la barra
  HideManager.vala              Auto-ocultado e inhibición durante paneles

  Items/
    LauncherItem.vala           Botón fijo de Dock-e
    StatusIndicatorItem.vala    Indicadores de volumen, red, batería y hora
    ApplicationDockItem.vala    Aplicaciones fijadas y ventanas abiertas

  Widgets/
    DockWindow.vala             Entrada de ratón y ventana principal
    LauncherWindow.vala         Lanzador nativo de aplicaciones
    StatusPanelWindow.vala      Panel reutilizable para controles del sistema

docklets/                       Docklets heredados de Plank
src/                            Punto de entrada del ejecutable
tests/                          Pruebas heredadas y componentes de prueba
vapi/                           Definiciones de interfaces Vala
```

El flujo principal es:

1. `DockController` crea la ventana y registra los proveedores fijos.
2. `PositionManager` separa el botón, las aplicaciones y los indicadores.
3. `DockRenderer` dibuja cada región y anima sus estados.
4. `DockWindow` dirige los clics hacia `LauncherWindow` o
   `StatusPanelWindow`.
5. Los paneles interactúan con los servicios del escritorio mediante
   herramientas como PipeWire/WirePlumber, PulseAudio, NetworkManager, BlueZ y
   XFCE Power Manager.

## Compilación

Dock-e utiliza Autotools, Vala y GTK 3. En un sistema con las dependencias de
Plank instaladas:

```bash
./autogen.sh
make -j$(nproc)
```

Para ejecutar la compilación local sin instalarla:

```bash
LD_LIBRARY_PATH="$PWD/lib/.libs" "$PWD/src/.libs/plank" -n dev -d
```

## Origen y licencia

Dock-e está basado en Plank y mantiene su licencia **GNU General Public License
v3 o posterior**. Los avisos de copyright y autoría existentes en el código
original se conservan.

La documentación histórica y las instrucciones para contribuir al código base
pueden consultarse en `HACKING` y en el proyecto original de Plank.
