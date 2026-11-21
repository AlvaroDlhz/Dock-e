# Aislamiento de X11 en Dock-E

Plan para que todo lo que depende de X11 quede detrás de interfaces, de modo que
un backend Wayland (layer-shell + foreign-toplevel + compañía) sea posible sin
reescribir el dock. El backend X11 actual será la primera implementación de cada
interfaz y **no pierde ninguna función**: el objetivo de esta etapa es mover
código, no cambiar comportamiento.

Fecha del análisis: 2026-11-21, rama `claude/plan-x11-31df7a` (desde `1fc7ccd`).
Las referencias `archivo:línea` son de ese commit; las sesiones que editan
`TrayToggleItem`, `LauncherWindow`, preferencias y `tests/` en paralelo pueden
desplazar algunas líneas.

---

## 1. Inventario

### 1.0 Compilación y arranque

| Qué | Dónde |
|---|---|
| Dependencias duras `gdk-x11-3.0`, `libbamf3`, `libwnck-3.0`, `x11` | `configure.ac:130-149` |
| Barreras opcionales (`xi` ≥ 2.3 + `xfixes` ≥ 5) → `HAVE_BARRIERS` | `configure.ac:199-214` |
| XDamage opcional → `HAVE_XDAMAGE` | `configure.ac:232-243` |
| Bindings propios | `vapi/libbamf3.vapi`, `vapi/xdamage.vapi`, `vapi/xfixes.vapi`, `vapi/xi.vapi` |
| `libbamf3` se filtra a la API pública de libplank (`plank.pc`) | `lib/plank.deps:9` |
| Rechazo de cualquier sesión que no sea X11 | `lib/Factories/AbstractMain.vala:256-260` |
| Log de versión de Wnck y de barreras XInput | `lib/Factories/AbstractMain.vala:240`, `:247-249` |
| `WindowControl.initialize ()` (Wnck como pager) | `lib/Factories/AbstractMain.vala:264`, `lib/Services/WindowControl.vala:53-80` |
| Detección de sesión con `Gdk.X11.Screen` como último recurso | `lib/Services/Environment.vala:114`, `:126`, `:214-215` |

### 1.1 Lista de aplicaciones y ventanas (BAMF + Wnck)

Es el núcleo del dock y la dependencia más extendida. **BAMF** agrupa ventanas en
aplicaciones y las asocia a su `.desktop`; **Wnck** da estado y acciones de
ventana. Los dos se cruzan por XID (`app.get_xids ()` → `Wnck.Window.@get (xid)`).

| Responsabilidad | Dónde |
|---|---|
| `Matcher`: envoltorio de `Bamf.Matcher`; señales con tipos Bamf (`window_opened`, `active_window_changed`, `application_opened`…) | `lib/Services/Matcher.vala:27-33`, `:45`, `:53`, `:74-131` |
| Apps activas, app por URI de `.desktop`, favoritos | `lib/Services/Matcher.vala:134-176` |
| **API pública** `ApplicationDockItem.App : Bamf.Application` | `lib/Items/ApplicationDockItem.vala:68-80` |
| Señales de la app (activa, nombre, urgente, visible, ventanas añadidas/quitadas, cerrada) | `lib/Items/ApplicationDockItem.vala:148-176`, `:275-293` |
| Conteo de ventanas, transitorias, `is_running`, `.desktop` | `lib/Items/ApplicationDockItem.vala:184-207`, `:308`, `:340-370`, `:730` |
| Menú contextual con lista de ventanas e iconos | `lib/Items/ApplicationDockItem.vala:416-504` |
| Proveedor de ítems: casar apps con lanzadores | `lib/Items/ApplicationDockItemProvider.vala:52`, `:66`, `:75-95`, `:168-203`, `:321`, `:363` |
| `app_opened` fuerza `Wnck.Screen.force_update ()` | `lib/Items/ApplicationDockItemProvider.vala:196-199` |
| Proveedor por defecto: ventana activa, transitorios, favoritos | `lib/Items/DefaultApplicationDockItemProvider.vala:46-60`, `:106-113`, `:204-215`, `:236-239`, `:288-300` |
| `TransientDockItem.with_application (Bamf.Application)` | `lib/Items/TransientDockItem.vala:34-84` |
| `WindowControl`: iconos de app/ventana desde Wnck | `lib/Services/WindowControl.vala:91-140` |
| `WindowControl`: `has_maximized_window`, `has_minimized_window` | `lib/Services/WindowControl.vala:142-172` |
| `WindowControl`: cerrar todo, enfocar, anterior/siguiente | `lib/Services/WindowControl.vala:214-301` |
| `WindowControl`: minimizar, restaurar, maximizar, orden de apilado | `lib/Services/WindowControl.vala:303-361` |
| `WindowControl.smart_focus` + lógica de *viewports* (Compiz) | `lib/Services/WindowControl.vala:363-512` |
| `get_easy_geometry` | `lib/Services/WindowControl.vala:514-523` |
| Geometría del icono para la animación de minimizar (`_NET_WM_ICON_GEOMETRY` vía Wnck) | `lib/Services/WindowControl.vala:200-212`, llamado desde `lib/Widgets/DockWindow.vala:611`, `:629` |
| Previsualización de ventanas: lista de ventanas, minimizar/cerrar desde la tarjeta | `lib/Widgets/WindowPreviewWindow.vala:123-124`, `:220-305` |

### 1.2 Miniaturas de ventanas (XDamage + Gdk.X11)

| Qué | Dónde |
|---|---|
| Caché indexada por XID, señal `changed (uint32 xid)` | `lib/Services/WindowThumbnails.vala:36`, `:83-101` |
| Captura con `Gdk.X11.Window.foreign_for_display` + `pixbuf_get_from_window` | `lib/Services/WindowThumbnails.vala:130-153` |
| XDamage: crear, restar, destruir, filtro de eventos | `lib/Services/WindowThumbnails.vala:27-28`, `:45-75`, `:114-124`, `:155-197`, `:224-249` |
| Consumidores: previsualización de ventanas y de escritorios | `lib/Widgets/WindowPreviewWindow.vala:248-249`, `:303-335`; `lib/Widgets/WorkspacePreviewWindow.vala:303-308` |

### 1.3 Struts y reserva de espacio

