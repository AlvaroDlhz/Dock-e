//
//  Copyright (C) 2026 Dock-E
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

namespace Plank.Platform
{
	/**
	 * Reports the pointer pushing against a segment of the screen edge
	 * (pressure barriers on X11).  The backend only delivers the events;
	 * deciding when the push is strong enough is up to the dock.
	 */
	public interface EdgeTrigger : Object
	{
		/**
		 * Watches a segment of the screen edge, replacing the previous one.
		 *
		 * @param edge the screen edge the segment lies on
		 * @param line the segment in logical pixels and GDK screen
		 *        coordinates; its width or height is 0 depending on the edge
		 */
		public abstract void set_edge (Gtk.PositionType edge, Gdk.Rectangle line);

		/**
		 * Stops watching the edge.
		 */
		public abstract void clear ();

		/**
		 * The pointer pushed against the edge.  The pointer is let through
		 * again right after the handlers ran.
		 *
		 * @param dx the horizontal motion the edge stopped
		 * @param dy the vertical motion the edge stopped
		 * @param time the time of the event
		 */
		public signal void hit (double dx, double dy, uint32 time);

		/**
		 * The pointer moved away from the edge.
		 */
		public signal void left ();
	}
}
