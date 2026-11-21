//
//  Copyright (C) 2011-2012 Robert Dyer, Rico Tzschichholz
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
	 * A hover window that shows labels for dock items.
	 * This window floats outside (but near) the dock.
	 */
	public class HoverWindow : Gtk.Window
	{
		const int PADDING = 8;
		const int TAIL_SIZE = 6;
		
		static construct
		{
			set_accessible_role (Atk.Role.TOOL_TIP);
			PlankCompat.gtk_widget_class_set_css_name ((GLib.ObjectClass) typeof (HoverWindow).class_ref (), "tooltip");
		}
		
		Gtk.Box box;
		Gtk.Label label;
		Gtk.PositionType dock_position;
		WindowTransition transition;
		
		public HoverWindow ()
		{
			GLib.Object (type: Gtk.WindowType.POPUP);
		}
		
		construct
		{
			Platform.get_popup_placer ().setup (this, Platform.PopupKind.TOOLTIP);
			app_paintable = true;
			resizable = false;
			opacity = 1.0;
			transition = new WindowTransition (this);
			
			unowned Gdk.Screen screen = get_screen ();
			set_visual (screen.get_rgba_visual () ?? screen.get_system_visual ());
			
			get_style_context ().add_class (Gtk.STYLE_CLASS_TOOLTIP);
			get_style_context ().add_class ("plank-hover-label");

			DockStyle.ensure_base (screen);
			
			box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
			box.set_margin_left (4);
			box.set_margin_right (4);
			box.set_margin_top (4);
			box.set_margin_bottom (4);
			add (box);
			box.show ();
			
			label = new Gtk.Label (null);
			label.set_line_wrap (true);
			box.pack_start (label, false, false, 0);
		}
		
		/**
		 * Shows and centers the window according to the x/y location specified
		 * while accounting the dock's position.
		 *
		 * @param x the x location
		 * @param y the y location
		 * @param position the dock's position
		 */
		public void show_at (int x, int y, Gtk.PositionType position)
		{
			dock_position = position;
			box.set_margin_left (4 + (position == Gtk.PositionType.LEFT ? TAIL_SIZE : 0));
			box.set_margin_right (4 + (position == Gtk.PositionType.RIGHT ? TAIL_SIZE : 0));
			box.set_margin_top (4 + (position == Gtk.PositionType.TOP ? TAIL_SIZE : 0));
			box.set_margin_bottom (4 + (position == Gtk.PositionType.BOTTOM ? TAIL_SIZE : 0));
			unowned Gdk.Screen screen = get_screen ();
			Gdk.Rectangle monitor;
			screen.get_monitor_geometry (screen.get_monitor_at_point (x, y), out monitor);
			
			// realize and show the window early to have current allocation-dimensions
			// this is also needed for being able to move override-redirect windows
			// on mutter-derived window-managers
			var was_visible = visible;
			// Stays invisible until it is in place, so it never flashes at the previous item
			if (!was_visible)
				transition.jump_to (0.0);
			show ();
			
			var width = get_allocated_width ();
			var height = get_allocated_height ();
			
			switch (position) {
			case Gtk.PositionType.BOTTOM:
				x = x - width / 2;
				y = y - height - PADDING;
				break;
			case Gtk.PositionType.TOP:
				x = x - width / 2;
				y = y + PADDING;
				break;
			case Gtk.PositionType.LEFT:
				x = x + PADDING;
				y = y - height / 2;
				break;
			case Gtk.PositionType.RIGHT:
				x = x - width - PADDING;
				y = y - height / 2;
				break;
			}
			
			x = x.clamp (monitor.x, monitor.x + monitor.width - width);
			y = y.clamp (monitor.y, monitor.y + monitor.height - height);
			
			Platform.get_popup_placer ().place (this, x, y);
			
			// Every item gets its label fading in at its own place
			if (!was_visible)
				transition.animate_to (1.0, Motion.LABEL_OPEN_TIME * 1000);
		}
		
		/**
		 * Set the tooltip-text to show
		 *
		 * @param text the text to show
		 */
		public void set_text (string text)
		{
			label.set_text (text);
			if (text != null)
				label.show ();
			else
				label.hide ();
		}
		
		/**
		 * {@inheritDoc}
		 */
		public override bool draw (Cairo.Context cr)
		{
			var width = get_allocated_width ();
			var height = get_allocated_height ();
			unowned Gtk.StyleContext context = get_style_context ();
			int body_x = dock_position == Gtk.PositionType.LEFT ? TAIL_SIZE : 0;
			int body_y = dock_position == Gtk.PositionType.TOP ? TAIL_SIZE : 0;
			int body_width = width - ((dock_position == Gtk.PositionType.LEFT
				|| dock_position == Gtk.PositionType.RIGHT) ? TAIL_SIZE : 0);
			int body_height = height - ((dock_position == Gtk.PositionType.TOP
				|| dock_position == Gtk.PositionType.BOTTOM) ? TAIL_SIZE : 0);
			
			if (is_composited ()) {
				cr.save ();
				cr.set_operator (Cairo.Operator.CLEAR);
				cr.paint ();
				cr.restore ();
				
				shape_combine_region (null);
				
				context.render_background (cr, body_x, body_y, body_width, body_height);
				context.render_frame (cr, body_x, body_y, body_width, body_height);
				draw_tail (cr, width, height);
			} else {
				var surface = get_window ().create_similar_surface (Cairo.Content.COLOR_ALPHA, width, height);
				var compat_cr = new Cairo.Context (surface);
				
				context.render_background (compat_cr, body_x, body_y, body_width, body_height);
				context.render_frame (compat_cr, body_x, body_y, body_width, body_height);
				draw_tail (compat_cr, width, height);
				
				var region = Gdk.cairo_region_create_from_surface (surface);
				shape_combine_region (region);
			}
			
			return base.draw (cr);
		}

		void draw_tail (Cairo.Context cr, int width, int height)
		{
			double x1, y1, x2, y2, tip_x, tip_y;
			switch (dock_position) {
			case Gtk.PositionType.BOTTOM:
				x1 = width / 2.0 - 7;
				y1 = height - TAIL_SIZE;
				x2 = width / 2.0 + 7;
				y2 = y1;
				tip_x = width / 2.0;
				tip_y = height;
				break;
			case Gtk.PositionType.TOP:
				x1 = width / 2.0 - 7;
				y1 = TAIL_SIZE;
				x2 = width / 2.0 + 7;
				y2 = y1;
				tip_x = width / 2.0;
				tip_y = 0;
				break;
			case Gtk.PositionType.LEFT:
				x1 = TAIL_SIZE;
				y1 = height / 2.0 - 7;
				x2 = x1;
				y2 = height / 2.0 + 7;
				tip_x = 0;
				tip_y = height / 2.0;
				break;
			case Gtk.PositionType.RIGHT:
				x1 = width - TAIL_SIZE;
				y1 = height / 2.0 - 7;
				x2 = x1;
				y2 = height / 2.0 + 7;
				tip_x = width;
				tip_y = height / 2.0;
				break;
			default:
				return;
			}

			// Match whatever background the style gives the label's body
			unowned Gtk.StyleContext context = get_style_context ();
			var color = context.get_background_color (context.get_state ());

			cr.move_to (x1, y1);
			cr.line_to (tip_x, tip_y);
			cr.line_to (x2, y2);
			cr.close_path ();
			Gdk.cairo_set_source_rgba (cr, color);
			cr.fill ();
			cr.move_to (x1, y1);
			cr.line_to (x2, y2);
			cr.set_line_cap (Cairo.LineCap.BUTT);
			Gdk.cairo_set_source_rgba (cr, color);
			cr.set_line_width (2.0);
			cr.stroke ();
		}
	}
}