| Qué | Dónde |
|---|---|
| `_NET_WM_STRUT_PARTIAL` y `_NET_WM_STRUT` con `XChangeProperty` | `lib/Widgets/DockWindow.vala:870-902` |
| Disparadores (`HideMode`, cambio de tamaño/posición) | `lib/Widgets/DockWindow.vala:97`, `:107`, `:357`, `:577`, `:590` |
| Cálculo en coordenadas absolutas de la pantalla raíz (`screen.get_width ()`) | `lib/PositionManager.vala:1642-1668` (`get_struts`) |

### 1.4 Posición, tipo y comportamiento de ventanas

Aquí no hay llamadas a Xlib, pero sí **suposiciones de X11** expresadas con API de
GTK que en Wayland no hacen nada o hacen otra cosa: posición absoluta con
`move ()`, `type_hint`, `stick ()`, `set_keep_above ()`, coordenadas globales.

| Ventana | Suposición | Dónde |
|---|---|---|
| `DockWindow` | `TOPLEVEL` + `WindowTypeHint.DOCK`, `stick ()`, sin foco, `move ()` absoluto | `lib/Widgets/DockWindow.vala:77-87`, `:552-592` |
| `DockWindow` | Región de entrada (`input_shape_combine_region`) — portable | `lib/Widgets/DockWindow.vala:854-868` |
| `HoverWindow` (tooltip) | `POPUP` + `TOOLTIP`, `move ()` | `lib/Widgets/HoverWindow.vala:44`, `:92`, `:128` |
| `PoofWindow` | `DOCK`, keep above, `move ()` | `lib/Widgets/PoofWindow.vala:54-61`, `:104` |
| `WindowPreviewWindow` | `POPUP_MENU`, keep above, `move ()` | `lib/Widgets/WindowPreviewWindow.vala:36-49`, `:351`, `:384-389` |
| `WorkspacePreviewWindow` | `DIALOG`, keep above, `move ()` | `lib/Widgets/WorkspacePreviewWindow.vala:41-52`, `:326-331` |
| `LauncherWindow` y su menú contextual | `DIALOG`, keep above, `move ()` | `lib/Widgets/LauncherWindow.vala:121-136`, `:1179-1188`, `:1355-1359`, `:1639-1644` |
| Panel de la bandeja (`TrayToggleItem`) | `DIALOG`, keep above, `move ()` | `lib/Items/TrayToggleItem.vala:869-878`, `:1392-1411` |
| Diálogo de `System` | keep above | `lib/Services/System.vala:77-78` |
| `PositionManager`: monitor primario, `is_composited` (en Wayland siempre true) | `lib/PositionManager.vala:30`, `:66-128`, `:166-170` |
| `HideManager.update_hovered`: puntero en coordenadas globales | `lib/HideManager.vala:191-214` |
| `DragManager`: `Gdk.Device.grab` durante el arrastre | `lib/DragManager.vala:229-230` |

### 1.5 Ocultado inteligente (Wnck) y barreras de presión (XFixes + XInput 2.3)

| Qué | Dónde |
|---|---|
| Señales de Wnck: ventana abierta/cerrada, activa, escritorio | `lib/HideManager.vala:141-151`, `:162-172`, `:512-549` |
| Intersección dock/ventanas: tipo, pid, minimizada, maximizada, diálogos, escritorio visible, geometría | `lib/HideManager.vala:434-498`, `:551-574` |
| Barrera: `XFixes.create/destroy_pointer_barrier` | `lib/HideManager.vala:110-115`, `:176-184`, `:720-761` |
| XInput: comprobación de versión, `select_events`, `BARRIER_HIT/LEAVE`, `barrier_release_pointer` | `lib/HideManager.vala:600-718`, `:742-746` |
| Geometría de la barrera | `lib/PositionManager.vala:668-670`, `:1670-1700` |

### 1.6 Atajo global de la tecla Super

| Qué | Dónde |
|---|---|
| `XGrabKey` sobre la raíz con máscaras Lock/NumLock y `XAllowEvents` (Sync/Replay) | `lib/Services/SuperKeyBinding.vala:14-142` |
| Conexión a `LauncherWindow.toggle_global ()` | `lib/DockController.vala:120-121` |

Ya degrada bien: en un display que no es X11 sólo avisa (`:36-39`).

### 1.7 Escritorios virtuales y «mostrar escritorio» (Wnck)

| Qué | Dónde |
|---|---|
| Lista, nombre, activo, activar escritorio | `lib/Widgets/WorkspacePreviewWindow.vala:15`, `:36`, `:173-230` |
| Ventanas por escritorio, en orden de apilado, filtrando tipos | `lib/Widgets/WorkspacePreviewWindow.vala:245-265` |
| Filtro «sólo escritorio actual» y viewports | `lib/Items/DefaultApplicationDockItemProvider.vala:71-81`, `:132-180`; `lib/Services/WindowControl.vala:174-198` |
| «Mostrar escritorio» (`toggle_showing_desktop`) | `docklets/Desktop/DesktopDockItem.vala:47-48` |
| `WorkspaceItem` | sin X11 directo; usa `WorkspacePreviewWindow` (`lib/Items/WorkspaceItem.vala:39-49`) |

### 1.8 Lo que ya es portable

No hace falta tocarlo: bandeja por **StatusNotifierItem** y XApp por D-Bus
(`lib/Items/TrayToggleItem.vala:1-300`, `lib/Services/StatusNoticeModel.vala`),
menús dbusmenu, `Unity.vala` (LauncherEntry por D-Bus), `DBusManager`,
lanzamiento con `AppInfo`/`System.launch` (GTK usa xdg-activation en Wayland),
portapapeles de `Clippy` (`Gdk.Atom` de GDK, no de X), y el DnD de `DragManager`
salvo el `grab`.

---

## 2. Interfaces propuestas

### 2.0 Organización

```
lib/Platform/            interfaces y tipos neutrales (namespace Plank.Platform)
lib/Platform/X11/        primer backend: Wnck, BAMF, Xlib, XDamage, XFixes, XI
lib/Platform/Wayland/    (futuro) layer-shell, foreign-toplevel, ext-workspace…
```

Un único punto de entrada elige backend en tiempo de ejecución según el tipo de
`Gdk.Display`, y cada backend declara qué sabe hacer. La UI consulta esas
capacidades en lugar de preguntar «¿es X11?».

