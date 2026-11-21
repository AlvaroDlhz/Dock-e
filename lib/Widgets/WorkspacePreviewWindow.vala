// Native overview of the workspaces.

namespace Plank
{
	public class WorkspacePreviewWindow : Gtk.Window
	{
		const int CARD_WIDTH = 230;
		const int PREVIEW_HEIGHT = 128;
		const int GAP = 10;

		unowned DockController controller;
		WindowTransition transition;
		WorkspaceItem? current_item;
		Gtk.FlowBox flow;
		Platform.WorkspaceManager? workspaces;
		Platform.ToplevelManager? toplevels;
		// The workspaces as of the last rebuild
		Gee.List<Platform.Workspace> shown_workspaces = new Gee.ArrayList<Platform.Workspace> ();
		// Pictures of the windows, taken again only once a window has changed
		Platform.WindowThumbnailer? thumbnails;
		ulong thumbnail_changed_id = 0UL;

		public WorkspacePreviewWindow (DockController controller)
		{
			Object (type: Gtk.WindowType.TOPLEVEL);
			this.controller = controller;
			transition = new WindowTransition (this);
			transition.finished.connect ((hidden) => {
				if (!hidden)
					return;
				// Release the composited X11 surface instead of keeping a hidden
				// translucent buffer that XFCE can leave visible as a ghost.
				Idle.add (() => {
					if (!visible)
						unrealize ();
					return false;
				});
			});
			unowned Platform.Backend? backend = Platform.get_backend ();
			if (backend != null) {
				workspaces = backend.workspaces;
				toplevels = backend.toplevels;
				thumbnails = backend.create_thumbnailer (CARD_WIDTH - 10, PREVIEW_HEIGHT);
			}
			if (thumbnails != null)
				thumbnail_changed_id = thumbnails.changed.connect (() => redraw_previews ());
			decorated = false;
			resizable = false;
			skip_taskbar_hint = true;
			skip_pager_hint = true;
			set_keep_above (true);
			type_hint = Gdk.WindowTypeHint.DIALOG;
			set_transient_for (controller.window);
			destroy_with_parent = true;
			app_paintable = true;
			get_style_context ().add_class ("plank-workspace-previews");
			Accessibility.describe (this, _("Workspace overview"));
			var visual = get_screen ().get_rgba_visual ();
			if (visual != null)
				set_visual (visual);

			flow = new Gtk.FlowBox ();
			flow.selection_mode = Gtk.SelectionMode.NONE;
			flow.row_spacing = 4;
			flow.column_spacing = 4;
			flow.homogeneous = true;
			flow.margin = 10;
			flow.get_style_context ().add_class ("workspace-flow");
			Accessibility.describe (flow, _("Available workspaces"));
			add (flow);

			focus_out_event.connect (() => { dismiss (); return false; });
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
			show.connect (() => {
				controller.hide_manager.ExternalMenuVisible = true;
				controller.hide_manager.update_hovered ();
			});
			hide.connect (() => {
				// Nothing is watched or kept in memory while there is nothing to show
				if (thumbnails != null)
					thumbnails.clear ();
				controller.hide_manager.ExternalMenuVisible = false;
				controller.hide_manager.update_hovered ();
			});
			if (workspaces != null) {
				workspaces.changed.connect (() => { if (visible) rebuild (); });
				workspaces.active_changed.connect (() => { if (visible) rebuild (); });
			}
			if (toplevels != null) {
				// Which windows there are is not something their contents tell
				toplevels.added.connect (() => redraw_previews ());
				toplevels.removed.connect (() => redraw_previews ());
			}
			apply_theme ();
		}

		~WorkspacePreviewWindow ()
		{
			if (thumbnail_changed_id > 0UL)
				SignalHandler.disconnect (thumbnails, thumbnail_changed_id);
		}

		public override bool draw (Cairo.Context cr)
		{
			var width = get_allocated_width ();
			var height = get_allocated_height ();
			cr.save ();
			cr.set_operator (Cairo.Operator.CLEAR);
			cr.paint ();
			cr.restore ();
			unowned Gtk.StyleContext context = get_style_context ();
			context.render_background (cr, 0, 0, width, height);
			context.render_frame (cr, 0, 0, width, height);
			return base.draw (cr);
		}

