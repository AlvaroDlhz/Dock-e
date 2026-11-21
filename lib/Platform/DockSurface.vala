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
	 * What the display server has to know about the dock window itself.
	 */
	public interface DockSurface : Object
	{
		/**
		 * Reserves space along one edge so maximized windows do not cover
		 * the dock (struts on X11, an exclusive zone on layer-shell).
		 *
		 * @param edge the edge the dock sits on
		 * @param area the part of the screen the dock is placed in, in
		 *        logical pixels and GDK screen coordinates
		 * @param thickness the logical pixels to reserve from the edge of
		 *        area; 0 releases the space
		 */
		public abstract void reserve (Gtk.PositionType edge, Gdk.Rectangle area, int thickness);
	}
}