```vala
namespace Plank.Platform
{
	public enum BackendKind { X11, WAYLAND }

	[Flags]
	public enum Capability
	{
		TOPLEVELS,            // lista de ventanas con acciones
		TOPLEVEL_GEOMETRY,    // posición/tamaño de ventanas ajenas
		TOPLEVEL_PID,
		STACKING_ORDER,
		WINDOW_ICONS,         // icono por ventana (si no, el del .desktop)
		THUMBNAILS,
		WORKSPACES,
		WINDOW_WORKSPACE,     // a qué escritorio pertenece cada ventana
		SHOW_DESKTOP,
		ICON_GEOMETRY,        // destino de la animación de minimizar
		RESERVE_SPACE,        // struts / exclusive zone
		EDGE_PRESSURE,        // barreras de presión
		GLOBAL_SUPER_KEY,
		GLOBAL_POINTER,       // posición del puntero fuera de nuestras ventanas
		ABSOLUTE_PLACEMENT    // move () a coordenadas globales
	}

	public interface Backend : Object
	{
		public abstract BackendKind kind { get; }
		public abstract Capability capabilities { get; }

		public abstract ToplevelManager toplevels { get; }
		public abstract AppTracker apps { get; }
		public abstract WorkspaceManager? workspaces { get; }   // null si no hay
		public abstract WindowThumbnailer? thumbnailer { get; } // null si no hay
		public abstract SuperKeyTrigger? super_key { get; }

		public abstract DockSurface create_dock_surface (Gtk.Window dock);
		public abstract EdgeTrigger? create_edge_trigger (Gtk.Window dock);
		public abstract PopupPlacer popups { get; }

		public bool has (Capability c) { return (c in capabilities); }
	}

	public Backend get_backend ();   // singleton; X11Backend o WaylandBackend
}
```

### 2.1 Ventanas (toplevels)

```vala
public enum ToplevelKind { NORMAL, DIALOG, UTILITY, OTHER }

[Flags]
public enum ToplevelState
{
	ACTIVE, MINIMIZED, MAXIMIZED, FULLSCREEN, URGENT, SKIP_TASKBAR, SKIP_PAGER
}

public abstract class Toplevel : Object
{
	/** XID en X11; contador local en Wayland. Sólo para indexar, nunca para hablar con el servidor. */
	public abstract uint64 id { get; }
	public abstract string title { get; }
	public abstract string? app_id { get; }       // WM_CLASS en X11, app_id en Wayland
	public abstract int pid { get; }              // 0 si se desconoce
	public abstract ToplevelState state { get; }
	public abstract ToplevelKind kind { get; }
	public abstract Toplevel? transient_for { get; }

	/** false si el backend no conoce la geometría (ver Capability.TOPLEVEL_GEOMETRY). */
	public abstract bool get_geometry (out Gdk.Rectangle rect);
	public abstract bool is_on_workspace (Workspace workspace);
	public abstract Gdk.Pixbuf? get_icon (int size);

	public signal void state_changed (ToplevelState changed_mask);
	public signal void geometry_changed ();
	public signal void title_changed ();

	public abstract void activate (uint32 timestamp);
	public abstract void close (uint32 timestamp);
	public abstract void set_minimized (bool minimized);
	public abstract void set_maximized (bool maximized);
	/** _NET_WM_ICON_GEOMETRY en X11, set_rectangle en wlr-foreign-toplevel. */
	public abstract void set_icon_geometry (Gtk.Window dock, Gdk.Rectangle rect);
}

public interface ToplevelManager : Object
{
	public abstract Toplevel? active { get; }
	/** De abajo arriba si hay STACKING_ORDER; si no, orden de aparición. */
	public abstract Gee.List<Toplevel> list ();

	public signal void added (Toplevel toplevel);
	public signal void removed (Toplevel toplevel);
	public signal void active_changed (Toplevel? previous);
}
```

- **X11:** `X11Toplevel` envuelve `Wnck.Window`; `X11ToplevelManager` envuelve
  `Wnck.Screen` (incluye `set_client_type (PAGER)` y `force_update`). Los tipos
  `DESKTOP`, `DOCK`, `MENU` y `SPLASHSCREEN` se filtran dentro del backend, así
  `HideManager` y `WorkspacePreviewWindow` dejan de repetir ese filtro.
- **Wayland:** `zwlr_foreign_toplevel_manager_v1` (wlroots: Sway, Hyprland, labwc,
  river, Wayfire; también niri) da título, `app_id`, estados
  activa/minimizada/maximizada/pantalla completa, salida, padre, y las acciones
  activar, cerrar, (des)minimizar, (des)maximizar y `set_rectangle`.
  `ext-foreign-toplevel-list-v1` da sólo la lista (sin acciones); útil como
  identificador estable junto a otros protocolos. COSMIC tiene
  `cosmic-toplevel-info/management` (con escritorio por ventana). En KWin el
  equivalente es `org_kde_plasma_window_management` (a verificar cuál conviene).
- **Sin equivalente en Wayland:** geometría de ventanas ajenas, PID, orden de
  apilado, tipo de ventana (diálogo/utilidad), icono por ventana, urgencia
  (sólo vía D-Bus/notificaciones). Viewports de Compiz: sólo X11.

### 2.2 Aplicaciones (sustituye a BAMF y a `Matcher`)

```vala
public abstract class RunningApp : Object
{
	public abstract string? desktop_file { get; }   // ruta absoluta, como hoy con Bamf
	public abstract string name { get; }
	public abstract bool is_running { get; }
	public abstract bool is_active { get; }
	public abstract bool is_urgent { get; }
	public abstract bool is_user_visible { get; }
	public abstract Gee.List<Toplevel> get_windows ();

	public signal void window_added (Toplevel toplevel);
	public signal void window_removed (Toplevel toplevel);
	public signal void closed ();
	// active/urgent/name/running/user_visible: notify de GObject
}

public interface AppTracker : Object
{
	public abstract Gee.List<RunningApp> running_apps ();          // = Matcher.active_launchers
	public abstract RunningApp? app_for_desktop_file (string uri); // = Matcher.app_for_uri
	public abstract void set_favorites (Gee.List<string> desktop_files);

	public signal void app_opened (RunningApp app);
	public signal void app_closed (RunningApp app);
	public signal void active_app_changed (RunningApp? old_app, RunningApp? new_app);
	public signal void window_opened (Toplevel toplevel);
	public signal void active_window_changed (Toplevel? old_win, Toplevel? new_win);
}
```

