//
//  Copyright (C) 2012 Robert Dyer, Rico Tzschichholz
//
//  This file is part of Plank.
//
//  Plank is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Plank is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

namespace Plank
{
	/**
	 * Handles computing any size/position information for the dock.
	 */
	public class PositionManager : GLib.Object
	{
		const int BAR_SIDE_INSET = 12;
		const double CENTRAL_HOVER_CLEARANCE = 0.75;
		public DockController controller { private get; construct; }
		
		public bool screen_is_composited { get; private set; }
		
		Gdk.Rectangle static_dock_region;
		Gee.HashMap<DockElement, DockItemDrawValue> draw_values;
		
		Gdk.Rectangle monitor_geo;
		
		int window_scale_factor = 1;
		
		/**
		 * Creates a new position manager.
		 *
		 * @param controller the dock controller to manage positions for
		 */
		public PositionManager (DockController controller)
		{
			GLib.Object (controller : controller);
		}
		
		construct
		{
			static_dock_region = {};
			draw_values = new Gee.HashMap<DockElement, DockItemDrawValue> ();
		}
		
		/**
		 * Initializes the position manager.
		 */
		public void initialize ()
			requires (controller.window != null)
		{
			unowned Gdk.Screen screen = controller.window.get_screen ();
			
			controller.prefs.notify.connect (prefs_changed);
			screen.monitors_changed.connect (screen_changed);
			screen.size_changed.connect (screen_changed);
			screen.composited_changed.connect (screen_composited_changed);
			
			// NOTE don't call update_monitor_geo to avoid a double-call of dockwindow.set_size on startup
			var session=Environment.get_variable("XDG_CURRENT_DESKTOP");
			if (session != null && session.contains("GNOME")) {
				screen.get_monitor_geometry (find_monitor_number (screen, controller.prefs.Monitor), out monitor_geo);
			}
			else {
				monitor_geo = screen.get_monitor_workarea (find_monitor_number (screen, controller.prefs.Monitor));
			};

			screen_is_composited = screen.is_composited ();
		}
		
		~PositionManager ()
		{
			unowned Gdk.Screen screen = controller.window.get_screen ();
			
			screen.monitors_changed.disconnect (screen_changed);
			screen.size_changed.disconnect (screen_changed);
			screen.composited_changed.disconnect (screen_composited_changed);
			controller.prefs.notify.disconnect (prefs_changed);
			
			draw_values.clear ();
		}
		
		void prefs_changed (Object prefs, ParamSpec prop)
		{
			switch (prop.name) {
			case "Monitor":
				prefs_monitor_changed ();
				break;
			default:
				// Nothing important for us changed
				break;
			}
		}
		
		public static string[] get_monitor_plug_names (Gdk.Screen screen)
		{
			int n_monitors = screen.get_n_monitors ();
			var result = new string[n_monitors];
			
			for (int i = 0; i < n_monitors; i++)
				result[i] = screen.get_monitor_plug_name (i) ?? "PLUG_MONITOR_%i".printf (i);
			
			return result;
		}
		
		static int find_monitor_number (Gdk.Screen screen, string plug_name)
		{
			if (plug_name == "")
				return screen.get_primary_monitor ();
			
			int n_monitors = screen.get_n_monitors ();
			
			for (int i = 0; i < n_monitors; i++) {
				var name = screen.get_monitor_plug_name (i) ?? "PLUG_MONITOR_%i".printf (i);
				if (plug_name == name)
					return i;
			}
			
			return screen.get_primary_monitor ();
		}
		
		void prefs_monitor_changed ()
		{
			screen_changed (controller.window.get_screen ());
		}

		void screen_changed (Gdk.Screen screen)
		{
			var old_monitor_geo = monitor_geo;

			var session=Environment.get_variable("XDG_CURRENT_DESKTOP");
			if (session != null && session.contains("GNOME")) {
				screen.get_monitor_geometry (find_monitor_number (screen, controller.prefs.Monitor), out monitor_geo);
			}
			else {
				monitor_geo = screen.get_monitor_workarea (find_monitor_number (screen, controller.prefs.Monitor));
			};

			// No need to do anything if nothing has actually changed
			if (old_monitor_geo.x == monitor_geo.x
				&& old_monitor_geo.y == monitor_geo.y
				&& old_monitor_geo.width == monitor_geo.width
				&& old_monitor_geo.height == monitor_geo.height)
				return;
			
			Logger.verbose ("PositionManager.monitor_geo_changed (%i,%i-%ix%i)",
				monitor_geo.x, monitor_geo.y, monitor_geo.width, monitor_geo.height);
			
			freeze_notify ();
			
			update_dimensions ();
			update_regions ();
			
			thaw_notify ();
		}
		
		void screen_composited_changed (Gdk.Screen screen)
		{
			freeze_notify ();
			
			screen_is_composited = screen.is_composited ();
			
			update (controller.renderer.theme);
 			
			thaw_notify ();
		}
 		
		//
		// used to cache various sizes calculated from the theme and preferences
		//
		
		/**
		 * Theme-based line-width.
		 */
		public int LineWidth { get; private set; }
		
		/**
		 * Cached current icon size for the dock.
		 */
		public int IconSize { get; private set; }
		
		/**
		 * Cached current icon size for the dock.
		 */
		public int ZoomIconSize { get; private set; }
		
		/**
		 * Cached position of the dock.
		 */
		public Gtk.PositionType Position { get; private set; }
		
		/**
		 * Cached alignment of the dock.
		 */
		public Gtk.Align Alignment { get; private set; }
		
		/**
		 * Cached alignment of the items.
		 */
		public Gtk.Align ItemsAlignment { get; private set; }
		
		/**
		 * Cached offset of the dock.
		 */
		public int Offset { get; private set; }
		
		/**
		 * Theme-based indicator size, scaled by icon size.
		 */
		public int IndicatorSize { get; private set; }
		/**
		 * Theme-based icon-shadow size, scaled by icon size.
		 */
		public int IconShadowSize { get; private set; }
		/**
		 * Theme-based urgent glow size, scaled by icon size.
		 */
		public int GlowSize { get; private set; }
		/**
		 * Theme-based horizontal padding, scaled by icon size.
		 */
		public int HorizPadding  { get; private set; }
		/**
		 * Theme-based top padding, scaled by icon size.
		 */
		public int TopPadding    { get; private set; }
		/**
		 * Theme-based bottom padding, scaled by icon size.
		 */
		public int BottomPadding { get; private set; }
		/**
		 * Theme-based distance from the screen edge, scaled by icon size.
		 */
		public int DockMargin { get; private set; }
		/**
		 * Theme-based item padding, scaled by icon size.
		 */
		public int ItemPadding   { get; private set; }
		/**
		 * Theme-based urgent-bounce height, scaled by icon size.
		 */
		public int UrgentBounceHeight { get; private set; }
		/**
		 * Theme-based launch-bounce height, scaled by icon size.
		 */
		public int LaunchBounceHeight { get; private set; }
		
		int items_width;
		int items_offset;
		int top_offset;
		int bottom_offset;
		int extra_hide_offset;
		
