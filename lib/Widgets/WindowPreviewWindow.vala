// Native window previews for running applications on X11.

namespace Plank
{
	public class WindowPreviewWindow : Gtk.Window
	{
		const int OPEN_DELAY = 240;
		// Enough time to cross the physical gap between the dock and this
		// separate X11 window without dropping the shared hover state.
		const int CLOSE_DELAY = 520;
		const int CARD_WIDTH = 220;
		const int PREVIEW_HEIGHT = 125;
		const int GAP = 10;

		unowned DockController controller;
		ApplicationDockItem? current_item;
		Gtk.FlowBox flow;
		uint open_timer = 0U;
		uint close_timer = 0U;
		uint refresh_timer = 0U;
		ulong previews_enabled_changed_id = 0UL;
		bool pointer_inside = false;
		Gtk.CssProvider css_provider;

		public WindowPreviewWindow (DockController controller)
		{
			Object (type: Gtk.WindowType.TOPLEVEL);
			this.controller = controller;
			decorated = false;
			resizable = false;
			skip_taskbar_hint = true;
			skip_pager_hint = true;
			set_keep_above (true);
			// Treat previews as an owned popup, not as an application window.
			// Otherwise BAMF exposes it as a second running "Plank" item.
			type_hint = Gdk.WindowTypeHint.POPUP_MENU;
			set_transient_for (controller.window);
			destroy_with_parent = true;
			app_paintable = true;
			get_style_context ().add_class ("plank-window-previews");
			Accessibility.describe (this, _("Window previews"));
			var visual = get_screen ().get_rgba_visual ();
			if (visual != null)
				set_visual (visual);

			flow = new Gtk.FlowBox ();
			Accessibility.describe (flow, _("Open windows"));
			flow.selection_mode = Gtk.SelectionMode.NONE;
			flow.row_spacing = 8;
			flow.column_spacing = 8;
			flow.homogeneous = true;
			flow.margin = 10;
			add (flow);

			add_events (Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK);
			enter_notify_event.connect (() => {
				pointer_inside = true;
				cancel_close ();
				return false;
			});
			leave_notify_event.connect ((event) => {
				pointer_inside = false;
				int wx, wy, ww, wh;
				get_position (out wx, out wy);
				get_size (out ww, out wh);
				if (exit_is_toward_dock (event, wx, wy, ww, wh))
					schedule_close ();
				else
					dismiss ();
				return false;
			});
			key_press_event.connect ((event) => {
				Accessibility.set_keyboard_navigation (this, true);
				if (event.keyval == Gdk.Key.Escape) {
					dismiss ();
					return true;
				}
				return false;
			});
			button_press_event.connect (() => {
				Accessibility.set_keyboard_navigation (this, false);
				return false;
			});
			previews_enabled_changed_id = controller.prefs.notify["WindowPreviewsEnabled"].connect (() => {
				if (!controller.prefs.WindowPreviewsEnabled)
					dismiss ();
			});
			show.connect (() => {
				controller.hide_manager.ExternalMenuVisible = true;
				controller.hide_manager.update_hovered ();
			});
			hide.connect (() => {
				controller.hide_manager.ExternalMenuVisible = false;
				controller.hide_manager.update_hovered ();
			});
			apply_theme ();
		}

		~WindowPreviewWindow ()
		{
			cancel_open ();
			cancel_close ();
			stop_refresh ();
			if (previews_enabled_changed_id > 0UL)
				SignalHandler.disconnect (controller.prefs, previews_enabled_changed_id);
			Gtk.StyleContext.remove_provider_for_screen (get_screen (), css_provider);
		}