- **X11:** `BamfAppTracker` = el `Matcher` actual (incluida la lógica de vistas
  pendientes `:84-99`) devolviendo `BamfApp : RunningApp`, cuyas ventanas son los
  `X11Toplevel` cruzados por XID.
- **Wayland:** BAMF no existe. Hace falta un *matcher* propio: `app_id` →
  `GDesktopAppInfo` (id exacto, `StartupWMClass`, búsqueda por nombre,
  heurísticas para Flatpak/Snap/Chromium PWA). Es la pieza con más casos raros.
- **Nota:** `WindowControl` se convierte en código neutral que opera sobre
  `RunningApp` y `Toplevel` (la lógica de `smart_focus` se conserva tal cual). La
  parte de viewports (`:435-512`) pasa al backend X11 como detalle de
  `X11Toplevel.activate`.

### 2.3 Miniaturas

```vala
public interface WindowThumbnailer : Object
{
	public abstract Gdk.Pixbuf? lookup (Toplevel toplevel);   // null si aún no hay
	public abstract void clear ();
	public signal void changed (Toplevel toplevel);
}
```

- **X11:** el `WindowThumbnails` actual (XDamage + `Gdk.X11.Window.foreign`), con
  la clave cambiada de `uint32 xid` a `Toplevel`.
- **Wayland:** `ext-image-copy-capture-v1` con fuente
  `ext-foreign-toplevel-image-capture-source-manager-v1` (wlroots ≥ 0.19 y
  compositores que lo adopten); Hyprland tiene además
  `hyprland-toplevel-export-v1`. `wlr-screencopy` sólo captura salidas, no
  ventanas. Requiere buffers SHM/dmabuf y es la parte más costosa del backend.
- **Sin equivalente:** en GNOME y KDE no hay forma sin diálogo
  (`xdg-desktop-portal` ScreenCast pide permiso al usuario). Con
  `thumbnailer == null` las previsualizaciones muestran icono + título.

### 2.4 Superficie del dock: tipo, posición y reserva de espacio

```vala
public interface DockSurface : Object
{
	/** DOCK + sticky + sin foco en X11; capa TOP en layer-shell. Antes de realize. */
	public abstract void setup ();
	/** Borde, monitor y rectángulo en coordenadas del monitor. */
	public abstract void place (Gtk.PositionType edge, int monitor, Gdk.Rectangle rect);
	/** Espacio reservado desde el borde, en px lógicos; 0 = nada. */
	public abstract void reserve (Gtk.PositionType edge, int monitor,
		int thickness, int start, int end);
}
```

- **X11:** `setup` hace lo de `DockWindow.vala:77-87`; `place` hace `move ()`
  convirtiendo a coordenadas globales; `reserve` calcula
  `_NET_WM_STRUT_PARTIAL` (lo que hoy hace `PositionManager.get_struts` con
  `screen.get_width ()` y la escala) y lo escribe con Xlib. Así
  `PositionManager` deja de saber de coordenadas de la raíz.
- **Wayland:** `zwlr_layer_shell_v1` vía la biblioteca **gtk-layer-shell** (GTK3,
  trae `.vapi`): ancla al borde, márgenes, capa `TOP`, `exclusive_zone` =
  `thickness`, monitor = `wl_output`. Lo soportan wlroots, KWin, Hyprland,
  niri, COSMIC. La región de entrada ya es portable.
- **Sin equivalente:** reserva *parcial* (sólo un tramo del borde): la zona
  exclusiva ocupa todo el borde. En **GNOME/Mutter no hay layer-shell**.

### 2.5 Ventanas emergentes (tooltip, previsualizaciones, lanzador, bandeja, poof)

```vala
public interface PopupPlacer : Object
{
	/** Prepara una ventana emergente ligada al dock (tipo, keep-above, padre). */
	public abstract void setup (Gtk.Window popup, Gtk.Window dock, PopupKind kind);
	/** Coloca junto a un rectángulo del dock (coordenadas del dock), hacia `side`. */
	public abstract void place (Gtk.Window popup, Gdk.Rectangle anchor, Gtk.PositionType side);
}

public enum PopupKind { TOOLTIP, PREVIEW, PANEL, OVERLAY }
```

- **X11:** lo actual: `type_hint`, `set_keep_above`, `move ()` con el cálculo de
  monitor que ya hace cada ventana.
- **Wayland:** dos caminos según el caso: `xdg_popup` con
  `xdg_positioner` hijo de la superficie layer-shell (en GTK3:
  `Gtk.WindowType.POPUP` con `transient_for` = dock, o `Gtk.Popover`), o una
  superficie layer-shell propia para paneles grandes con teclado
  (`LauncherWindow`, panel de bandeja) con `keyboard_interactivity`
  `ON_DEMAND`/`EXCLUSIVE`.
- **Sin equivalente:** posicionar ventanas arbitrarias en coordenadas globales;
  `PoofWindow` (animación donde se suelta un ítem fuera del dock) sólo puede
  hacerse como overlay layer-shell de pantalla completa o eliminarse.

### 2.6 Disparador de borde (barreras de presión)

```vala
public interface EdgeTrigger : Object
{
	/** Segmento del borde en coordenadas del monitor; ancho/alto 0 según el borde. */
	public abstract void set_edge (int monitor, Gtk.PositionType edge, Gdk.Rectangle line);
	public abstract void clear ();
	public abstract void release_pointer ();     // dejar pasar el puntero tras disparar
	public signal void hit (double delta, uint32 time);
	public signal void left ();
}
```

El umbral de presión (`PRESSURE_THRESHOLD`, `PRESSURE_TIMEOUT`) se queda en
`HideManager`; el backend sólo entrega eventos.

- **X11:** XFixes + XInput 2.3, código de `HideManager.vala:600-761`.
- **Wayland:** no hay barreras. Aproximación: superficie layer-shell de 1-2 px en
  el borde con `exclusive_zone = -1` y región de entrada; dispara al entrar (sin
  presión real) o acumulando movimiento contra el borde con
  `zwp_relative_pointer_v1`. `create_edge_trigger` puede devolver un trigger
  «hot edge» o `null`.

### 2.7 Tecla Super