		/**
		 * x position of the dock window.
		 */
		int win_x;
		/**
		 * y position of the dock window.
		 */
		int win_y;

		/**
		 * The currently visible height of the dock.
		 */
		int VisibleDockHeight;
		/**
		 * The static height of the dock.
		 */
		int DockHeight;
		/**
		 * The height of the dock's background image.
		 */
		int DockBackgroundHeight;
		
		/**
		 * The currently visible width of the dock.
		 */
		int VisibleDockWidth;
		/**
		 * The static width of the dock.
		 */
		int DockWidth;
		/**
		 * The width of the dock's background image.
		 */
		int DockBackgroundWidth;
		
		Gdk.Rectangle background_rect;
		Gdk.Rectangle primary_background_rect;
		Gdk.Rectangle status_background_rect;
		
		/**
		 * The maximum item count which fit the dock in its maximum
		 * size with the current theme and icon-size.
		 */
		public int MaxItemCount { get; private set; }
		
		/**
		 * The maximum icon-size which results in a dock which fits on
		 * the target screen edge.
		 */
		int MaxIconSize { get; private set; default = DockPreferences.MAX_ICON_SIZE; }
		
		/**
		 * Updates all internal caches.
		 *
		 * @param theme the current dock theme
		 */
		public void update (DockTheme theme)
		{
			Logger.verbose ("PositionManager.update ()");
			
			screen_is_composited = controller.window.get_screen ().is_composited ();
			
			freeze_notify ();
			
			update_caches (theme);
			update_max_icon_size (theme);
			update_dimensions ();
			update_regions ();
			
			thaw_notify ();
		}
		
		void update_caches (DockTheme theme)
		{
			unowned DockPreferences prefs = controller.prefs;
			
			Position = Gtk.PositionType.BOTTOM;
			Alignment = prefs.Alignment;
			ItemsAlignment = prefs.ItemsAlignment;
			Offset = prefs.Offset;
			
			// Mirror position/alignments/offset for RTL environments if needed
			if (Gtk.Widget.get_default_direction () == Gtk.TextDirection.RTL) {
				if (is_horizontal_dock ()) {
					if (Alignment == Gtk.Align.START)
						Alignment = Gtk.Align.END;
					else if (Alignment == Gtk.Align.END)
						Alignment = Gtk.Align.START;
					
					if (ItemsAlignment == Gtk.Align.START)
						ItemsAlignment = Gtk.Align.END;
					else if (ItemsAlignment == Gtk.Align.END)
						ItemsAlignment = Gtk.Align.START;
					
					Offset = -Offset;
				} else {
					if (Position == Gtk.PositionType.RIGHT)
						Position = Gtk.PositionType.LEFT;
					else
						Position = Gtk.PositionType.RIGHT;
				}
			}
			
			IconSize = int.min (MaxIconSize, prefs.IconSize);
			ZoomIconSize = IconSize;
			
			var scaled_icon_size = IconSize / 10.0;
			
			IconShadowSize = (int) Math.ceil (theme.IconShadowSize * scaled_icon_size);
			IndicatorSize = (int) (theme.IndicatorSize * scaled_icon_size);
			GlowSize      = (int) (theme.GlowSize      * scaled_icon_size);
			HorizPadding  = (int) (theme.HorizPadding  * scaled_icon_size);
			TopPadding    = (int) (theme.TopPadding    * scaled_icon_size);
			BottomPadding = (int) (theme.BottomPadding * scaled_icon_size);
			DockMargin    = (int) (theme.DockMargin    * scaled_icon_size);
			ItemPadding   = (int) (theme.ItemPadding   * scaled_icon_size);
			var hover_clearance = (int) Math.ceil (CENTRAL_HOVER_CLEARANCE * scaled_icon_size);
			if (theme.HorizPadding >= 0)
				HorizPadding += hover_clearance;
			if (theme.TopPadding >= 0)
				TopPadding += hover_clearance;
			if (theme.BottomPadding >= 0)
				BottomPadding += hover_clearance;
			UrgentBounceHeight = (int) (theme.UrgentBounceHeight * IconSize);
			LaunchBounceHeight = (int) (theme.LaunchBounceHeight * IconSize);
			LineWidth     = theme.LineWidth;
			
			if (!screen_is_composited) {
				if (HorizPadding < 0)
					HorizPadding = (int) scaled_icon_size;
				if (TopPadding < 0)
					TopPadding = (int) scaled_icon_size;
			}
			
			items_offset  = (int) (2 * LineWidth + (HorizPadding > 0 ? HorizPadding : 0));
			
			top_offset = theme.get_top_offset () + TopPadding;
			bottom_offset = theme.get_bottom_offset () + BottomPadding;
			
			if (top_offset < 0)
				extra_hide_offset = IconShadowSize;
			else if (top_offset < IconShadowSize)
				extra_hide_offset = (IconShadowSize - top_offset);
			else
				extra_hide_offset = 0;
		}
		
		/**
		 * Find an appropriate MaxIconSize
		 */
		void update_max_icon_size (DockTheme theme)
		{
			unowned DockPreferences prefs = controller.prefs;
			
			// Check if the dock is oversized and doesn't fit the targeted screen-edge
			var item_count = controller.VisibleItems.size;
			var width = item_count * (ItemPadding + IconSize) + 2 * HorizPadding + 4 * LineWidth;
			var max_width = (is_horizontal_dock () ? monitor_geo.width : monitor_geo.height);
			var step_size = int.max (1, (int) (Math.fabs (width - max_width) / item_count));
			
			if (width > max_width && MaxIconSize > DockPreferences.MIN_ICON_SIZE) {
				MaxIconSize -= step_size;
			} else if (width < max_width && MaxIconSize < prefs.IconSize && step_size > 1) {
				MaxIconSize += step_size;
			} else {
				// Make sure the MaxIconSize is even and restricted properly
				MaxIconSize = int.max (DockPreferences.MIN_ICON_SIZE,
					int.min (DockPreferences.MAX_ICON_SIZE, (int) (MaxIconSize / 2.0) * 2));
				Logger.verbose ("PositionManager.MaxIconSize = %i", MaxIconSize);
				update_caches (theme);
				return;
			}
			
			update_caches (theme);
			update_max_icon_size (theme);
		}
		
