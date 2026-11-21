//
// A selection highlight which glides between the rows of a list.
//

namespace Plank
{
	/**
	 * Paints the highlight of the selected row of a list itself, so that
	 * it can glide to the next row instead of jumping there. The style
	 * of the list has to leave the background of selected rows alone.
	 */
	public class ListSelectionGlide : GLib.Object
	{
		// The time (in seconds) the highlight takes to cover most of its way
		const double GLIDE_TIME = 0.030;

		public unowned Gtk.ListBox list { get; construct; }

		/**
		 * The color of the highlight.
		 */
		public Gdk.RGBA color = { 1.0, 1.0, 1.0, 0.16 };

		/**
		 * The margin rows have around them, which the highlight leaves out.
		 */
		public int inset_x = 5;
		public int inset_y = 1;

		public double radius = 8.0;

		/**
		 * Whether the highlight glides at all, or just stays on its row.
		 */
		public bool animate = true;

		double y = 0.0;
		double height = 0.0;
		bool placed = false;
		bool snap_next = true;
		uint tick_id = 0U;
		int64 last_time = 0LL;
		ulong draw_handler_id = 0UL;
		ulong selected_handler_id = 0UL;
		ulong destroy_handler_id = 0UL;
		bool list_alive = true;

		public ListSelectionGlide (Gtk.ListBox list)
		{
			Object (list : list);
		}

		construct
		{
			draw_handler_id = list.draw.connect (on_draw);
			selected_handler_id = list.row_selected.connect (on_row_selected);
			destroy_handler_id = list.destroy.connect (on_list_destroyed);
		}

		~ListSelectionGlide ()
		{
			if (!list_alive)
				return;
			stop ();
			list.disconnect (draw_handler_id);
			list.disconnect (selected_handler_id);
			list.disconnect (destroy_handler_id);
		}

		/**
		 * Makes the highlight jump to wherever the selection is next,
		 * e.g. because the rows were replaced and there is nothing to glide from.
		 */
		public void snap ()
		{
			snap_next = true;
		}

		void on_list_destroyed ()
		{
			stop ();
			list_alive = false;
		}

		void stop ()
		{
			if (tick_id > 0U && list_alive)
				list.remove_tick_callback (tick_id);
			tick_id = 0U;
		}

		/**
		 * Where the selected row is inside the list.
		 */
		bool get_target (out Gdk.Rectangle target)
		{
			target = {};
			var row = list.get_selected_row ();
			if (row == null || !row.get_mapped ())
				return false;
			Gtk.Allocation row_allocation, list_allocation;
			row.get_allocation (out row_allocation);
			list.get_allocation (out list_allocation);
			target = { row_allocation.x - list_allocation.x + inset_x,
				row_allocation.y - list_allocation.y + inset_y,
				row_allocation.width - 2 * inset_x, row_allocation.height - 2 * inset_y };
			return target.width > 0 && target.height > 0;
		}

		void on_row_selected (Gtk.ListBoxRow? row)
		{
			if (row == null || tick_id > 0U || snap_next || !placed || !animate
				|| !list.get_mapped () || !Motion.animations_enabled ())
				return;

			last_time = 0LL;
			tick_id = list.add_tick_callback (on_tick);
		}

		bool on_tick (Gtk.Widget widget, Gdk.FrameClock frame_clock)
		{
			var now = frame_clock.get_frame_time ();
			var dt = (last_time == 0LL ? 0.016 : double.min (0.032, (now - last_time) / 1000000.0));
			last_time = now;

			Gdk.Rectangle target;
			if (get_target (out target)) {
				var step = 1.0 - Math.exp (-dt / GLIDE_TIME);
				y += (target.y - y) * step;
				height += (target.height - height) * step;
				list.queue_draw ();
				if (!snap_next && (Math.fabs (target.y - y) >= 0.5
					|| Math.fabs (target.height - height) >= 0.5))
					return Source.CONTINUE;
			}

			// From here on drawing keeps the highlight on its row
			tick_id = 0U;
			list.queue_draw ();
			return Source.REMOVE;
		}

		bool on_draw (Gtk.Widget widget, Cairo.Context cr)
		{
			Gdk.Rectangle target;
			if (!get_target (out target)) {
				placed = false;
				return false;
			}

			if (tick_id == 0U || snap_next || !placed) {
				y = target.y;
				height = target.height;
				placed = true;
				snap_next = false;
			}

			var corner = double.min (radius, height / 2.0);
			var x = (double) target.x;
			var right = x + target.width;
			var bottom = y + height;
			cr.save ();
			cr.new_sub_path ();
			cr.arc (right - corner, y + corner, corner, -Math.PI_2, 0.0);
			cr.arc (right - corner, bottom - corner, corner, 0.0, Math.PI_2);
			cr.arc (x + corner, bottom - corner, corner, Math.PI_2, Math.PI);
			cr.arc (x + corner, y + corner, corner, Math.PI, 3.0 * Math.PI_2);
			cr.close_path ();
			Gdk.cairo_set_source_rgba (cr, color);
			cr.fill ();
			cr.restore ();
			return false;
		}
	}
}