```vala
public interface SuperKeyTrigger : Object
{
	public abstract bool available { get; }
	public signal void activated (uint32 timestamp);
}
```

- **X11:** el `SuperKeyBinding` actual.
- **Wayland:** no se pueden capturar teclas globales. Opciones:
  `org.freedesktop.portal.GlobalShortcuts` (KDE, GNOME ≥ 48, Hyprland; requiere
  modificador + tecla, Super sola normalmente no), o documentar que el usuario
  ate Super en su compositor a una acción D-Bus de Dock-E (hay que exponer
  `toggle-launcher` en `lib/DBus/`). Super sola, «tap» sin otra tecla: **sin
  equivalente** salvo configuración del compositor.

### 2.8 Escritorios virtuales

```vala
public abstract class Workspace : Object
{
	public abstract int index { get; }
	public abstract string name { get; }
	public abstract bool is_active { get; }
	public abstract bool is_viewport { get; }   // Compiz; siempre false en Wayland
	public abstract void activate (uint32 timestamp);
}

public interface WorkspaceManager : Object
{
	public abstract Gee.List<Workspace> list ();
	public abstract Workspace? active { get; }
	public signal void changed ();                          // añadidos/quitados/renombrados
	public signal void active_changed (Workspace? previous);

	public abstract bool showing_desktop { get; }
	public abstract void set_showing_desktop (bool show);
}
```

- **X11:** Wnck (`Wnck.Screen`, `Wnck.Workspace`, `viewports_changed`,
  `toggle_showing_desktop`).
- **Wayland:** `ext-workspace-v1` (lista, nombre, activo, activar; sway, labwc,
  niri, COSMIC, Hyprland a verificar), `cosmic-workspace` en COSMIC.
  `ext-workspace` **no dice qué ventana está en qué escritorio**: la
  previsualización de escritorios con miniaturas de sus ventanas y el filtro
  «sólo escritorio actual» quedan sin datos salvo en COSMIC (ventana↔escritorio en
  `cosmic-toplevel-info`). «Mostrar escritorio»: sin protocolo; se puede emular
  minimizando todas las ventanas con foreign-toplevel y restaurándolas.

### 2.9 Sesión y entorno

```vala
public BackendKind detect_backend ();   // por tipo de Gdk.Display, no por variables
```

`Environment.vala:214` deja de nombrar `Gdk.X11.Screen` y
`AbstractMain.vala:256-260` pasa de «sólo X11» a «¿hay backend para este
display?». Si no lo hay (GNOME Wayland, por ejemplo), se mantiene el mensaje
crítico actual.

---

## 3. Orden de migración

Cada etapa es un commit (o dos) independiente, compila con las mismas
dependencias de hoy y deja el dock funcionando igual en X11. Tamaño relativo:
**XS** < 50 líneas tocadas, **S** ~100, **M** ~300, **L** ~600+, **XL** varias
semanas.

| # | Etapa | Toca | Tamaño |
|---|---|---|---|
| 0 | Crear `lib/Platform/` con `Backend`, `Capability`, `get_backend ()` y un `X11Backend` vacío; enlazar en `lib/Makefile.am`. Sin consumidores. | nuevos archivos, Makefile | XS |
| 1 | **Sesión:** `detect_backend ()`; `Environment` y `AbstractMain` lo usan. El log de versión de Wnck pasa al backend. | `Environment.vala`, `AbstractMain.vala` | XS |
| 2 | **Tecla Super:** `SuperKeyTrigger`; mover `SuperKeyBinding` a `Platform/X11/`. | `SuperKeyBinding.vala`, `DockController.vala:120` | XS |
| 3 | **Reserva de espacio:** `DockSurface.reserve`; `set_struts` y el cálculo absoluto de `PositionManager.get_struts` pasan al backend. | `DockWindow.vala:870-902`, `PositionManager.vala` (struts) | S |
| 4 | **Barreras:** `EdgeTrigger`; `HideManager` conserva la lógica de presión, el backend X11 el código XFixes/XI. Los `#if HAVE_BARRIERS` quedan sólo en `Platform/X11/`. | `HideManager.vala`, `PositionManager.vala:668`, `:1670` | M |
| 5 | **Toplevels:** `Toplevel` + `ToplevelManager` sobre Wnck, conviviendo con el código viejo (aún nadie los usa). Añadir tests unitarios con un backend falso. | nuevos | M |
| 6 | **Ocultado inteligente** sobre `ToplevelManager` (`HideManager.vala:141-172`, `:434-574`). Primer consumidor real: valida la interfaz. | `HideManager.vala` | S |
| 7 | **Escritorios:** `WorkspaceManager`; migrar `WorkspacePreviewWindow`, filtro de `DefaultApplicationDockItemProvider`, `DesktopDockItem`. | 3-4 archivos | M |
| 8 | **Miniaturas:** `WindowThumbnailer` indexado por `Toplevel`; `WindowThumbnails` → `Platform/X11/`. Requiere 5. | `WindowThumbnails.vala`, 2 previsualizaciones | S |
| 9 | **Aplicaciones (I):** `AppTracker` + `RunningApp` con `BamfAppTracker`; `Matcher` queda como fachada que delega (para no romper nada). | `Matcher.vala`, nuevos | M |
| 10 | **Aplicaciones (II):** `ApplicationDockItem.App` pasa a `RunningApp`; proveedores, `TransientDockItem`, `WindowPreviewWindow` y `WindowControl` operan sobre `RunningApp`/`Toplevel`. Rompe la API pública (ver decisión D2). | ~8 archivos | **L** |
| 11 | **Viewports y `smart_focus`:** la lógica Compiz entra en `X11Toplevel.activate`; `WindowControl` queda neutral. | `WindowControl.vala` | S |
| 12 | **Ventanas emergentes:** `DockSurface.setup/place` para el dock y `PopupPlacer` para tooltip, poof, previsualizaciones, lanzador y bandeja. Hacerlo **después** de que se integren las ramas que editan `LauncherWindow` y `TrayToggleItem`. | 7 ventanas | M |
| 13 | **Puntero global:** `HideManager.update_hovered` y `DragManager.vala:229` usan eventos de entrada/salida de la propia ventana cuando no hay `GLOBAL_POINTER`. | 2 archivos | S |
| 14 | **Compilación:** `--with-x11` (por defecto sí) agrupa Wnck/BAMF/X11/XI/XFixes/XDamage; `Platform/X11/` sólo compila con él; `lib/plank.deps` deja de exportar `libbamf3`. Comprobar con `grep` que fuera de `Platform/X11/` no queda ni `Wnck`, ni `Bamf`, ni `Gdk.X11`, ni `X.`. | `configure.ac`, `lib/Makefile.am`, `plank.deps` | S |