		void update_dimensions ()
		{
			Logger.verbose ("PositionManager.update_dimensions ()");
			
			// height of the visible (cursor) rect of the dock
			var height = IconSize + top_offset + bottom_offset;
			
			// height of the dock background image, as drawn
			var background_height = int.max (0, height);
			
			if (top_offset < 0)
				height -= top_offset;
			
			// height of the dock window
			var dock_height = height + (screen_is_composited ? UrgentBounceHeight : 0);
			
			var width = 0;
			switch (Alignment) {
			default:
			case Gtk.Align.START:
			case Gtk.Align.END:
			case Gtk.Align.CENTER:
				width = controller.VisibleItems.size * (ItemPadding + IconSize) + 2 * HorizPadding + 4 * LineWidth;
				break;
			case Gtk.Align.FILL:
				if (is_horizontal_dock ())
					width = monitor_geo.width;
				else
					width = monitor_geo.height;
				break;
			}
			
			// width of the dock background image, as drawn
			var background_width = int.max (0, width);
			
			// width of the visible (cursor) rect of the dock
			if (HorizPadding < 0)
				width -= 2 * HorizPadding;
			
			if (is_horizontal_dock ()) {
				width = int.min (monitor_geo.width, width);
				VisibleDockHeight = height;
				VisibleDockWidth = width;
				DockHeight = dock_height + DockMargin;
				DockWidth = (screen_is_composited ? monitor_geo.width : width);
				DockBackgroundHeight = background_height;
				DockBackgroundWidth = background_width;
				MaxItemCount = (int) Math.floor ((double) (monitor_geo.width - 2 * HorizPadding + 4 * LineWidth) / (ItemPadding + IconSize));
			} else {
				width = int.min (monitor_geo.height, width);
				VisibleDockHeight = width;
				VisibleDockWidth = height;
				DockHeight = (screen_is_composited ? monitor_geo.height : width);
				DockWidth = dock_height + DockMargin;
				DockBackgroundHeight = background_width;
				DockBackgroundWidth = background_height;
				MaxItemCount = (int) Math.floor ((double) (monitor_geo.height - 2 * HorizPadding + 4 * LineWidth) / (ItemPadding + IconSize));
			}
		}
		
		/**
		 * Return whether or not a dock is a horizontal dock.
		 *
		 * @return true if the dock's position indicates it is horizontal
		 */
		public bool is_horizontal_dock ()
		{
			return (Position == Gtk.PositionType.TOP || Position == Gtk.PositionType.BOTTOM);
		}
		
		/**
		 * Returns the cursor region for the dock.
		 * This is the region that the cursor can interact with the dock.
		 *
		 * @return the cursor region for the dock
		 */
		public Gdk.Rectangle get_cursor_region ()
		{
			var cursor_region = static_dock_region;
			var progress = 1.0 - controller.renderer.hide_progress;
			window_scale_factor = controller.window.get_window ().get_scale_factor ();

			// The visual dock can extend beyond the original static region after
			// rotation, theme padding, or section layout. Input must cover the full
			// visual union, including the transparent bridge to the screen edge.
			if (background_rect.width > 0 && background_rect.height > 0) {
				cursor_region.union (background_rect, out cursor_region);
			}
			
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				var full_height = DockHeight - cursor_region.y;
				cursor_region.height = int.max (1 * window_scale_factor, (int) (progress * full_height));
				cursor_region.y = DockHeight - cursor_region.height + (window_scale_factor - 1);
				break;
			case Gtk.PositionType.TOP:
				var full_height = cursor_region.y + cursor_region.height;
				cursor_region.height = int.max (1 * window_scale_factor, (int) (progress * full_height));
				cursor_region.y = 0;
				break;
			case Gtk.PositionType.LEFT:
				var full_width = cursor_region.x + cursor_region.width;
				cursor_region.width = int.max (1 * window_scale_factor, (int) (progress * full_width));
				cursor_region.x = 0;
				break;
			case Gtk.PositionType.RIGHT:
				var full_width = DockWidth - cursor_region.x;
				cursor_region.width = int.max (1 * window_scale_factor, (int) (progress * full_width));
				cursor_region.x = DockWidth - cursor_region.width + (window_scale_factor - 1);
				break;
			}
			
			return cursor_region;
		}
		
		/**
		 * Returns the static dock region for the dock.
		 * This is the region that the dock occupies when not hidden.
		 *
		 * @return the static dock region for the dock
		 */
		public Gdk.Rectangle get_static_dock_region ()
		{
			var dock_region = static_dock_region;
			dock_region.x += win_x;
			dock_region.y += win_y;
			
			// Revert adjustments made by update_dock_position () for non-compositing mode
			if (!screen_is_composited && controller.hide_manager.Hidden) {
				switch (Position) {
				default:
				case Gtk.PositionType.BOTTOM:
					dock_region.y -= DockHeight - 1;
					break;
				case Gtk.PositionType.TOP:
					dock_region.y += DockHeight - 1;
					break;
				case Gtk.PositionType.LEFT:
					dock_region.x += DockWidth - 1;
					break;
				case Gtk.PositionType.RIGHT:
					dock_region.x -= DockWidth - 1;
					break;
				}
			}
			
			return dock_region;
		}
		
		/**
		 * Call when any cached region needs updating.
		 */
		public void update_regions ()
		{
			Logger.verbose ("PositionManager.update_regions ()");
			
			var old_region = static_dock_region;
			
			// width of the items-area of the dock
			items_width = controller.VisibleItems.size * (ItemPadding + IconSize);
			
			static_dock_region.width = VisibleDockWidth;
			static_dock_region.height = VisibleDockHeight;
			
			var xoffset = (DockWidth - static_dock_region.width) / 2;
			var yoffset = (DockHeight - static_dock_region.height) / 2;
			
			if (screen_is_composited) {
				var offset = Offset;
				xoffset = (int) ((1 + offset / 100.0) * xoffset);
				yoffset = (int) ((1 + offset / 100.0) * yoffset);
				
				switch (Alignment) {
				default:
				case Gtk.Align.CENTER:
				case Gtk.Align.FILL:
					break;
				case Gtk.Align.START:
					if (is_horizontal_dock ()) {
						xoffset = 0;
						yoffset = (monitor_geo.height - static_dock_region.height);
					} else {
						xoffset = (monitor_geo.width - static_dock_region.width);
						yoffset = 0;
					}
					break;
				case Gtk.Align.END:
					if (is_horizontal_dock ()) {
						xoffset = (monitor_geo.width - static_dock_region.width);
						yoffset = 0;
					} else {
						xoffset = 0;
						yoffset = (monitor_geo.height - static_dock_region.height);
					}
					break;
				}
			}
			
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				static_dock_region.x = xoffset;
				static_dock_region.y = DockHeight - static_dock_region.height - DockMargin;
				break;
			case Gtk.PositionType.TOP:
				static_dock_region.x = xoffset;
				static_dock_region.y = DockMargin;
				break;
			case Gtk.PositionType.LEFT:
				static_dock_region.y = yoffset;
				static_dock_region.x = DockMargin;
				break;
			case Gtk.PositionType.RIGHT:
				static_dock_region.y = yoffset;
				static_dock_region.x = DockWidth - static_dock_region.width - DockMargin;
				break;
			}
			
			update_dock_position ();
			