		public void toggle (WorkspaceItem item)
		{
			if (visible && current_item == item) {
				dismiss ();
				return;
			}
			current_item = item;
			controller.launcher.dismiss ();
			controller.background_apps.dismiss ();
			controller.window_previews.dismiss ();
			rebuild ();
			apply_theme ();
			if (!visible)
				transition.jump_to (0.0);
			show_all ();
			present ();
			Idle.add (() => {
				position_over_item ();
				if (current_item != null)
					transition.animate_to (1.0,
						Motion.duration (controller.prefs, Motion.POPUP_OPEN_TIME), false, true);
				flow.child_focus (Gtk.DirectionType.TAB_FORWARD);
				return false;
			});
		}

		public void dismiss ()
		{
			current_item = null;
			if (visible)
				transition.animate_to (0.0,
					Motion.duration (controller.prefs, Motion.POPUP_CLOSE_TIME), true);
		}

		void rebuild ()
		{
			foreach (unowned Gtk.Widget child in flow.get_children ())
				flow.remove (child);
			if (workspaces == null)
				return;
			shown_workspaces = workspaces.list ();
			var count = shown_workspaces.size;
			for (var number = 0; number < count; number++) {
				var card = create_card (shown_workspaces[number]);
				flow.add (card);
				unowned Gtk.Widget wrapper = card.get_parent ();
				wrapper.margin = 4;
				wrapper.get_style_context ().add_class ("workspace-flow-child");
			}
			flow.max_children_per_line = int.min (3, int.max (1, count));
			flow.min_children_per_line = int.min (3, int.max (1, count));
			flow.show_all ();
			Idle.add (() => { if (visible) position_over_item (); return false; });
		}

		Gtk.Widget create_card (Platform.Workspace workspace)
		{
			var workspace_number = workspace.index;
			var card = new Gtk.EventBox ();
			card.visible_window = true;
			card.can_focus = true;
			card.get_style_context ().add_class ("workspace-card");
			if (workspace.is_active)
				card.get_style_context ().add_class ("active");
			Accessibility.describe (card, _("Switch to %s").printf (workspace.name),
				_("Workspace preview"));
			Accessibility.set_role (card, Atk.Role.PUSH_BUTTON);

			var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
			box.margin = 5;
			var preview = new Gtk.DrawingArea ();
			preview.set_size_request (CARD_WIDTH - 10, PREVIEW_HEIGHT);
			preview.draw.connect ((cr) => {
				draw_workspace (cr, workspace_number, preview.get_allocated_width (),
					preview.get_allocated_height ());
				return true;
			});
			box.pack_start (preview, true, true, 0);

			var footer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
			var title = new Gtk.Label (workspace.name) { xalign = 0.0f };
			title.ellipsize = Pango.EllipsizeMode.END;
			title.get_style_context ().add_class ("workspace-title");
			footer.pack_start (title, true, true, 0);
			if (workspace.is_active) {
				var active = new Gtk.Label (_("Current"));
				active.get_style_context ().add_class ("workspace-active-label");
				footer.pack_end (active, false, false, 0);
			}
			box.pack_end (footer, false, false, 0);
			card.add (box);
			card.button_release_event.connect ((event) => {
				if (event.button == 1U) {
					activate_workspace (workspace_number, event.time);
					return true;
				}
				return false;
			});
			card.key_press_event.connect ((event) => {
				if (event.keyval == Gdk.Key.Return || event.keyval == Gdk.Key.KP_Enter
					|| event.keyval == Gdk.Key.space) {
					activate_workspace (workspace_number, event.time);
					return true;
				}
				return false;
			});
			return card;
		}

		void activate_workspace (int number, uint32 timestamp)
		{
			if (number < shown_workspaces.size)
				shown_workspaces[number].activate (timestamp);
			dismiss ();
		}