		public void handle_dock_hover (DockItem? item)
		{
			if (!controller.prefs.WindowPreviewsEnabled) {
				dismiss ();
				return;
			}
			var app_item = item as ApplicationDockItem;
			if (app_item != null && app_item.is_running () && app_item.App != null
				&& app_item.App.get_windows ().length () > 0) {
				cancel_close ();
				if (visible && current_item == app_item)
					return;
				// Moving horizontally onto another dock icon is intentional: close
				// the old preview immediately, then apply the normal delay to the new
				// application. A vertical move toward the preview reports null instead
				// and continues to use the hover bridge below.
				if (visible && current_item != app_item)
					dismiss ();
				schedule_open (app_item);
			} else {
				cancel_open ();
				if (visible && item != null) {
					// Another concrete item means movement along the dock's main axis.
					dismiss ();
				} else if (visible && !pointer_inside) {
					// Null is the gap between the dock and the native preview window.
					schedule_close ();
				}
			}
		}

		public void handle_dock_motion (double root_x, double root_y)
		{
			if (!visible || current_item == null || pointer_inside)
				return;
			// Item hit targets intentionally grow for easier acquisition. Preview
			// ownership instead follows the real painted icon along the dock axis.
			var anchor = controller.position_manager.get_screen_region_for_item (current_item);
			var inside_anchor_axis = controller.position_manager.is_horizontal_dock ()
				? root_x >= anchor.x && root_x < anchor.x + anchor.width
				: root_y >= anchor.y && root_y < anchor.y + anchor.height;
			if (!inside_anchor_axis)
				dismiss ();
		}

		bool exit_is_toward_dock (Gdk.EventCrossing event, int x, int y, int width, int height)
		{
			switch (controller.position_manager.Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				return event.x_root >= x && event.x_root < x + width
					&& event.y_root >= y + height;
			case Gtk.PositionType.TOP:
				return event.x_root >= x && event.x_root < x + width
					&& event.y_root < y;
			case Gtk.PositionType.LEFT:
				return event.y_root >= y && event.y_root < y + height
					&& event.x_root < x;
			case Gtk.PositionType.RIGHT:
				return event.y_root >= y && event.y_root < y + height
					&& event.x_root >= x + width;
			}
		}

		void schedule_open (ApplicationDockItem item)
		{
			cancel_open ();
			current_item = item;
			open_timer = Timeout.add (OPEN_DELAY, () => {
				open_timer = 0U;
				if (current_item == item)
					show_for_item (item);
				return false;
			});
		}

		void show_for_item (ApplicationDockItem item)
		{
			if (!controller.prefs.WindowPreviewsEnabled) {
				dismiss ();
				return;
			}
			Accessibility.set_keyboard_navigation (this, false);
			current_item = item;
			rebuild ();
			if (flow.get_children ().length () == 0) {
				dismiss ();
				return;
			}
			opacity = 0.0;
			show_all ();
			position_over_item ();
			opacity = 1.0;
			start_refresh ();
		}

		void rebuild ()
		{
			foreach (unowned Gtk.Widget child in flow.get_children ())
				flow.remove (child);
			if (current_item == null || current_item.App == null)
				return;
			var count = 0;
			foreach (var view in current_item.App.get_windows ()) {
				unowned Bamf.Window? window = view as Bamf.Window;
				if (window == null || window.get_transient () != null)
					continue;
				flow.add (create_card (window));
				count++;
			}
			flow.max_children_per_line = count <= 3 ? int.max (1, count) : 3;
			flow.min_children_per_line = count <= 3 ? int.max (1, count) : int.min (3, count);
		}

		Gtk.Widget create_card (Bamf.Window window)
		{
			var event_box = new Gtk.EventBox ();
			event_box.can_focus = true;
			Accessibility.describe (event_box, _("Activate %s").printf (window.get_name ()),
				_("Window preview"));
			Accessibility.set_role (event_box, Atk.Role.PUSH_BUTTON);
			event_box.visible_window = true;
			event_box.get_style_context ().add_class ("preview-card");
			event_box.set_size_request (CARD_WIDTH, PREVIEW_HEIGHT + 38);
			var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 5);
			box.margin = 5;
			var image = new Gtk.Image ();
			image.set_size_request (CARD_WIDTH - 10, PREVIEW_HEIGHT);
			image.set_data<uint32> ("preview-xid", window.get_xid ());
			update_image (image, window.get_xid ());
			box.pack_start (image, true, true, 0);