			if (!screen_is_composited
				|| old_region.x != static_dock_region.x
				|| old_region.y != static_dock_region.y
				|| old_region.width != static_dock_region.width
				|| old_region.height != static_dock_region.height) {
				controller.window.update_size_and_position ();
#if HAVE_BARRIERS
				controller.hide_manager.update_barrier ();
#endif
				
				// With active compositing support update_size_and_position () won't trigger a redraw
				// (a changed static_dock_region doesn't implicate the window-size changed)
				if (screen_is_composited)
					controller.renderer.animated_draw ();
			} else {
				controller.renderer.animated_draw ();
			}
		}
		
		/**
		 * The draw-value for a dock item.
		 *
		 * @param item the dock item to find the drawvalue for
		 * @return the region for the dock item
		 */
		public DockItemDrawValue get_draw_value_for_item (DockItem item)
		{
			if (draw_values.size == 0) {
				debug ("Without draw_values there is trouble ahead");
				update_draw_values (controller.VisibleItems);
			}
			
			var draw_value = draw_values[item];
			if (draw_value == null) {
				warning ("Without a draw_value there is trouble ahead for '%s'", item.Text);
				draw_value = new DockItemDrawValue ();
			}
			
			return draw_value;
		}
		
		/**
		 * Update and recalculated all internal draw-values using the given methodes for custom manipulations.
		 *
		 * @param items the ordered list of all current item which are suppose to be shown on the dock
		 * @param func a function which adjusts the draw-value per item
		 * @param post_func a function which post-processes all draw-values
		 */
		public void update_draw_values (Gee.ArrayList<unowned DockItem> items, DrawValueFunc? func = null,
			DrawValuesFunc? post_func = null)
		{
			draw_values.clear ();
			
			// first we do the math as if this is a top dock, to do this we need to set
			// up some "pretend" variables. we pretend we are a top dock because 0,0 is
			// at the top.
			int height = is_horizontal_dock () ? DockHeight : DockWidth;
			int icon_size = IconSize;
			
			//FIXME
			// the line along the dock width about which the center of unzoomed icons sit
			double center_y = (is_horizontal_dock () ? static_dock_region.height / 2.0 : static_dock_region.width / 2.0);
			
			double center_x = (icon_size + ItemPadding) / 2.0 + items_offset;
			if (Alignment == Gtk.Align.FILL) {
				switch (ItemsAlignment) {
				default:
				case Gtk.Align.FILL:
				case Gtk.Align.CENTER:
					if (is_horizontal_dock ())
						center_x += static_dock_region.x + (static_dock_region.width - 2 * items_offset - items_width) / 2;
					else
						center_x += static_dock_region.y + (static_dock_region.height - 2 * items_offset - items_width) / 2;
					break;
				case Gtk.Align.START:
					break;
				case Gtk.Align.END:
					if (is_horizontal_dock ())
						center_x += static_dock_region.x + (static_dock_region.width - 2 * items_offset - items_width);
					else
						center_x += static_dock_region.y + (static_dock_region.height - 2 * items_offset - items_width);
					break;
				}
			} else {
				if (is_horizontal_dock ())
					center_x += static_dock_region.x;
				else
					center_x += static_dock_region.y;
			}
			
			PointD center = { Math.floor (center_x), Math.floor (center_y) };
			
			foreach (unowned DockItem item in items) {
				DockItemDrawValue val = new DockItemDrawValue ();
				val.opacity = 1.0;
				val.darken = 0.0;
				val.lighten = 0.0;
				val.show_indicator = true;
				val.zoom = 1.0;
				
				val.static_center = center;
				
				val.center = { Math.round (center.x), icon_size / 2.0 };
				val.icon_size = icon_size;
				
				// now we undo our transforms to the point
				if (!is_horizontal_dock ()) {
					double tmp = val.center.y;
					val.center.y = val.center.x;
					val.center.x = tmp;
					
					tmp = val.static_center.y;
					val.static_center.y = val.static_center.x;
					val.static_center.x = tmp;
				}
				
				switch (Position) {
				case Gtk.PositionType.RIGHT:
					val.center.x = height - val.center.x;
					val.static_center.x = height - val.static_center.x;
					break;
				case Gtk.PositionType.BOTTOM:
					val.center.y = height - val.center.y;
					val.static_center.y = height - val.static_center.y;
					break;
				default:
					break;
				}
				
				//FIXME
				val.move_in (Position, bottom_offset + DockMargin);

				// let the draw-value be modified by the given function
				if (func != null)
					func (item, val);
				
				draw_values[item] = val;
				
				//FIXME
				// Don't reserve space for removed items
				if (item.RemoveTime == 0)
					center.x += icon_size + ItemPadding;
			}
			
			if (post_func != null)
				post_func (draw_values);

			DockItem? primary_first = null;
			DockItem? primary_last = null;
			DockItem? status_first = null;
			DockItem? status_last = null;
			DockItem? left_first = null;
			DockItem? left_last = null;
			var status_count = 0;
			foreach (unowned DockItem item in items) {
				if (item is UpdateManagerItem || item is TrayToggleItem || item is TrayStatusItem
					|| item is TrayOverflowItem || item is WorkspaceItem) {
					if (left_first == null)
						left_first = item;
					left_last = item;
				} else if (item is StatusIndicatorItem) {
					if (status_first == null)
						status_first = item;
					status_last = item;
					status_count++;
				} else {
					if (primary_first == null)
						primary_first = item;
					primary_last = item;
				}
			}

			// Left-side controls share a provider with the launcher button, so their
			// original slots sit between the launcher and application items. Compact
			// the central sequence after classification to remove those empty slots,
			// while move_right() preserves each item's current draw displacement.
			DockItem? previous_primary = null;
			foreach (unowned DockItem item in items) {
				if (item is StatusIndicatorItem || item is UpdateManagerItem
					|| item is TrayToggleItem || item is TrayStatusItem || item is TrayOverflowItem
					|| item is WorkspaceItem)
					continue;
				if (previous_primary != null) {
					var desired_axis = axis_position (draw_values[previous_primary], true)
						+ IconSize + ItemPadding;
					var compact_shift = desired_axis - axis_position (draw_values[item], true);
					draw_values[item].move_right (Position, compact_shift);
				}
				previous_primary = item;
			}

			if (primary_first != null && primary_last != null) {
				// Center the primary section against the full bar, independently of
				// the number and width of the controls anchored at either edge.
				var primary_center = (axis_position (draw_values[primary_first], true)
					+ axis_position (draw_values[primary_last], true)) / 2.0;
				var primary_shift = axis_length () / 2.0 - primary_center;
				foreach (unowned DockItem item in items) {
					if (!(item is StatusIndicatorItem) && !(item is UpdateManagerItem)
						&& !(item is TrayToggleItem) && !(item is TrayStatusItem)
						&& !(item is TrayOverflowItem) && !(item is WorkspaceItem))
						draw_values[item].move_right (Position, primary_shift);
				}
			}

			if (status_count > 0) {
				var side_inset = BAR_SIDE_INSET * window_scale_factor;
				var background_padding = ItemPadding + 2 * HorizPadding + 4 * LineWidth;
				var status_last_center = axis_position (draw_values[status_last]);
				var desired_last_center = axis_length () - DockMargin - side_inset
					- (IconSize + background_padding) / 2.0;
				var status_shift = desired_last_center - status_last_center;
				foreach (unowned DockItem item in items) {
					if (item is StatusIndicatorItem)
						draw_values[item].move_right (Position, status_shift);
				}
			}

			if (left_first != null && left_last != null) {
				var side_inset = BAR_SIDE_INSET * window_scale_factor;
				var background_padding = ItemPadding + 2 * HorizPadding + 4 * LineWidth;
				var desired_center = DockMargin + side_inset + (IconSize + background_padding) / 2.0;
				var left_shift = desired_center - axis_position (draw_values[left_first]);
				foreach (unowned DockItem item in items)
					if (item is UpdateManagerItem || item is TrayToggleItem || item is TrayStatusItem
						|| item is TrayOverflowItem || item is WorkspaceItem)
						draw_values[item].move_right (Position, left_shift);
			}

			primary_background_rect = {};
			status_background_rect = {};
			if (primary_first != null && primary_last != null) {
				update_background_region (draw_values[primary_first], draw_values[primary_last]);
				primary_background_rect = background_rect;
			}
			if (status_first != null && status_last != null) {
				update_background_region (draw_values[status_first], draw_values[status_last]);
				status_background_rect = background_rect;
			}

			// Keep the fixed status icons centered inside their own background,
			// independently of the launchers' zoom-oriented baseline.
			if (status_background_rect.width > 0 && status_background_rect.height > 0) {
				var status_cross_center = is_horizontal_dock ()
					? status_background_rect.y + status_background_rect.height / 2.0
					: status_background_rect.x + status_background_rect.width / 2.0;
				foreach (unowned DockItem item in items) {
					if (!(item is StatusIndicatorItem) && !(item is UpdateManagerItem)
						&& !(item is TrayToggleItem) && !(item is TrayStatusItem)
						&& !(item is TrayOverflowItem) && !(item is WorkspaceItem))
						continue;

					var value = draw_values[item];
					if (is_horizontal_dock ()) {
						value.center.y = status_cross_center;
						value.static_center.y = status_cross_center;
					} else {
						value.center.x = status_cross_center;
						value.static_center.x = status_cross_center;
					}
				}
			}

			if (primary_background_rect.width > 0 && status_background_rect.width > 0)
				primary_background_rect.union (status_background_rect, out background_rect);
			else if (primary_background_rect.width > 0)
				background_rect = primary_background_rect;
			else
				background_rect = status_background_rect;

			// With side sections enabled, render one continuous bar with the
			// theme's floating margin on every edge. Central-only mode keeps the
			// compact background calculated from the menu and application items.
			if (controller.prefs.ShowSideSections
				&& background_rect.width > 0 && background_rect.height > 0) {
				var side_inset = BAR_SIDE_INSET * window_scale_factor;
				if (is_horizontal_dock ()) {
					background_rect.x = DockMargin + side_inset;
					background_rect.width = int.max (1, DockWidth - 2 * (DockMargin + side_inset));
				} else {
					background_rect.y = DockMargin + side_inset;
					background_rect.height = int.max (1, DockHeight - 2 * (DockMargin + side_inset));

					// Vertical docks use a rotated theme whose asymmetric top/bottom
					// padding otherwise leaves application icons on a different axis
					// from the fixed controls. Center every visual icon in the final
					// painted bar while preserving its animation/static displacement.
					var cross_center = background_rect.x + background_rect.width / 2.0;
					foreach (unowned DockItem item in items) {
						var value = draw_values[item];
						var static_delta = value.static_center.x - value.center.x;
						value.center.x = cross_center;
						value.static_center.x = cross_center + static_delta;
					}
				}
			}
			
			// precalculate and cache regions (for the current frame)
			draw_values.map_iterator ().foreach ((i, val) => {
				val.draw_region = get_item_draw_region (val);
				val.hover_region = get_item_hover_region (val);
				val.background_region = get_item_background_region (val);
				return true;
			});
		}
		/**
		 * The region for drawing a dock item.
		 *
		 * @param val the item's DockItemDrawValue
		 * @return the region for the dock item
		 */
		Gdk.Rectangle get_item_draw_region (DockItemDrawValue val)
		{
			var width = val.icon_size, height = val.icon_size;
			
			return { (int) Math.round (val.center.x - width / 2.0),
				(int) Math.round (val.center.y - height / 2.0),
				(int) width,
				(int) height };
		}
		
		/**
		 * The intersecting region of a dock item's hover region and the background.
		 *
		 * @param val the item's DockItemDrawValue
		 * @return the region for the dock item
		 */
		Gdk.Rectangle get_item_background_region (DockItemDrawValue val)
		{
			Gdk.Rectangle rect;
			var hover_region = val.hover_region;
			
			// FIXME Do this a better way
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				hover_region.height = (background_rect.y + background_rect.height - hover_region.y).abs ();
				break;
			case Gtk.PositionType.TOP:
				hover_region.y = background_rect.y;
				hover_region.height = (hover_region.y - background_rect.y + background_rect.height).abs ();
				break;
			case Gtk.PositionType.LEFT:
				hover_region.x = background_rect.x;
				hover_region.width = (hover_region.x - background_rect.x + background_rect.width).abs ();
				break;
			case Gtk.PositionType.RIGHT:
				hover_region.width = (background_rect.x + background_rect.width - hover_region.x).abs ();
				break;
			}
			
			if (!hover_region.intersect (background_rect, out rect))
				return {};
			
			return rect;
		}
		
		/**
		 * The cursor region for interacting with a dock element.
		 *
		 * @param val the item's DockItemDrawValue
		 * @return the region for the dock item
		 */
		Gdk.Rectangle get_item_hover_region (DockItemDrawValue val)
		{
			Gdk.Rectangle rect;
			
			var item_padding = ItemPadding;
			var top_padding = (top_offset < 0 ? 0 : top_offset);
			var bottom_padding = bottom_offset;
			var width = val.icon_size, height = val.icon_size;
			
			// Apply scalable padding
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				width += item_padding;
				break;
			case Gtk.PositionType.TOP:
				width += item_padding;
				break;
			case Gtk.PositionType.LEFT:
				height += item_padding;
				break;
			case Gtk.PositionType.RIGHT:
				height += item_padding;
				break;
			}
			
			rect = { (int) Math.round (val.center.x - width / 2.0),
				(int) Math.round (val.center.y - height / 2.0),
				(int) width,
				(int) height };
			
			// Apply static padding
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				rect.y -= top_padding;
				rect.height += bottom_padding + top_padding;
				break;
			case Gtk.PositionType.TOP:
				rect.y -= bottom_padding;
				rect.height += bottom_padding + top_padding;
				break;
			case Gtk.PositionType.LEFT:
				rect.x -= bottom_padding;
				rect.width += bottom_padding + top_padding;
				break;
			case Gtk.PositionType.RIGHT:
				rect.x -= top_padding;
				rect.width += bottom_padding + top_padding;
				break;
			}
			
			Gdk.Rectangle background_region;
			
			if (rect.intersect (get_background_region (), out background_region))
				background_region.union (get_item_draw_region (val), out rect);

			// Keep the visual spacing while extending each item's invisible hit target
			// to the screen-facing edge. This lets the user acquire an icon directly
			// from the edge without first moving into the painted background.
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				rect.height = int.max (rect.height, DockHeight - rect.y);
				break;
			case Gtk.PositionType.TOP:
				var bottom = rect.y + rect.height;
				rect.y = 0;
				rect.height = bottom;
				break;
			case Gtk.PositionType.LEFT:
				var right = rect.x + rect.width;
				rect.x = 0;
				rect.width = right;
				break;
			case Gtk.PositionType.RIGHT:
				rect.width = int.max (rect.width, DockWidth - rect.x);
				break;
			}
			
			return rect;
		}
		
		/**
		 * The cursor region for interacting with a dock element.
		 *
		 * @param element the dock element to find a region for
		 * @return the region for the dock item
		 */
		public Gdk.Rectangle get_hover_region_for_element (DockElement element)
		{
			unowned DockItem? item = (element as DockItem);
			if (item != null)
				return get_draw_value_for_item (item).hover_region;
			
			unowned DockContainer? container = (element as DockContainer);
			if (container == null)
				return {};
			
			unowned Gee.ArrayList<DockElement> items = container.VisibleElements;
			
			if (items.size == 0)
				return {};
			
			var first_rect = get_hover_region_for_element (items.first ());
			if (items.size == 1)
				return first_rect;
			
			var last_rect = get_hover_region_for_element (items.last ());
			
			Gdk.Rectangle result;
			first_rect.union (last_rect, out result);
			return result;
		}
		
		/**
		 * Get the item which is the nearest at the given coordinates. If a container is given
		 * the result will be restricted to its children.
		 *
		 * @param x the x position
		 * @param y the y position
		 * @param container a container or NULL 
		 */
		public unowned DockItem? get_nearest_item_at (int x, int y, DockContainer? container = null)
		{
			unowned DockItem? result = null;
			var square_distance = double.MAX;
			
			var draw_values_it = draw_values.map_iterator ();
			while (draw_values_it.next ()) {
				var val = draw_values_it.get_value ();
				var center = val.static_center;
				var new_square_distance = (x - center.x) * (x - center.x) + (y - center.y) * (y - center.y);
				if (square_distance > new_square_distance) {
					DockItem? item = (draw_values_it.get_key () as DockItem);
					if (item == null)
						continue;
					if (container == null || item.Container == container) {
						square_distance = new_square_distance;
						result = item;
					}				
				}				
			}
			
			return result;
		}
		
		/**
		 * Get the item which is the appropriate target for a drag'n'drop action.
		 * The returned item may not hovered and is meant to be used as target
		 * for e.g. DockContainer.add/move_to functions.
		 * If a container is given the result will be restricted to its children.
		 *
		 * @param container a container or NULL 
		 */
		public unowned DockItem? get_current_target_item (DockContainer? container = null)
		{
			var cursor = controller.renderer.local_cursor;
			var offset = ItemPadding / 2;
			
			return get_nearest_item_at (cursor.x + offset, cursor.y + offset, container);
		}
		
		/**
		 * Get's the x and y position to display a menu for a dock item.
		 *
		 * @param hovered the item that is hovered
		 * @param requisition the menu's requisition
		 * @param x the resulting x position
		 * @param y the resulting y position
		 */
		public void get_menu_position (DockItem hovered, Gtk.Requisition requisition, out int x, out int y)
		{
			var rect = get_hover_region_for_element (hovered);
			
			var offset = 10;
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				x = win_x + rect.x + (rect.width - requisition.width) / 2;
				y = win_y + rect.y - requisition.height - offset;
				break;
			case Gtk.PositionType.TOP:
				x = win_x + rect.x + (rect.width - requisition.width) / 2;
				y = win_y + rect.height + offset;
				break;
			case Gtk.PositionType.LEFT:
				y = win_y + rect.y + (rect.height - requisition.height) / 2;
				x = win_x + rect.x + rect.width + offset;
				break;
			case Gtk.PositionType.RIGHT:
				y = win_y + rect.y + (rect.height - requisition.height) / 2;
				x = win_x + rect.x - requisition.width - offset;
				break;
			}
		}
		
		/**
		 * Get's the x and y position to display a hover window for a dock item.
		 *
		 * @param hovered the item that is hovered
		 * @param x the resulting x position
		 * @param y the resulting y position
		 */
		public void get_hover_position (DockItem hovered, out int x, out int y)
		{
			var center = get_draw_value_for_item (hovered).static_center;
			var offset = (ZoomIconSize - IconSize / 2.0);
			
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				x = (int) Math.round (center.x + win_x);
				y = (int) Math.round (center.y + win_y - offset);
				break;
			case Gtk.PositionType.TOP:
				x = (int) Math.round (center.x + win_x);
				y = (int) Math.round (center.y + win_y + offset);
				break;
			case Gtk.PositionType.LEFT:
				x = (int) Math.round (center.x + win_x + offset);
				y = (int) Math.round (center.y + win_y);
				break;
			case Gtk.PositionType.RIGHT:
				x = (int) Math.round (center.x + win_x - offset);
				y = (int) Math.round (center.y + win_y);
				break;
			}
		}
		
		/**
		 * Get's the x and y position to display a hover window for the given coordinates.
		 *
		 * @param x the resulting x position
		 * @param y the resulting y position
		 */
		public void get_hover_position_at (ref int x, ref int y)
		{
			// Any element will suffice since only the constant coordinate of center is used
			var center = get_draw_value_for_item (controller.VisibleItems.first ()).static_center;
			var offset = (ZoomIconSize - IconSize / 2.0);
			
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				y = (int) Math.round (center.y + win_y - offset);
				break;
			case Gtk.PositionType.TOP:
				y = (int) Math.round (center.y + win_y + offset);
				break;
			case Gtk.PositionType.LEFT:
				x = (int) Math.round (center.x + win_x + offset);
				break;
			case Gtk.PositionType.RIGHT:
				x = (int) Math.round (center.x + win_x - offset);
				break;
			}
		}
		
		/**
		 * Get's the x and y position to display the urgent-glow for a dock item.
		 *
		 * @param item the item to show urgent-glow for
		 * @param x the resulting x position
		 * @param y the resulting y position
		 */
		public void get_urgent_glow_position (DockItem item, out int x, out int y)
		{
			var rect = get_hover_region_for_element (item);
			var glow_size = GlowSize;
			
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				x = rect.x + (rect.width - glow_size) / 2;
				y = DockHeight - glow_size / 2;
				break;
			case Gtk.PositionType.TOP:
				x = rect.x + (rect.width - glow_size) / 2;
				y = - glow_size / 2;
				break;
			case Gtk.PositionType.LEFT:
				y = rect.y + (rect.height - glow_size) / 2;
				x = - glow_size / 2;
				break;
			case Gtk.PositionType.RIGHT:
				y = rect.y + (rect.height - glow_size) / 2;
				x = DockWidth - glow_size / 2;
				break;
			}
		}

		/**
		 * Caches the x and y position of the dock window.
		 */
		public void update_dock_position ()
		{
			var xoffset = 0;
			var yoffset = 0;
			
			if (!screen_is_composited) {
				var offset = Offset;
				xoffset = (int) ((1 + offset / 100.0) * (monitor_geo.width - DockWidth) / 2);
				yoffset = (int) ((1 + offset / 100.0) * (monitor_geo.height - DockHeight) / 2);
				
				switch (Alignment) {
				default:
				case Gtk.Align.CENTER:
				case Gtk.Align.FILL:
					break;
				case Gtk.Align.START:
					if (is_horizontal_dock ()) {
						xoffset = 0;
						yoffset = (monitor_geo.height - static_dock_region.height);
					} else {
						xoffset = (monitor_geo.width - static_dock_region.width);
						yoffset = 0;
					}
					break;
				case Gtk.Align.END:
					if (is_horizontal_dock ()) {
						xoffset = (monitor_geo.width - static_dock_region.width);
						yoffset = 0;
					} else {
						xoffset = 0;
						yoffset = (monitor_geo.height - static_dock_region.height);
					}
					break;
				}
			}
			
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				win_x = monitor_geo.x + xoffset;
				win_y = monitor_geo.y + monitor_geo.height - DockHeight;
				break;
			case Gtk.PositionType.TOP:
				win_x = monitor_geo.x + xoffset;
				win_y = monitor_geo.y;
				break;
			case Gtk.PositionType.LEFT:
				win_y = monitor_geo.y + yoffset;
				win_x = monitor_geo.x;
				break;
			case Gtk.PositionType.RIGHT:
				win_y = monitor_geo.y + yoffset;
				win_x = monitor_geo.x + monitor_geo.width - DockWidth;
				break;
			}
			
			// Actually change the window position while hidden for non-compositing mode
			if (!screen_is_composited && controller.hide_manager.Hidden) {
				switch (Position) {
				default:
				case Gtk.PositionType.BOTTOM:
					win_y += DockHeight - 1;
					break;
				case Gtk.PositionType.TOP:
					win_y -= DockHeight - 1;
					break;
				case Gtk.PositionType.LEFT:
					win_x -= DockWidth - 1;
					break;
				case Gtk.PositionType.RIGHT:
					win_x += DockWidth - 1;
					break;
				}
			}
		}
		
		/**
		 * Get's the x and y position to display the main dock buffer.
		 *
		 * @param x the resulting x position
		 * @param y the resulting y position
		 */
		public void get_dock_draw_position (out int x, out int y)
		{
			get_dock_draw_position_for_progress (controller.renderer.hide_progress, out x, out y);
		}

		public void get_dock_draw_position_for_progress (double progress, out int x, out int y)
		{
			if (!screen_is_composited) {
				x = 0;
				y = 0;
				return;
			}
			
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				x = 0;
				y = (int) ((VisibleDockHeight + extra_hide_offset + DockMargin) * progress);
				break;
			case Gtk.PositionType.TOP:
				x = 0;
				y = (int) (- (VisibleDockHeight + extra_hide_offset + DockMargin) * progress);
				break;
			case Gtk.PositionType.LEFT:
				x = (int) (- (VisibleDockWidth + extra_hide_offset + DockMargin) * progress);
				y = 0;
				break;
			case Gtk.PositionType.RIGHT:
				x = (int) ((VisibleDockWidth + extra_hide_offset + DockMargin) * progress);
				y = 0;
				break;
			}
		}
		
		/**
		 * Get's the region to display the dock window at.
		 *
		 * @return the region for the dock window
		 */
		public Gdk.Rectangle get_dock_window_region ()
		{
			return { win_x, win_y, DockWidth, DockHeight };
		}

		public Gdk.Rectangle get_screen_background_region ()
		{
			return { win_x + background_rect.x, win_y + background_rect.y,
				background_rect.width, background_rect.height };
		}

		public Gdk.Rectangle get_screen_region_for_item (DockItem item)
		{
			var rect = get_draw_value_for_item (item).draw_region;
			rect.x += win_x;
			rect.y += win_y;
			return rect;
		}
		
		/**
		 * Get's the padding between background and icons of the dock.
		 *
		 * @param x the horizontal padding
		 * @param y the vertical padding
		 */
		public void get_background_padding (out int x, out int y)
		{
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				x = 0;
				y = VisibleDockHeight - DockBackgroundHeight + extra_hide_offset;
				break;
			case Gtk.PositionType.TOP:
				x = 0;
				y = -(VisibleDockHeight - DockBackgroundHeight + extra_hide_offset);
				break;
			case Gtk.PositionType.LEFT:
				x = -(VisibleDockWidth - DockBackgroundWidth + extra_hide_offset);
				y = 0;
				break;
			case Gtk.PositionType.RIGHT:
				x = VisibleDockWidth - DockBackgroundWidth + extra_hide_offset;
				y = 0;
				break;
			}
		}
		
		/**
		 * Get's the region for background of the dock.
		 *
		 * @return the region for the dock background
		 */
		public Gdk.Rectangle get_background_region ()
		{
			return background_rect;
		}

		public Gdk.Rectangle get_primary_background_region ()
		{
			return primary_background_rect;
		}

		public Gdk.Rectangle get_status_background_region ()
		{
			return status_background_rect;
		}

		double axis_position (DockItemDrawValue value, bool use_static = false)
		{
			var point = use_static ? value.static_center : value.center;
			return is_horizontal_dock () ? point.x : point.y;
		}

		int axis_length ()
		{
			return is_horizontal_dock () ? DockWidth : DockHeight;
		}

		public bool pointer_is_over_primary_section (int x, int y)
		{
			return point_in_rectangle (x, y, primary_background_rect);
		}

		public bool pointer_is_over_status_section (int x, int y)
		{
			return point_in_rectangle (x, y, status_background_rect);
		}

		static bool point_in_rectangle (int x, int y, Gdk.Rectangle rectangle)
		{
			return x >= rectangle.x && x < rectangle.x + rectangle.width
				&& y >= rectangle.y && y < rectangle.y + rectangle.height;
		}

		public void get_popup_position (Gdk.Rectangle anchor, int popup_width, int popup_height,
			int gap, Gdk.Rectangle workarea, out int x, out int y)
		{
			var bar = get_screen_background_region ();
			calculate_popup_position (Position, bar, anchor, popup_width, popup_height,
				gap, workarea, out x, out y);
		}

		public static void calculate_popup_position (Gtk.PositionType position, Gdk.Rectangle bar,
			Gdk.Rectangle anchor, int popup_width, int popup_height, int gap,
			Gdk.Rectangle workarea, out int x, out int y)
		{
			switch (position) {
			default:
			case Gtk.PositionType.BOTTOM:
				x = anchor.x + anchor.width / 2 - popup_width / 2;
				y = bar.y - popup_height - gap;
				break;
			case Gtk.PositionType.TOP:
				x = anchor.x + anchor.width / 2 - popup_width / 2;
				y = bar.y + bar.height + gap;
				break;
			case Gtk.PositionType.LEFT:
				x = bar.x + bar.width + gap;
				y = anchor.y + anchor.height / 2 - popup_height / 2;
				break;
			case Gtk.PositionType.RIGHT:
				x = bar.x - popup_width - gap;
				y = anchor.y + anchor.height / 2 - popup_height / 2;
				break;
			}

			x = x.clamp (workarea.x + 8,
				int.max (workarea.x + 8, workarea.x + workarea.width - popup_width - 8));
			y = y.clamp (workarea.y + 8,
				int.max (workarea.y + 8, workarea.y + workarea.height - popup_height - 8));
		}

		public void get_popup_slide_offset (int amount, out int x, out int y)
		{
			x = 0;
			y = 0;
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM: y = amount; break;
			case Gtk.PositionType.TOP: y = -amount; break;
			case Gtk.PositionType.LEFT: x = -amount; break;
			case Gtk.PositionType.RIGHT: x = amount; break;
			}
		}
		
		void update_background_region (DockItemDrawValue val_first, DockItemDrawValue val_last)
		{
			var x = 0, y = 0, width = 0, height = 0;
			
			if (screen_is_composited) {
				x = static_dock_region.x;
				y = static_dock_region.y;
				width = VisibleDockWidth;
				height = VisibleDockHeight;
			} else {
				width = DockWidth;
				height = DockHeight;
			}
			
			if (Alignment == Gtk.Align.FILL) {
				switch (Position) {
				default:
				case Gtk.PositionType.BOTTOM:
					x += (width - DockBackgroundWidth) / 2;
					y += height - DockBackgroundHeight;
					break;
				case Gtk.PositionType.TOP:
					x += (width - DockBackgroundWidth) / 2;
					break;
				case Gtk.PositionType.LEFT:
					y += (height - DockBackgroundHeight) / 2;
					break;
				case Gtk.PositionType.RIGHT:
					x += width - DockBackgroundWidth;
					y += (height - DockBackgroundHeight) / 2;
					break;
				}
				
				background_rect = { x, y, DockBackgroundWidth, DockBackgroundHeight };
				return;
			}
			
			var center_first = val_first.center;
			var center_last = val_last.center;
			var padding = ItemPadding + 2 * HorizPadding + 4 * LineWidth;
			var padding_first = (val_first.icon_size + padding) / 2.0;
			var padding_last = (val_last.icon_size + padding) / 2.0;
			
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				x = (int) Math.round (center_first.x - padding_first);
				y += height - DockBackgroundHeight;
				width = (int) Math.round (center_last.x - center_first.x + padding_first + padding_last);
				height = DockBackgroundHeight;
				break;
			case Gtk.PositionType.TOP:
				x = (int) Math.round (center_first.x - padding_first);
				width = (int) Math.round (center_last.x - center_first.x + padding_first + padding_last);
				height = DockBackgroundHeight;
				break;
			case Gtk.PositionType.LEFT:
				y = (int) Math.round (center_first.y - padding_first);
				width = DockBackgroundWidth;
				height = (int) Math.round (center_last.y - center_first.y + padding_first + padding_last);
				break;
			case Gtk.PositionType.RIGHT:
				x += width - DockBackgroundWidth;
				y = (int) Math.round (center_first.y - padding_first);
				width = DockBackgroundWidth;
				height = (int) Math.round (center_last.y - center_first.y + padding_first + padding_last);
				break;
			}
			
			background_rect = { x, y, width, height };
		}
		
		/**
		 * Get the item's icon geometry for the dock.
		 *
		 * @param item an application-dockitem of the dock
		 * @param for_hidden whether the geometry should apply for a hidden dock
		 * @return icon geometry for the given application-dockitem
		 */
		public Gdk.Rectangle get_icon_geometry (ApplicationDockItem item, bool for_hidden)
		{
			var region = get_hover_region_for_element (item);
			
			if (!for_hidden) {
				region.x += win_x;
				region.y += win_y;
				
				return region;
			}
			
			var x = win_x, y = win_y;
			
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				x += region.x + region.width / 2;
				y += DockHeight;
				break;
			case Gtk.PositionType.TOP:
				x += region.x + region.width / 2;
				y += 0;
				break;
			case Gtk.PositionType.LEFT:
				x += 0;
				y += region.y + region.height / 2;
				break;
			case Gtk.PositionType.RIGHT:
				x += DockWidth;
				y += region.y + region.height / 2;
				break;
			}
			
			return { x, y, 0, 0 };
		}
		
		/**
		 * Computes the struts for the dock.
		 *
		 * @param struts the array to contain the struts
		 */
		public void get_struts (ref ulong[] struts)
		{
			window_scale_factor = controller.window.get_window ().get_scale_factor ();
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				struts [Struts.BOTTOM] = (VisibleDockHeight + controller.window.get_screen ().get_height () - monitor_geo.y - monitor_geo.height) * window_scale_factor;
				struts [Struts.BOTTOM_START] = monitor_geo.x * window_scale_factor;
				struts [Struts.BOTTOM_END] = (monitor_geo.x + monitor_geo.width) * window_scale_factor - 1;
				break;
			case Gtk.PositionType.TOP:
				struts [Struts.TOP] = (monitor_geo.y + VisibleDockHeight) * window_scale_factor;
				struts [Struts.TOP_START] = monitor_geo.x * window_scale_factor;
				struts [Struts.TOP_END] = (monitor_geo.x + monitor_geo.width) * window_scale_factor - 1;
				break;
			case Gtk.PositionType.LEFT:
				struts [Struts.LEFT] = (monitor_geo.x + VisibleDockWidth) * window_scale_factor;
				struts [Struts.LEFT_START] = monitor_geo.y * window_scale_factor;
				struts [Struts.LEFT_END] = (monitor_geo.y + monitor_geo.height) * window_scale_factor - 1;
				break;
			case Gtk.PositionType.RIGHT:
				struts [Struts.RIGHT] = (VisibleDockWidth + controller.window.get_screen ().get_width () - monitor_geo.x - monitor_geo.width) * window_scale_factor;
				struts [Struts.RIGHT_START] = monitor_geo.y * window_scale_factor;
				struts [Struts.RIGHT_END] = (monitor_geo.y + monitor_geo.height) * window_scale_factor - 1;
				break;
			}
		}
		