### 3.1 Ajustes hechos al ejecutar las etapas 0–4

Rama `claude/refactor-x11-73a736`. Cambios respecto a las interfaces de la
sección 2, con el motivo:

- **Dónde vive `Plank.Platform`:** en `libplank-internal` (no se exporta), no en
  `libplank`. Así las etapas 0–9 no añaden API pública ni símbolos a
  `plank.vapi`; los consumidores de `libplank` guardan los objetos del backend
  en campos privados. Se revisará en la etapa 10, cuando se rompa la API (D2).
- **`get_backend ()`** devuelve `Backend?`: `null` si no hay backend para el
  display (hoy, cualquier cosa que no sea X11). **`detect_backend`** es
  `bool detect_backend (out BackendKind kind)`, porque «sin backend» no es un
  `BackendKind`. `Backend` gana `log_details ()` para el log de versiones de
  Wnck y de barreras que antes hacía `AbstractMain`.
- **Comprobación de sesión (etapa 1):** se arranca si hay backend para el
  `Gdk.Display`, y el backend X11 se rechaza dentro de una sesión con
  `XDG_SESSION_TYPE=wayland` (Xwayland, D4) con el mismo mensaje de antes.
  Única diferencia: un display X11 con `XDG_SESSION_TYPE=tty` o sin
  especificar (p. ej. `startx` desde una consola) antes se rechazaba y ahora
  arranca.
- **Tecla Super (etapa 2):** en vez de una propiedad `super_key`, el backend
  tiene `create_super_key_trigger ()` y cada dock pide el suyo, igual que antes
  cada `DockController` creaba su `SuperKeyBinding` (con varios docks, sólo el
  primero consigue la tecla). La clase pública `SuperKeyBinding` desaparece de
  `libplank`; la había añadido este fork, no estaba en `libplank.symbols` y
  ningún docklet la usaba. `activated` lleva la marca de tiempo de la tecla.
- **Reserva de espacio (etapa 3):** `DockSurface.reserve (edge, area,
  thickness)` en lugar de `(edge, monitor, thickness, start, end)`. `area` es la
  zona donde se coloca el dock (el área de trabajo del monitor, o el monitor
  entero en GNOME, tal como la calcula `PositionManager`) en coordenadas lógicas
  de GDK; un índice de monitor no basta para reproducir el cálculo actual, y
  la reserva parcial (`start`/`end`) no se usa hoy. `create_dock_surface ()`
  sólo tiene `reserve`; `setup`/`place` llegan en la etapa 12.
  `PositionManager.get_struts` queda marcado obsoleto y sin uso, sólo por el
  ABI, hasta la etapa 10.
- **Barreras (etapa 4):** `EdgeTrigger.set_edge (edge, line)` recibe la línea en
  coordenadas de pantalla de GDK, como hoy (sin índice de monitor). La señal es
  `hit (double dx, double dy, uint32 time)` en vez de `hit (delta, time)`,
  porque `HideManager` compara el empuje contra el desplazamiento a lo largo
  del borde. No hay `release_pointer ()`: el backend suelta el puntero después
  de emitir cada evento, como antes. `update_barrier ()` y `get_barrier ()`
  existen ahora aunque no haya barreras; el backend devuelve `null` desde
  `create_edge_trigger ()`.

### 3.2 Ajustes hechos al ejecutar las etapas 5–9

- **`Workspace` y `WorkspaceManager` entran en la etapa 5**, no en la 7:
  `Toplevel.is_on_workspace (Workspace)` los necesita, y el ocultado
  inteligente (etapa 6) necesita el escritorio activo. La etapa 7 sólo migra a
  los consumidores. `list ()` llama a `Wnck.Screen.force_update ()`, como hacía
  la vista de escritorios antes de reconstruirse.
- **`Toplevel`:**
  - `ToplevelState` separa `MAXIMIZED_HORIZONTALLY` y `MAXIMIZED_VERTICALLY`
    (`MAXIMIZED` es la suma), porque el ocultado cuenta cualquiera de las dos.
  - `has_any_state ()` facilita las consultas.
  - `get_icon ()` no tiene tamaño y puede devolver el icono genérico del
    backend, como la vista de escritorios hacía con Wnck.
  - `set_minimized` recibe la marca de tiempo (Wnck la pide para restaurar).
  - `set_icon_geometry (rect)` recibe las coordenadas que ya da
    `PositionManager.get_icon_geometry`, sin la ventana del dock.
  - `transient_for` y `WorkspaceManager.active` son `owned get`.
- **Geometría en píxeles lógicos redondeada hacia fuera** en `X11Toplevel`.
  Así, una ventana toca el dock exactamente en los mismos casos que antes,
  cuando `HideManager` escalaba el dock a píxeles de dispositivo; hay un test
  que lo comprueba posición por posición con escala 2 y 3.
- **`ToplevelManager`:**
  - `non_toplevel_focused` existe porque, con el foco en el escritorio
    (xfdesktop, que no es toplevel), el ocultado sigue calculando.
  - `active_changed` también se emite cuando el foco pasa entre el escritorio y
    ninguna ventana.
  - `lookup_id ()` lleva de un XID de BAMF a su `Toplevel` hasta la etapa 10.
  - Única diferencia con el código viejo: con el foco en el escritorio, el PID
    «activo» ya no es el de xfdesktop. Sólo cambiaría algo si xfdesktop tuviera
    ventanas normales sobre el dock.
- **Ocultado (etapa 6):** el cálculo pasa a `WindowOverlap.compute ()`
  (`lib/Services/WindowOverlap.vala`), neutral y con tests sobre el backend
  falso. Ya no se recalcula al abrir o cerrar ventanas que no son toplevels
  (escritorio, docks, menús, splash), que nunca contaban.
