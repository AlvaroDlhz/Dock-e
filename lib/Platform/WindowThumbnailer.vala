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
	 * Keeps a small picture of each toplevel which is asked for, and takes
	 * a new one only after the toplevel has changed.
	 */
	public interface WindowThumbnailer : Object
	{
		/**
		 * The current picture of a toplevel, fit into the size the
		 * thumbnailer was created with.
		 *
		 * @return null if the toplevel cannot be read, as when it is gone
		 */
		public abstract Gdk.Pixbuf? lookup (Toplevel toplevel);

		/**
		 * Forgets every toplevel, which also frees their pictures.
		 */
		public abstract void clear ();

		/**
		 * The picture of this toplevel is out of date, and asking for it
		 * again gives a new one.
		 */
		public signal void changed (Toplevel toplevel);
	}
}