#if HAVE_BARRIERS
		public Gdk.Rectangle get_barrier ()
		{
			Gdk.Rectangle barrier = {};
			
			switch (Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				barrier.x = monitor_geo.x + (monitor_geo.width - VisibleDockWidth) / 2;
				barrier.y = monitor_geo.y + monitor_geo.height;
				barrier.width = VisibleDockWidth;
				barrier.height = 0;
				break;
			case Gtk.PositionType.TOP:
				barrier.x = monitor_geo.x + (monitor_geo.width - VisibleDockWidth) / 2;
				barrier.y = monitor_geo.y;
				barrier.width = VisibleDockWidth;
				barrier.height = 0;
				break;
			case Gtk.PositionType.LEFT:
				barrier.x = monitor_geo.x;
				barrier.y = monitor_geo.y + (monitor_geo.height - VisibleDockHeight) / 2;
				barrier.width = 0;
				barrier.height = VisibleDockHeight;
				break;
			case Gtk.PositionType.RIGHT:
				barrier.x = monitor_geo.x + monitor_geo.width;
				barrier.y = monitor_geo.y + (monitor_geo.height - VisibleDockHeight) / 2;
				barrier.width = 0;
				barrier.height = VisibleDockHeight;
				break;
			}
			
			warn_if_fail (barrier.width > 0 || barrier.height > 0);
			
			return barrier;
		}
#endif
	}
}