- **Escritorios (etapa 7):**
  - En Compiz, un cambio de viewport llega como `active_changed` del escritorio
    activo, así que `DefaultApplicationDockItemProvider` ya no distingue entre
    las dos señales de Wnck.
  - Al cambiar la ventana activa, comprueba `previous.is_on_workspace (activo)`
    en vez de `get_workspace () == activo`. Sólo difiere con ventanas fijadas
    en todos los escritorios.
  - El filtro por aplicación (`WindowControl.has_window_on_workspace`) sigue
    con BAMF y recibe un `Platform.Workspace` hasta la etapa 10.
  - «Mostrar escritorio» llega al docklet por la nueva función pública
    `Plank.toggle_showing_desktop ()` (y `can_show_desktop ()`): los docklets
    sólo ven la API pública de libplank.
- **Miniaturas (etapa 8):** `create_thumbnailer (width, height)` en vez de una
  propiedad `thumbnailer`. Cada previsualización tiene su tamaño y vacía su
  caché al ocultarse, como antes con su propio `WindowThumbnails`.
- **Aplicaciones (etapa 9):**
  - `BamfAppTracker` emite las señales neutrales y, hasta la etapa 10, también
    las de BAMF (`bamf_*`), que `Matcher` sólo reemite.
  - BAMF puede anunciar una ventana antes que Wnck: `window_opened` y
    `RunningApp.window_added` esperan a que exista el `Toplevel`
    (`ToplevelWaiter`), y `get_windows ()` omite las que Wnck aún no conoce.
  - `RunningApp.name` es `owned get`.
- **Tests:** `Platform.set_backend_for_tests ()` cambia el backend del proceso
  por uno falso (`tests/PlatformFakes.vala`).

### 3.3 Ajustes hechos al ejecutar las etapas 10–14

- **API pública (etapa 10, D2):**
  - El soname sube a `libplank.so.2`; el paquete de Debian pasa a ser
    `libplank2`.
  - `plank.deps`, `plank.pc` y `libplank-dev` ya no piden `libbamf3`.
  - `ApplicationDockItem.App` (ahora un `RunningApp`) e
    `item_for_application ()` quedan `internal`.
  - El método virtual protegido `app_opened (Bamf.Application)` desaparece. Lo
    sustituye la señal interna `unmatched_app_opened`, porque la vtable de un
    método virtual va en la cabecera pública con el tipo del backend.
  - Desaparecen `PositionManager.get_struts ()` y el enum `Struts`.
  - Las declaraciones `internal` de libplank van a `plank-private.h`
    (`--internal-header`), así `plank.h` no incluye las cabeceras de Wnck.
  - Ningún docklet incluido usaba lo que se quitó; no hubo que cambiarlos.
  - `libplank.symbols` se regeneró con `make symbols`.
- **`Matcher` desaparece** en la etapa 10, en vez de quedar como fachada hasta
  la 14: ya no lo usa nadie. `BamfApp` emite `closed` una sola vez, aunque
  BAMF avise del cierre por la aplicación y por el matcher en cualquier orden.
- **El `force_update` de Wnck al abrirse una aplicación** pasa a
  `ToplevelManager.refresh ()`. Antes sólo lo hacía el proveedor base, porque
  el proveedor por defecto lo reemplazaba; ahora lo hacen los dos.
- **Diferencias con ventanas que no son toplevels:** las ventanas de una
  aplicación que el backend no lista (sobre todo los splash, como el de
  LibreOffice) ya no cuentan como ventanas suyas. Mientras una aplicación sólo
  tenga su splash, un clic en su ícono la lanza otra vez en vez de enfocar el
  splash.
- **Viewports (etapa 11):** `Toplevel` gana `is_in_view ()`,
  `shares_view_with ()` e `icon_is_generic`. `X11Toplevel.activate ()` hace lo
  que hacía `center_and_focus_window`. Única diferencia: el reenfoque diferido
  del truco para Compiz usa también ese `activate` (antes era un `activate`
  simple de Wnck), así que, si la ventana tiene un diálogo abierto, enfoca el
  diálogo. La preparación de Wnck como pager pasa a `Backend.initialize ()`.
- **Ventanas emergentes (etapa 12):**
  - `PopupPlacer.place (popup, x, y, anchor)` recibe la posición que ya calcula
    cada ventana y, cuando lo hay, el rectángulo del ítem. En vez de que el
    backend calcule la posición a partir del ancla, la conserva tal cual en
    X11; el ancla queda para un `xdg_positioner`.
  - `PopupPlacer.setup (popup, kind)` no fija el padre: los `transient_for`
    siguen en cada ventana, porque son GTK portable.
  - `AbsolutePopupPlacer` hace con GTK lo mismo que antes cada ventana y es el
    placer del backend X11.
  - `DockSurface.place (edge, area, rect)` recibe el rectángulo en
    coordenadas de pantalla de GDK.
  - El diálogo de `System` no es una ventana del dock y no se tocó.
- **Puntero global (etapa 13):** sólo cambian `update_hovered` y el `grab` de
  `DragManager`. Las otras consultas de puntero global de `DragManager`
  (posición del «poof», ventana proxy de XDND) y de `WindowPreviewWindow`
  quedan para el backend Wayland: usan GTK, no X11, pero suponen un puntero
  global.
- **Compilación (etapa 14):**
  - `--without-x11` quita gdk-x11, BAMF, Wnck y Xlib, y con ellos las barreras
    y XDamage. `Platform/X11/` sólo se compila con `HAVE_X11`.
  - `Backend.vala` reconoce el display por el nombre de su tipo
    (`GdkX11Display`, `GdkWaylandDisplay`).
  - Los tests propios del backend X11 se compilan sólo con `HAVE_X11`.

Al terminar la etapa 14 el dock es idéntico en X11 y la compilación sin X11
debería fallar sólo por falta de backend. A partir de ahí, el backend Wayland, en
este orden (cada paso usable por sí solo):

| # | Etapa Wayland | Tamaño |
|---|---|---|
| W1 | `DockSurface` con gtk-layer-shell + `PopupPlacer` con `xdg_popup`; levantar el bloqueo de sesión cuando hay layer-shell. Dock con lanzadores, sin ventanas. | M |
| W2 | `ToplevelManager` con `wlr-foreign-toplevel` + matcher `app_id` → `.desktop`. Indicadores de ejecución, activar, cerrar, minimizar. | L |
| W3 | `WorkspaceManager` con `ext-workspace-v1`. | M |
| W4 | `EdgeTrigger` «hot edge» y ocultado inteligente reducido (por estado maximizado/pantalla completa del activo en la misma salida). | M |
| W5 | `SuperKeyTrigger` por portal GlobalShortcuts y acción D-Bus. | S |
| W6 | `WindowThumbnailer` con `ext-image-copy-capture`. | L |