		void draw_workspace (Cairo.Context cr, int workspace_number, int width, int height)
		{
			var background = get_bar_color ();
			var background_alpha = get_bar_opacity (background);
			cr.save ();
			// Replace the thumbnail background instead of blending it over the
			// panel.  This keeps its final color and transparency identical to
			// the dock background.
			cr.set_operator (Cairo.Operator.SOURCE);
			cr.set_source_rgba (background.red, background.green, background.blue,
				background_alpha);
			cr.rectangle (0, 0, width, height);
			cr.fill ();
			cr.restore ();
			if (toplevels == null || workspace_number >= shown_workspaces.size)
				return;
			var workspace = shown_workspaces[workspace_number];
			var screen_width = int.max (1, get_screen ().get_width ());
			var screen_height = int.max (1, get_screen ().get_height ());
			var scale_x = (double) width / screen_width;
			var scale_y = (double) height / screen_height;

			foreach (var window in toplevels.list ()) {
				if (window.has_any_state (Platform.ToplevelState.MINIMIZED | Platform.ToplevelState.SKIP_PAGER)
					|| !window.is_on_workspace (workspace))
					continue;
				Gdk.Rectangle geometry;
				if (!window.get_geometry (out geometry))
					continue;
				var x = geometry.x, y = geometry.y;
				var window_width = geometry.width, window_height = geometry.height;
				if (window_width < 2 || window_height < 2)
					continue;
				var px = double.max (1.0, x * scale_x);
				var py = double.max (1.0, y * scale_y);
				var pw = double.min (width - px - 1.0, double.max (12.0, window_width * scale_x));
				var ph = double.min (height - py - 1.0, double.max (9.0, window_height * scale_y));
				if (pw <= 0 || ph <= 0)
					continue;

				Gdk.Pixbuf? pixbuf = capture_window (window);
				cr.save ();
				cr.rectangle (px, py, pw, ph);
				cr.clip ();
				if (pixbuf != null) {
					var scaled = pixbuf.scale_simple ((int) pw, (int) ph, Gdk.InterpType.BILINEAR);
					Gdk.cairo_set_source_pixbuf (cr, scaled, px, py);
					cr.paint ();
				} else {
					cr.set_source_rgb (0.22, 0.25, 0.31);
					cr.paint ();
					var icon = window.get_icon ();
					if (icon != null) {
						var icon_size = (int) double.min (32.0, double.min (pw - 4.0, ph - 4.0));
						if (icon_size > 4) {
							var scaled_icon = icon.scale_simple (icon_size, icon_size, Gdk.InterpType.BILINEAR);
							Gdk.cairo_set_source_pixbuf (cr, scaled_icon,
								px + (pw - icon_size) / 2.0, py + (ph - icon_size) / 2.0);
							cr.paint ();
						}
					}
				}
				cr.restore ();
				cr.set_source_rgba (1.0, 1.0, 1.0, 0.28);
				cr.set_line_width (1.0);
				cr.rectangle (px + 0.5, py + 0.5, pw - 1.0, ph - 1.0);
				cr.stroke ();
			}
		}

		Gdk.Pixbuf? capture_window (Platform.Toplevel window)
		{
			if (thumbnails == null || window.has_any_state (Platform.ToplevelState.MINIMIZED))
				return null;
			return thumbnails.lookup (window);
		}

		void redraw_previews ()
		{
			if (!visible)
				return;
			// Drawing is cheap, the pictures of unchanged windows are reused
			foreach (unowned Gtk.Widget child in flow.get_children ())
				child.queue_draw ();
		}

		void position_over_item ()
		{
			if (current_item == null)
				return;
			var anchor = controller.position_manager.get_screen_region_for_item (current_item);
			int width, height;
			get_size (out width, out height);
			var monitor = get_screen ().get_monitor_at_point (anchor.x, anchor.y);
			var workarea = get_screen ().get_monitor_workarea (monitor);
			int x, y;
			controller.position_manager.get_popup_position (anchor, width, height, GAP,
				workarea, out x, out y);
			move (x, y);
		}

		void apply_theme ()
		{
			DockStyle.update (controller);
		}

		Gdk.RGBA get_bar_color ()
		{
			var color = controller.renderer.theme.FillStartColor;
			if (controller.prefs.CustomBackgroundEnabled) {
				Gdk.RGBA selected = {};
				if (selected.parse (controller.prefs.BackgroundColor)) {
					color.red = selected.red;
					color.green = selected.green;
					color.blue = selected.blue;
				}
			}
			return color;
		}

		double get_bar_opacity (Gdk.RGBA color)
		{
			return controller.prefs.CustomBackgroundEnabled
				? 1.0
				: color.alpha.clamp (0.0, 1.0);
		}
	}
}
