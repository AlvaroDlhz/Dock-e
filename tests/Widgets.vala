//
//  Copyright (C) 2013 Rico Tzschichholz
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

using Plank;

namespace PlankTests
{
	public static void register_widgets_tests ()
	{
		Test.add_func ("/Widgets/CompositedWindow/basics", composited_window_basics);
		Test.add_func ("/Widgets/PoofWindow/basics", poof_window_basics);
		Test.add_func ("/Widgets/HoverWindow/basics", hover_window_basics);
		Test.add_func ("/Widgets/PopupPosition/all-edges", popup_position_all_edges);
		Test.add_func ("/Widgets/PopupPosition/centered", popup_position_centered);
		Test.add_func ("/Services/WindowThumbnails/follows-changes", window_thumbnails_follow_changes);
	}

	void window_thumbnails_follow_changes ()
	{
		var shade = 0.2;
		var window = new Gtk.Window (Gtk.WindowType.POPUP);
		var area = new Gtk.DrawingArea ();
		area.draw.connect ((cr) => {
			cr.set_source_rgb (shade, shade, shade);
			cr.paint ();
			return true;
		});
		window.add (area);
		window.move (60, 60);
		window.set_size_request (200, 100);
		window.show_all ();

		wait (X_WAIT_MS);

		var xid = (uint32) ((Gdk.X11.Window) window.get_window ()).get_xid ();
		var thumbnails = new WindowThumbnails (100, 100);
		var first = thumbnails.lookup (xid);
		assert (first != null);
		// Fit into the room it was given, keeping its proportions
		assert (first.width == 100);
		assert (first.height == 50);
		// Nothing was painted in between, so the window is not read again
		assert (thumbnails.lookup (xid) == first);

		var announced = 0;
		thumbnails.changed.connect ((changed_xid) => {
			if (changed_xid == xid)
				announced++;
		});
		shade = 0.8;
		area.queue_draw ();

		wait (1500);

		assert (announced >= 1);
		var second = thumbnails.lookup (xid);
		assert (second != null);
		assert (second != first);
		// The picture shows what the window paints now
		unowned uint8[] pixels = second.get_pixels ();
		assert (pixels[0] > 150);

		thumbnails.clear ();
		window.destroy ();
	}
	
	void composited_window_basics ()
	{
		CompositedWindow window, window2;
		int x, y, width, height;
		
		window = new CompositedWindow ();
		window.move (100, 100);
		window.set_size_request (300, 300);
		window.show_all ();
		
		wait (X_WAIT_MS);
		
		window.get_position (out x, out y);
		window.get_size (out width, out height);
		assert (window.visible == true);
		assert (x == 100);
		assert (y == 100);
		assert (width == 300);
		assert (height == 300);

		window2 = new CompositedWindow.with_type (Gtk.WindowType.POPUP);
		window2.move (50, 50);
		window2.set_size_request (100, 100);
		window2.show_all ();
		
		wait (X_WAIT_MS);
		
		window2.get_position (out x, out y);
		window2.get_size (out width, out height);
		assert (window2.visible == true);
		assert (x == 50);
		assert (y == 50);
		assert (width == 100);
		assert (height == 100);
	}
	
	void poof_window_basics ()
	{
		PoofWindow window;
		unowned PoofWindow default_window;
		
		default_window = PoofWindow.get_default ();
		
		window = new PoofWindow ();
		window.show_at (100, 100);
		
		wait (X_WAIT_MS);
		
		window.show_at (200, 200);
		
		wait (X_WAIT_MS);
	}
	
	void hover_window_basics ()
	{
		HoverWindow window;
		
		window = new HoverWindow ();
		window.set_text ("TEST");
		
		window.show_at (200, 200, Gtk.PositionType.BOTTOM);
		window.show_at (200, 200, Gtk.PositionType.TOP);
		window.show_at (200, 200, Gtk.PositionType.LEFT);
		window.show_at (200, 200, Gtk.PositionType.RIGHT);
		
		wait (X_WAIT_MS);
		
		window = null;
		
		wait (X_WAIT_MS);
	}

	void popup_position_all_edges ()
	{
		Gdk.Rectangle workarea = { 0, 0, 1000, 800 };
		int x, y;

		PositionManager.calculate_popup_position (Gtk.PositionType.BOTTOM,
			{ 0, 740, 1000, 60 }, { 450, 740, 50, 60 }, 200, 100, 10,
			workarea, out x, out y);
		assert (x == 375 && y == 630);

		PositionManager.calculate_popup_position (Gtk.PositionType.TOP,
			{ 0, 0, 1000, 60 }, { 450, 0, 50, 60 }, 200, 100, 10,
			workarea, out x, out y);
		assert (x == 375 && y == 70);

		PositionManager.calculate_popup_position (Gtk.PositionType.LEFT,
			{ 0, 0, 60, 800 }, { 0, 350, 60, 50 }, 200, 100, 10,
			workarea, out x, out y);
		assert (x == 70 && y == 325);

		PositionManager.calculate_popup_position (Gtk.PositionType.RIGHT,
			{ 940, 0, 60, 800 }, { 940, 350, 60, 50 }, 200, 100, 10,
			workarea, out x, out y);
		assert (x == 730 && y == 325);
	}

	void popup_position_centered ()
	{
		int x, y;

		PositionManager.calculate_centered_popup_position (
			{ 0, 0, 1000, 800 }, 200, 100, out x, out y);
		assert (x == 400 && y == 350);

		PositionManager.calculate_centered_popup_position (
			{ 100, 50, 1000, 800 }, 200, 100, out x, out y);
		assert (x == 500 && y == 400);

		PositionManager.calculate_centered_popup_position (
			{ 0, 0, 100, 80 }, 200, 100, out x, out y);
		assert (x == 0 && y == 0);
	}
}