---

## 4. Riesgos y límites

### Riesgos de la migración (en X11)

- **API pública de libplank:** `ApplicationDockItem.App` es `Bamf.Application` y
  `plank.pc` arrastra `libbamf3`. Cambiarlo rompe docklets externos compilados
  contra libplank (ver D2).
- **Ramas en paralelo:** las etapas 10 y 12 tocan archivos que otras sesiones
  editan ahora (`TrayToggleItem`, `LauncherWindow`, preferencias). Conviene
  hacerlas después de integrar esas ramas.
- **Sutilezas de BAMF:** la lógica de vistas pendientes (`Matcher.vala:84-131`) y
  las transitorias (`get_transient`) deben pasar tal cual; hay que reproducir
  pruebas manuales con apps que abren ventanas tarde (Chromium, LibreOffice,
  Steam).
- **Rendimiento en reposo:** hay un script de medición de consumo en reposo
  (commit `aa04c9c`); envolver Wnck en objetos propios no debe añadir trabajo por
  evento. Medir antes y después de las etapas 5-10.
- **Escala HiDPI:** los struts y la geometría de Wnck están en píxeles de
  dispositivo y el resto en lógicos (`HideManager.vala:436-442`). Las interfaces
  deben hablar siempre en píxeles lógicos y convertir dentro del backend.

### Lo que no se puede hacer en Wayland

| Función | Situación |
|---|---|
| **Todo, en GNOME (Mutter)** | Sin layer-shell, sin foreign-toplevel, sin ext-workspace. Sólo vía extensión de GNOME Shell o en Xwayland (donde Dock-E sólo vería ventanas X11). Ver D4. |
| Ocultado inteligente exacto (ventana tapa el dock) | Sin geometría de ventanas ajenas. Aproximación: ocultar si la activa está maximizada/a pantalla completa en esa salida. |
| Barreras de presión | No existen; «hot edge» sin presión real. |
| Super sola | Sólo configurando el compositor; el portal no la admite como atajo. |
| Miniaturas en GNOME/KDE | Sólo con diálogo de captura de pantalla. |
| Ventanas por escritorio | Sólo COSMIC; en el resto se pierde el filtro «sólo escritorio actual» y las miniaturas por escritorio. |
| «Mostrar escritorio» | Sin protocolo; emulable minimizando todo. |
| Reserva parcial del borde | La zona exclusiva cubre todo el borde. |
| Icono por ventana, PID, orden de apilado, tipo de ventana | No expuestos; usar icono del `.desktop` y orden de aparición. |
| Viewports estilo Compiz | Sólo X11. |
| Ventana «poof» en coordenadas libres | Sólo como overlay layer-shell o eliminándola. |

Como la regla del proyecto es **no perder funciones**, el backend Wayland debe
declarar estas carencias en `capabilities` y la UI ocultar o degradar cada
opción (por ejemplo, el modo de ocultado «inteligente» aparece como «ocultar con
ventanas maximizadas») en lugar de mostrar opciones que no hacen nada. En X11
todas las capacidades siguen activas.

---

## 5. Decisiones (tomadas por el usuario el 2026-11-21)

Resueltas, en todos los casos con la opción recomendada:

- **D1:** modelo propio `RunningApp`/`Toplevel`; BAMF y Wnck quedan dentro del backend X11.
- **D2:** se rompe la API pública de libplank en la etapa 10 (sube el soname y se actualizan los docklets incluidos).
- **D3:** backend Wayland con gtk-layer-shell y los protocolos en C de `wayland-scanner` envueltos en GObject.
- **D4:** GNOME en Wayland no se soporta en el backend nativo; mensaje claro al arrancar.

Las opciones consideradas se conservan abajo como referencia.

### Opciones consideradas

**D1. Modelo de aplicaciones y ventanas**
1. *(Recomendada)* Modelo propio `RunningApp`/`Toplevel` en `Plank.Platform`, con
   BAMF y Wnck como detalle del backend X11.
2. Interfaces finas con identificadores opacos (`uint64`) y funciones de consulta,
   sin objetos: menos código, pero cada consumidor vuelve a preguntar todo.
3. Mantener BAMF como modelo y sólo aislar Wnck: menos trabajo hoy, pero impide
   Wayland (BAMF es sólo X11).

**D2. API pública de libplank (`ApplicationDockItem.App`, `plank.pc`)**
1. *(Recomendada)* Romperla en la etapa 10: subir soname, `App` pasa a
   `RunningApp`, quitar `libbamf3` de `plank.deps`. Los docklets incluidos se
   actualizan en el mismo commit.
2. Mantener `App : Bamf.Application` marcado `[Version (deprecated = true)]` en
   compilaciones con X11 y añadir `RunningApp` aparte durante un ciclo.
3. Declarar libplank privada (sólo para los docklets del árbol) y dejar de
   instalar sus cabeceras/vapi.

**D3. Cómo escribir el backend Wayland**
1. *(Recomendada)* gtk-layer-shell (con su vapi) para superficies, y los
   protocolos (`wlr-foreign-toplevel`, `ext-workspace`, captura) en C generado
   por `wayland-scanner`, envueltos en GObject pequeños con su `.vapi`.
2. Todo en Vala con `.vapi` escritos a mano sobre el C de `wayland-scanner`.
3. Delegar en un proceso auxiliar (p. ej. un helper que hable D-Bus) que
   implemente los protocolos, y que Dock-E sólo hable D-Bus.

**D4. GNOME en Wayland**
1. *(Recomendada)* No soportarlo en el backend nativo: mensaje claro al arrancar
   y sugerencia de iniciar sesión X11.
2. Permitir arrancar en Xwayland (`GDK_BACKEND=x11`) con funciones reducidas: sólo
   ve aplicaciones X11, sin struts fiables ni Super.
3. Extensión de GNOME Shell compañera que exponga ventanas, escritorios y
   posición por D-Bus, como backend propio. Es otro proyecto a mantener.

Decisión técnica que no hace falta preguntar: el backend se elige **en tiempo
de ejecución** según el `Gdk.Display` (ambos backends compilables a la vez), no
en tiempo de compilación.