			var footer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 5);
			var title = new Gtk.Label (window.get_name ()) { xalign = 0.0f };
			title.ellipsize = Pango.EllipsizeMode.END;
			title.width_chars = 18;
			title.max_width_chars = 18;
			title.set_size_request (CARD_WIDTH - 48, -1);
			title.get_style_context ().add_class ("preview-title");
			footer.pack_start (title, true, true, 0);
			var close = new Gtk.Button.from_icon_name ("window-close-symbolic", Gtk.IconSize.MENU);
			close.relief = Gtk.ReliefStyle.NONE;
			close.tooltip_text = _("Close window");
			Accessibility.describe (close, _("Close %s").printf (window.get_name ()));
			close.get_style_context ().add_class ("preview-close");
			close.clicked.connect (() => {
				unowned Wnck.Window? wnck = Wnck.Window.@get (window.get_xid ());
				if (wnck != null)
					wnck.close (Gtk.get_current_event_time ());
			});
			footer.pack_end (close, false, false, 0);
			box.pack_end (footer, false, false, 0);
			event_box.add (box);
			event_box.button_release_event.connect ((event) => {
				if (event.button == 1U) {
					activate_preview (window, event.time);
					return true;
				}
				if (event.button == 2U) {
					unowned Wnck.Window? wnck = Wnck.Window.@get (window.get_xid ());
					if (wnck != null)
						wnck.close (event.time);
					return true;
				}
				return false;
			});
			event_box.key_press_event.connect ((event) => {
				if (event.keyval == Gdk.Key.Return || event.keyval == Gdk.Key.KP_Enter
					|| event.keyval == Gdk.Key.space) {
					activate_preview (window, event.time);
					return true;
				}
				return false;
			});
			return event_box;
		}

		void activate_preview (Bamf.Window window, uint32 event_time)
		{
			WindowControl.focus_window (window, event_time);
			dismiss ();
		}

		void update_image (Gtk.Image image, uint32 xid)
		{
			unowned Wnck.Window? wnck = Wnck.Window.@get (xid);
			if (wnck == null)
				return;
			Gdk.error_trap_push ();
			var foreign = new Gdk.X11.Window.foreign_for_display (
				(Gdk.X11.Display) get_display (), (X.Window) xid);
			Gdk.Pixbuf? pixbuf = null;
			if (foreign != null) {
				int x, y, width, height;
				wnck.get_geometry (out x, out y, out width, out height);
				if (width > 1 && height > 1)
					pixbuf = Gdk.pixbuf_get_from_window (foreign, 0, 0, width, height);
			}
			Gdk.error_trap_pop_ignored ();
			if (pixbuf != null) {
				var scaled = DrawingService.ar_scale (pixbuf, CARD_WIDTH - 10, PREVIEW_HEIGHT);
				image.set_from_pixbuf (scaled);
			} else {
				unowned Gdk.Pixbuf? fallback = wnck.get_icon ();
				if (fallback != null)
					image.set_from_pixbuf (DrawingService.ar_scale (fallback, 64, 64));
				else
					image.set_from_icon_name ("application-x-executable-symbolic", Gtk.IconSize.DIALOG);
			}
		}

		void refresh_images ()
		{
			foreach (unowned Gtk.Widget row in flow.get_children ()) {
				var child = (row as Gtk.FlowBoxChild)?.get_child () as Gtk.EventBox;
				var box = child?.get_child () as Gtk.Box;
				if (box == null)
					continue;
				foreach (unowned Gtk.Widget widget in box.get_children ()) {
					var image = widget as Gtk.Image;
					if (image != null) {
						update_image (image, image.get_data<uint32> ("preview-xid"));
						break;
					}
				}
			}
		}

		void start_refresh ()
		{
			stop_refresh ();
			refresh_timer = Timeout.add (500, () => {
				if (!visible) { refresh_timer = 0U; return false; }
				refresh_images ();
				return true;
			});
		}

		void stop_refresh ()
		{
			if (refresh_timer > 0U) { Source.remove (refresh_timer); refresh_timer = 0U; }
		}

		void schedule_close ()
		{
			cancel_close ();
			close_timer = Timeout.add (CLOSE_DELAY, () => {
				close_timer = 0U;
				// The dock and preview are separate native windows. Re-check the
				// actual pointer position after the bridge delay instead of trusting
				// the leave event emitted while crossing the gap.
				int pointer_x, pointer_y;
				get_display ().get_device_manager ().get_client_pointer ().get_position (
					null, out pointer_x, out pointer_y);
				int window_x, window_y, window_width, window_height;
				get_position (out window_x, out window_y);
				get_size (out window_width, out window_height);
				var over_preview = pointer_x >= window_x && pointer_x < window_x + window_width
					&& pointer_y >= window_y && pointer_y < window_y + window_height;
				var dock = controller.position_manager.get_screen_background_region ();
				var over_dock = pointer_x >= dock.x && pointer_x < dock.x + dock.width
					&& pointer_y >= dock.y && pointer_y < dock.y + dock.height;
				if (!pointer_inside && !over_preview && !over_dock)
					dismiss ();
				return false;
			});
		}

		void cancel_open () { if (open_timer > 0U) { Source.remove (open_timer); open_timer = 0U; } }
		void cancel_close () { if (close_timer > 0U) { Source.remove (close_timer); close_timer = 0U; } }

		public void dismiss ()
		{
			cancel_open ();
			stop_refresh ();
			current_item = null;
			if (visible)
				hide ();
		}

		void position_over_item ()
		{
			if (current_item == null)
				return;
			var anchor = controller.position_manager.get_screen_region_for_item (current_item);
			int width, height;
			get_size (out width, out height);
			var screen = get_screen ();
			var monitor = screen.get_monitor_at_point (anchor.x, anchor.y);
			var workarea = screen.get_monitor_workarea (monitor);
			int x, y;
			controller.position_manager.get_popup_position (anchor, width, height,
				GAP, workarea, out x, out y);
			move (x, y);
		}

		void apply_theme ()
		{
			var color = controller.renderer.theme.FillStartColor;
			var red = (int) (color.red * 255);
			var green = (int) (color.green * 255);
			var blue = (int) (color.blue * 255);
			var card_red = int.min (255, red + 12);
			var card_green = int.min (255, green + 12);
			var card_blue = int.min (255, blue + 12);
			var hover_red = int.min (255, red + 24);
			var hover_green = int.min (255, green + 24);
			var hover_blue = int.min (255, blue + 24);
			var css = ".plank-window-previews { background: rgb(%d,%d,%d); border-radius: 14px; }"
				.printf (red, green, blue);
			css += ".plank-window-previews .preview-card { background: rgb(%d,%d,%d); border-radius: 10px; }"
				.printf (card_red, card_green, card_blue);
			css += ".plank-window-previews .preview-card:hover { background: rgb(%d,%d,%d); }"
				.printf (hover_red, hover_green, hover_blue);
			css += ".plank-window-previews.keyboard-navigation .preview-card:focus { box-shadow: inset 0 0 0 2px rgba(115,210,22,0.85); }";
			css += ".plank-window-previews .preview-title { color: white; font-weight: 500; }";
			css += ".plank-window-previews .preview-close { color: white; border-radius: 8px; padding: 3px; background: transparent; }";
			css += ".plank-window-previews .preview-close:hover { background: rgb(210,65,65); }";
			css_provider = new Gtk.CssProvider ();
			try {
				css_provider.load_from_data (css);
				Gtk.StyleContext.add_provider_for_screen (get_screen (), css_provider,
					Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
			} catch (Error e) {
				warning ("Unable to style previews: %s", e.message);
			}
		}
	}
}
